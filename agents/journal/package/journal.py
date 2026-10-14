"""omp の session 記録から 1 日分の作業日誌を作り、agent-journal に記録する。"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta, tzinfo
from enum import Enum
from pathlib import Path
from time import time as epoch_seconds
from typing import Any
from zoneinfo import ZoneInfo

PROMPTS = Path(__file__).resolve().parent / "prompts"
MESSAGE_CHARS = 4000
CHUNK_CHARS = 40000
MODEL_TIMEOUT_SECONDS = 900
DEADLINE_ENV = "DOTFILES_JOB_DEADLINE"


class JournalError(Exception):
    pass


def child_timeout(limit: float | None) -> float | None:
    value = os.environ.get(DEADLINE_ENV)
    if value is None:
        return limit
    try:
        remaining = float(value) - epoch_seconds()
    except ValueError:
        raise JournalError(f"{DEADLINE_ENV} is not a number: {value!r}") from None
    if remaining <= 0:
        raise JournalError("the job deadline was reached; no new child process is started")
    return remaining if limit is None else min(limit, remaining)


def run(command: list[str], *, limit: float | None = None, **options: Any) -> subprocess.CompletedProcess:
    timeout = child_timeout(limit)
    try:
        return subprocess.run(command, timeout=timeout, **options)
    except subprocess.TimeoutExpired:
        raise JournalError(f"{Path(command[0]).name} did not finish within {timeout:.0f}s") from None
    except OSError as error:
        raise JournalError(f"{Path(command[0]).name} could not start: {error}") from None


@dataclass
class Prompt:
    """利用者が書いた発言。entry の ID で session file の原文へ戻れる。"""

    id: str
    text: str


@dataclass
class Session:
    id: str
    title: str
    cwd: str
    path: Path
    first: datetime
    last: datetime
    lines: list[str] = field(default_factory=list)
    prompts: list[Prompt] = field(default_factory=list)
    requests: int = 0
    cost: float = 0.0


@dataclass
class Project:
    root: str
    sessions: list[Session]
    commits: list[str]
    body: str = ""


def window(day: date, tz: ZoneInfo, start_hour: int) -> tuple[datetime, datetime]:
    start = datetime.combine(day, time(start_hour), tz)
    return start, start + timedelta(days=1)


def completed_day(now: datetime, tz: ZoneInfo, start_hour: int) -> date:
    moment = now.astimezone(tz)
    boundary = datetime.combine(moment.date(), time(start_hour), tz)
    if moment < boundary:
        boundary -= timedelta(days=1)
    return (boundary - timedelta(days=1)).date()


def output_path(journal: Path, day: date, machine: str) -> Path:
    return journal / f"{day:%Y}" / f"{day:%m%d}" / f"{machine}.md"


def entry_time(entry: dict) -> datetime | None:
    value = entry.get("timestamp")
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def clip(text: str) -> str:
    text = text.strip()
    return text if len(text) <= MESSAGE_CHARS else text[:MESSAGE_CHARS] + "…（以下省略）"


def text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    texts: list[str] = []
    for part in content if isinstance(content, list) else []:
        if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str):
            texts.append(part["text"])
    return "\n".join(texts)


def read_session(path: Path, start: datetime, end: datetime, tz: tzinfo) -> Session | None:
    header: dict | None = None
    title = ""
    session: Session | None = None
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            kind = entry.get("type")
            if kind == "title":
                title = str(entry.get("title") or title)
                continue
            if kind == "session":
                header = entry
                title = title or str(entry.get("title") or "")
                continue
            if kind != "message" or header is None:
                continue
            moment = entry_time(entry)
            message = entry.get("message")
            if moment is None or not start <= moment < end or not isinstance(message, dict):
                continue
            role = message.get("role")
            if role not in ("user", "assistant"):
                continue
            if session is None:
                session = Session(str(header.get("id") or path.stem), title, str(header.get("cwd") or ""), path, moment, moment)
            session.last = max(session.last, moment)
            clock = moment.astimezone(tz).strftime("%H:%M")
            content = message.get("content")
            if role == "user":
                # agent が書いた指示は role が user でも attribution が agent になる。利用者の発言だけを残す
                if message.get("attribution") == "user" and isinstance(entry.get("id"), str):
                    session.prompts.append(Prompt(entry["id"], text_of(content)))
                text = clip(text_of(content))
                if text:
                    session.lines.append(f"[{clock} 利用者] {text}")
                continue
            session.requests += 1
            cost = ((message.get("usage") or {}).get("cost") or {}).get("total")
            if isinstance(cost, (int, float)):
                session.cost += cost
            for part in content if isinstance(content, list) else []:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text" and isinstance(part.get("text"), str):
                    text = clip(part["text"])
                    if text:
                        session.lines.append(f"[{clock} 応答] {text}")
                elif part.get("type") == "toolCall":
                    arguments = part.get("arguments") if isinstance(part.get("arguments"), dict) else {}
                    intent = part.get("intent") or arguments.get("i")
                    name = part.get("name") or "tool"
                    session.lines.append(f"[{clock} 操作] {name}: {intent}" if intent else f"[{clock} 操作] {name}")
    if session is not None:
        session.title = title
    return session


def sessions_in(root: Path, start: datetime, end: datetime, tz: tzinfo) -> list[Session]:
    found = []
    for path in sorted(root.glob("*/*.jsonl")):
        try:
            if datetime.fromtimestamp(path.stat().st_mtime, tz) < start:
                continue
        except OSError:
            continue
        session = read_session(path, start, end, tz)
        if session is not None and session.lines:
            found.append(session)
    return sorted(found, key=lambda session: session.first)


def project_root(cwd: str) -> str:
    result = run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    root = result.stdout.strip()
    return root if result.returncode == 0 and root else cwd


def commits_between(root: str, start: datetime, end: datetime) -> list[str]:
    result = run(
        [
            "git", "-C", root, "log", "--all",
            f"--since={start.isoformat()}",
            f"--until={(end - timedelta(seconds=1)).isoformat()}",
            "--format=%h %s",
        ],
        capture_output=True,
        text=True,
    )
    return result.stdout.splitlines() if result.returncode == 0 else []


def summarize(options: argparse.Namespace, prompt: Path, material: str) -> str:
    # cwd を Git の外に置く。project memory の hook が動いても想起先の project を決められず、記憶を model の入力へ混ぜない。
    # 一時 directory の場所は TMPDIR で変わるため、work tree の中なら model を呼ばずに止める
    with tempfile.TemporaryDirectory(prefix="agent-journal-") as workdir:
        inside = run(["git", "-C", workdir, "rev-parse", "--is-inside-work-tree"], capture_output=True)
        if inside.returncode == 0:
            raise JournalError(f"{workdir} is inside a Git work tree; set TMPDIR outside any repository")
        budget = child_timeout(MODEL_TIMEOUT_SECONDS)
        result = run(
            [
                options.omp, "-p", "--no-session", "--no-extensions", "--no-skills", "--no-rules",
                "--no-tools", "--no-lsp", "--no-title",
                "--model", options.model, "--thinking", options.thinking,
                "--max-time", f"{max(1, int(budget) - 60)}",
                "--system-prompt", str(prompt),
            ],
            limit=MODEL_TIMEOUT_SECONDS,
            input=material,
            capture_output=True,
            text=True,
            cwd=workdir,
        )
    summary = result.stdout.strip()
    if result.returncode != 0 or not summary:
        raise JournalError(f"{prompt.name}: the model failed: {result.stderr.strip()[-500:]}")
    return summary


def chunks(lines: list[str]) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    size = 0
    for line in lines:
        if current and size + len(line) > CHUNK_CHARS:
            parts.append("\n".join(current))
            current, size = [], 0
        current.append(line)
        size += len(line) + 1
    if current:
        parts.append("\n".join(current))
    return parts


def summarize_session(options: argparse.Namespace, session: Session) -> str:
    parts = chunks(session.lines)
    summaries = []
    for index, part in enumerate(parts, start=1):
        material = f"session: {session.id}\ntitle: {session.title}\ncwd: {session.cwd}\n範囲: {index}/{len(parts)}\n\n{part}"
        summaries.append(summarize(options, PROMPTS / "session.md", material))
    return "\n\n".join(summaries)


def compose(
    options: argparse.Namespace, machine: str, day: date, start: datetime, end: datetime, sessions: list[Session]
) -> str:
    projects: dict[str, Project] = {}
    for session in sessions:
        root = project_root(session.cwd)
        projects.setdefault(root, Project(root, [], commits_between(root, start, end))).sessions.append(session)

    for project in projects.values():
        blocks = [f"project: {project.root}"]
        for session in project.sessions:
            blocks.append(f"## session {session.id[:8]} {session.title}\n{summarize_session(options, session)}")
        blocks.append("## commit\n" + ("\n".join(project.commits) or "なし"))
        project.body = summarize(options, PROMPTS / "project.md", "\n\n".join(blocks))

    tz = start.tzinfo
    lines = [
        f"# {day.isoformat()} {machine}",
        "",
        f"対象は {start:%Y-%m-%d %H:%M} から {end:%Y-%m-%d %H:%M} まで（{tz}）の omp の作業である。",
        "",
        "| project | session | request | 費用 (USD) |",
        "|---|---|---|---|",
    ]
    for project in projects.values():
        cost = sum(session.cost for session in project.sessions)
        requests = sum(session.requests for session in project.sessions)
        lines.append(f"| {Path(project.root).name or project.root} | {len(project.sessions)} | {requests} | {cost:.3f} |")
    lines.append(
        f"| 合計 | {len(sessions)} | {sum(session.requests for session in sessions)} | {sum(session.cost for session in sessions):.3f} |"
    )
    for project in projects.values():
        lines += ["", f"## {Path(project.root).name or project.root}", "", f"`{project.root}`", "", project.body, "", "### session", ""]
        for session in project.sessions:
            span = f"{session.first.astimezone(tz):%H:%M}–{session.last.astimezone(tz):%H:%M}"
            # 本文の短い ID は近い時刻に始めた session 同士で重なり得るため、一覧は resume できる完全な ID を持つ
            lines.append(f"- `{session.id}` {session.title}（{span}）")
        lines += ["", "### commit", ""]
        lines += [f"- `{commit}`" for commit in project.commits] or ["なし"]
    return "\n".join(lines) + "\n"


def git(journal: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    result = run(["git", "-C", str(journal), *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise JournalError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def sync(journal: Path) -> str:
    if not (journal / ".git").exists():
        raise JournalError(f"{journal} is not a git checkout")
    branch = git(journal, "symbolic-ref", "--short", "HEAD").stdout.strip()
    git(journal, "fetch", "--quiet", "origin")
    if git(journal, "rev-parse", "--verify", "--quiet", f"origin/{branch}", check=False).returncode == 0:
        git(journal, "rebase", "--quiet", "--autostash", f"origin/{branch}")
    return branch


class Stage(Enum):
    ABSENT = "absent"
    GENERATED = "generated"
    COMMITTED = "committed"
    PUBLISHED = "published"


def blob(journal: Path, revision: str, relative: str) -> bytes | None:
    result = run(["git", "-C", str(journal), "show", f"{revision}:{relative}"], capture_output=True)
    return result.stdout if result.returncode == 0 else None


def stage_of(journal: Path, relative: str, branch: str) -> Stage:
    path = journal / relative
    if not path.is_file():
        return Stage.ABSENT
    body = path.read_bytes()
    if blob(journal, f"origin/{branch}", relative) == body:
        return Stage.PUBLISHED
    if blob(journal, "HEAD", relative) == body:
        return Stage.COMMITTED
    return Stage.GENERATED


def unfinished_days(journal: Path, machine: str, branch: str) -> list[date]:
    candidates = {
        entry[3:]
        for entry in git(journal, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames").stdout.split("\0")
        if len(entry) > 3
    }
    if git(journal, "rev-parse", "--verify", "--quiet", f"origin/{branch}", check=False).returncode == 0:
        candidates |= set(filter(None, git(journal, "diff", "--name-only", "-z", f"origin/{branch}", "HEAD").stdout.split("\0")))
    pattern = re.compile(rf"(\d{{4}})/(\d{{2}})(\d{{2}})/{re.escape(machine)}\.md")
    days = []
    for relative in sorted(candidates):
        match = pattern.fullmatch(relative)
        if match is None:
            continue
        try:
            day = date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
        except ValueError:
            continue
        if stage_of(journal, relative, branch) is not Stage.PUBLISHED:
            days.append(day)
    return days


def pending_days(
    now: datetime, tz: ZoneInfo, start_hour: int, lookback: int, journal: Path, machine: str, branch: str
) -> list[date]:
    latest = completed_day(now, tz, start_hour)
    recent = (latest - timedelta(days=offset) for offset in range(lookback))
    unpublished = {
        day
        for day in recent
        if stage_of(journal, str(output_path(journal, day, machine).relative_to(journal)), branch) is not Stage.PUBLISHED
    }
    return sorted(unpublished | set(unfinished_days(journal, machine, branch)))


def write(path: Path, document: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        handle.write(document)
    os.replace(handle.name, path)


def commit(journal: Path, relative: str, day: date) -> None:
    git(journal, "add", "--", relative)
    if git(journal, "diff", "--cached", "--quiet", "--", relative, check=False).returncode != 0:
        git(journal, "commit", "--quiet", "-m", f"docs: {day.isoformat()} の日誌", "--", relative)


def publish(journal: Path, branch: str, relative: str) -> None:
    git(journal, "push", "--quiet", "origin", f"HEAD:{branch}")
    # remote の内容が公開の正本のため push の終了 status による判定は不可
    if blob(journal, f"origin/{branch}", relative) != (journal / relative).read_bytes():
        raise JournalError(f"{relative} is not at origin/{branch} with the expected content after the push")


def parse(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="dotfiles-agent-journal", description=__doc__)
    parser.add_argument("--sessions-root", required=True, type=Path)
    parser.add_argument("--journal-dir", required=True, type=Path)
    parser.add_argument("--machine-name", required=True)
    parser.add_argument("--timezone", required=True)
    parser.add_argument("--start-hour", required=True, type=int)
    parser.add_argument("--lookback-days", required=True, type=int)
    parser.add_argument("--omp", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--thinking", required=True)
    parser.add_argument("--date", type=date.fromisoformat, help="この日の日誌だけを作り直す（YYYY-MM-DD）")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, now: datetime | None = None) -> int:
    options = parse(argv)
    tz = ZoneInfo(options.timezone)
    journal = options.journal_dir
    machine = options.machine_name
    try:
        branch = sync(journal)
        days = [options.date] if options.date else pending_days(
            now or datetime.now(tz), tz, options.start_hour, options.lookback_days, journal, machine, branch
        )
    except JournalError as error:
        print(f"dotfiles-agent-journal: {error}", file=sys.stderr)
        return 1
    failed = []
    for day in days:
        path = output_path(journal, day, machine)
        relative = str(path.relative_to(journal))
        start, end = window(day, tz, options.start_hour)
        try:
            stage = Stage.ABSENT if options.date else stage_of(journal, relative, branch)
            entered = stage
            recorded = 0
            if stage is Stage.ABSENT:
                sessions = sessions_in(options.sessions_root, start, end, tz)
                if not sessions:
                    print(f"{day}: omp の作業はない")
                    continue
                write(path, compose(options, machine, day, start, end, sessions))
                recorded = len(sessions)
                stage = stage_of(journal, relative, branch)
            if stage is Stage.GENERATED:
                commit(journal, relative, day)
                stage = Stage.COMMITTED
            if stage is Stage.COMMITTED:
                publish(journal, branch, relative)
        except JournalError as error:
            print(f"dotfiles-agent-journal: {day}: {error}", file=sys.stderr)
            failed.append(day)
            continue
        if entered is Stage.ABSENT:
            print(f"{day}: {recorded} session を記録した")
        elif entered is Stage.GENERATED:
            print(f"{day}: 生成済みの日誌を commit して公開した")
        else:
            print(f"{day}: commit 済みの日誌を公開した")
    return 1 if failed else 0


if __name__ == "__main__":
    # 既定の SIGTERM は一時 directory と model の子を残すため既定動作は不可
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(128 + signal.SIGTERM))
    sys.exit(main())
