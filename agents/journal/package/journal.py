"""omp の session 記録から 1 日分の作業日誌を作り、agent-journal に記録する。"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

PROMPTS = Path(__file__).resolve().parent / "prompts"
MESSAGE_CHARS = 4000
CHUNK_CHARS = 40000
MODEL_TIMEOUT_SECONDS = 900


class JournalError(Exception):
    pass


@dataclass
class Session:
    id: str
    title: str
    cwd: str
    first: datetime
    last: datetime
    lines: list[str] = field(default_factory=list)
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


def output_path(journal: Path, day: date, host: str) -> Path:
    return journal / f"{day:%Y}" / f"{day:%m%d}" / f"{host}.md"


def pending_days(now: datetime, tz: ZoneInfo, start_hour: int, lookback: int, journal: Path, host: str) -> list[date]:
    latest = completed_day(now, tz, start_hour)
    days = (latest - timedelta(days=offset) for offset in range(lookback))
    return sorted(day for day in days if not output_path(journal, day, host).exists())


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


def read_session(path: Path, start: datetime, end: datetime, tz: ZoneInfo) -> Session | None:
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
                session = Session(str(header.get("id") or path.stem), title, str(header.get("cwd") or ""), moment, moment)
            session.last = max(session.last, moment)
            clock = moment.astimezone(tz).strftime("%H:%M")
            content = message.get("content")
            if role == "user":
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


def sessions_in(root: Path, start: datetime, end: datetime, tz: ZoneInfo) -> list[Session]:
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
    result = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    root = result.stdout.strip()
    return root if result.returncode == 0 and root else cwd


def commits_between(root: str, start: datetime, end: datetime) -> list[str]:
    result = subprocess.run(
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


def summarize(options: argparse.Namespace, prompt: str, material: str) -> str:
    with tempfile.TemporaryDirectory(prefix="agent-journal-") as workdir:
        try:
            result = subprocess.run(
                [
                    options.omp, "-p", "--no-session", "--no-extensions", "--no-skills", "--no-rules",
                    "--no-tools", "--no-lsp", "--no-title",
                    "--model", options.model, "--thinking", options.thinking,
                    "--max-time", f"{MODEL_TIMEOUT_SECONDS - 60}",
                    "--system-prompt", str(PROMPTS / prompt),
                ],
                input=material,
                capture_output=True,
                text=True,
                cwd=workdir,
                timeout=MODEL_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            raise JournalError(f"{prompt}: the model did not answer within {MODEL_TIMEOUT_SECONDS}s") from None
    summary = result.stdout.strip()
    if result.returncode != 0 or not summary:
        raise JournalError(f"{prompt}: the model failed: {result.stderr.strip()[-500:]}")
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
        summaries.append(summarize(options, "session.md", material))
    return "\n\n".join(summaries)


def compose(options: argparse.Namespace, day: date, start: datetime, end: datetime, sessions: list[Session]) -> str:
    projects: dict[str, Project] = {}
    for session in sessions:
        root = project_root(session.cwd)
        projects.setdefault(root, Project(root, [], commits_between(root, start, end))).sessions.append(session)

    for project in projects.values():
        blocks = [f"project: {project.root}"]
        for session in project.sessions:
            blocks.append(f"## session {session.id[:8]} {session.title}\n{summarize_session(options, session)}")
        blocks.append("## commit\n" + ("\n".join(project.commits) or "なし"))
        project.body = summarize(options, "project.md", "\n\n".join(blocks))

    tz = start.tzinfo
    lines = [
        f"# {day.isoformat()} {options.host}",
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
    result = subprocess.run(["git", "-C", str(journal), *args], capture_output=True, text=True)
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


def record(journal: Path, path: Path, day: date, document: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        handle.write(document)
    os.replace(handle.name, path)
    relative = str(path.relative_to(journal))
    git(journal, "add", "--", relative)
    if git(journal, "diff", "--cached", "--quiet", "--", relative, check=False).returncode != 0:
        git(journal, "commit", "--quiet", "-m", f"docs: {day.isoformat()} の日誌を記録する", "--", relative)


def publish(journal: Path, branch: str) -> None:
    if git(journal, "rev-parse", "--verify", "--quiet", "HEAD", check=False).returncode == 0:
        git(journal, "push", "--quiet", "origin", f"HEAD:{branch}")


def parse(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="dotfiles-agent-journal", description=__doc__)
    parser.add_argument("--sessions-root", required=True, type=Path)
    parser.add_argument("--journal-dir", required=True, type=Path)
    parser.add_argument("--host", required=True)
    parser.add_argument("--timezone", required=True)
    parser.add_argument("--start-hour", required=True, type=int)
    parser.add_argument("--lookback-days", required=True, type=int)
    parser.add_argument("--omp", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--thinking", required=True)
    parser.add_argument("--date", type=date.fromisoformat, help="この日の日誌だけを作り直す（YYYY-MM-DD）")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    options = parse(argv)
    tz = ZoneInfo(options.timezone)
    journal = options.journal_dir
    try:
        branch = sync(journal)
        days = [options.date] if options.date else pending_days(
            datetime.now(tz), tz, options.start_hour, options.lookback_days, journal, options.host
        )
        for day in days:
            start, end = window(day, tz, options.start_hour)
            sessions = sessions_in(options.sessions_root, start, end, tz)
            if not sessions:
                print(f"{day}: omp の作業はない")
                continue
            record(journal, output_path(journal, day, options.host), day, compose(options, day, start, end, sessions))
            print(f"{day}: {len(sessions)} session を記録した")
        publish(journal, branch)
    except JournalError as error:
        print(f"dotfiles-agent-journal: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
