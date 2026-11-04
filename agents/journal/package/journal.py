"""omp の session 記録から 1 日分の技術的な知見を作り、agent-journal に記録する。"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from datetime import date, datetime, time, timedelta, tzinfo
from enum import Enum
from pathlib import Path
from time import time as epoch_seconds
from typing import Any, NamedTuple
from zoneinfo import ZoneInfo

PROMPTS = Path(__file__).resolve().parent / "prompts"
MESSAGE_CHARS = 4000
CHUNK_CHARS = 40000
BACKGROUND_CHARS = 16000
PIECE_CHARS = 8000
SYNTHESIS_CHARS = 60000
REDUCTION_ROUNDS = 4
MODEL_TIMEOUT_SECONDS = 900
DEADLINE_ENV = "DOTFILES_JOB_DEADLINE"
FORMAT_MARKER = "<!-- agent-journal: technical-insights-v1 -->"
NO_INSIGHTS = "この期間の記録から、根拠を引用できる技術的な知見は抽出されなかった。"
LIMITATION = (
    "各項目の根拠は、記録に残る利用者の発言とエージェントの応答・操作の意図からの引用である。"
    "エージェントが報告した観察と数値は、独立に確かめたものではない。"
)
STATUS_LABELS = {
    "supported": "記録から支持される（独立した検証ではない）",
    "hypothesis": "仮説（記録にある根拠からの推測）",
}
INSIGHT_TEXTS = ("title", "finding", "explanation", "application", "caveats")
INSIGHT_KEYS = {*INSIGHT_TEXTS, "status", "evidence"}
INJECTED = re.compile(r"<(project_memory|system-reminder|task-notification)\b[^>]*>.*?</\1\s*>", re.DOTALL | re.IGNORECASE)
FENCED_JSON = re.compile(r"\A```[A-Za-z]*[ \t]*\n(.*)\n```\Z", re.DOTALL)
HEADING_LINE = re.compile(r"(?m)^( {0,3})#")
LINE_BREAK = re.compile(r"\r\n|\r|\n")
BACKTICK_RUN = re.compile(r"`+")


class Ground(NamedTuple):
    text: str
    current: bool
    supported: bool


Grounds = dict[str, list[Ground]]


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
class Evidence:
    """記録に見える一つの発言・応答・操作。source から session file の原文へ戻れ、current が偽なら対象の時間帯より前の背景。"""

    source: str
    text: str
    current: bool
    kind: str


@dataclass
class Session:
    id: str
    title: str
    cwd: str
    path: Path
    first: datetime
    last: datetime
    evidence: list[Evidence] = field(default_factory=list)
    prompts: list[Prompt] = field(default_factory=list)


@dataclass
class Citation:
    source: str
    quote: str
    current: bool


@dataclass
class Insight:
    title: str
    finding: str
    explanation: str
    application: str
    caveats: str
    status: str
    evidence: list[Citation]


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


def visible_evidence(source: str, message: dict, current: bool) -> list[Evidence]:
    content = message.get("content")
    if message.get("role") == "user":
        text = INJECTED.sub("", text_of(content)).strip()
        return [Evidence(source, text, current, "user")] if text else []
    found = []
    for part in content if isinstance(content, list) else []:
        if not isinstance(part, dict):
            continue
        if part.get("type") == "text" and isinstance(part.get("text"), str):
            text = part["text"].strip()
            if text:
                found.append(Evidence(source, text, current, "assistant"))
        elif part.get("type") == "toolCall":
            arguments = part.get("arguments") if isinstance(part.get("arguments"), dict) else {}
            intent = part.get("intent") or arguments.get("i")
            name = part.get("name") or "tool"
            found.append(Evidence(source, f"{name}: {intent}" if intent else str(name), current, "tool"))
    return found


def background_tail(items: list[Evidence], limit: int) -> list[Evidence]:
    chosen: list[Evidence] = []
    used = 0
    for item in reversed(items):
        room = limit - used
        if len(item.text) <= room:
            chosen.append(item)
            used += len(item.text)
            continue
        if room > 0:
            chosen.append(replace(item, text=item.text[-room:]))
        break
    chosen.reverse()
    return chosen


def read_session(path: Path, start: datetime, end: datetime, context_chars: int = 0) -> Session | None:
    header: dict | None = None
    session_id = path.stem
    title = ""
    session: Session | None = None
    active = False
    before: deque[Evidence] = deque()
    kept = 0
    with path.open(encoding="utf-8", errors="replace") as handle:
        for number, line in enumerate(handle, start=1):
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
                session_id = str(entry.get("id") or path.stem)
                title = title or str(entry.get("title") or "")
                continue
            if kind != "message" or header is None:
                continue
            moment = entry_time(entry)
            message = entry.get("message")
            if moment is None or moment >= end or not isinstance(message, dict):
                continue
            role = message.get("role")
            # agent が書いた指示は role が user でも attribution が agent になるため role だけでの利用者の判定は不可
            if role not in ("user", "assistant") or (role == "user" and message.get("attribution") != "user"):
                continue
            current = moment >= start
            entry_id = entry.get("id")
            locator = entry_id if isinstance(entry_id, str) and entry_id else f"line-{number}"
            found = visible_evidence(f"{session_id}#{locator}", message, current)
            if not current:
                if session is None and context_chars > 0:
                    before.extend(found)
                    kept += sum(len(item.text) for item in found)
                    while len(before) > 1 and kept - len(before[0].text) >= context_chars:
                        kept -= len(before.popleft().text)
                continue
            if session is None:
                session = Session(session_id, title, str(header.get("cwd") or ""), path, moment, moment)
            session.first = min(session.first, moment)
            session.last = max(session.last, moment)
            session.evidence.extend(found)
            if role == "user":
                raw = text_of(message.get("content"))
                if isinstance(entry_id, str):
                    session.prompts.append(Prompt(entry_id, raw))
                active = active or bool(raw.strip())
            else:
                active = active or bool(found)
    if session is None or not active:
        return None
    session.title = title
    if context_chars > 0:
        session.evidence[:0] = background_tail(list(before), context_chars)
    return session


def sessions_in(root: Path, start: datetime, end: datetime, tz: tzinfo, context_chars: int = 0) -> list[Session]:
    found = []
    for path in sorted(root.glob("*/*.jsonl")):
        try:
            if datetime.fromtimestamp(path.stat().st_mtime, tz) < start:
                continue
        except OSError:
            continue
        session = read_session(path, start, end, context_chars)
        if session is not None:
            found.append(session)
    return sorted(found, key=lambda session: session.first)


def active_sessions(root: Path, start: datetime, end: datetime, tz: tzinfo) -> list[Session]:
    return [
        session
        for session in sessions_in(root, start, end, tz, BACKGROUND_CHARS)
        if any(item.current for item in session.evidence)
    ]


def project_root(cwd: str) -> str:
    result = run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    root = result.stdout.strip()
    return root if result.returncode == 0 and root else cwd


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
                "--no-tools", "--no-lsp", "--no-title", "--no-context-files",
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


def dump(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False)


def record_of(item: Evidence, text: str, part: str | None) -> dict[str, str]:
    record = {"source": item.source, "scope": "target" if item.current else "background", "role": item.kind, "text": text}
    if part is not None:
        record["part"] = part
    return record


def record_size(record: dict[str, str]) -> int:
    return len(dump(record)) + 1


def settled(build: Callable[..., list], *fixed: Any) -> list:
    # part と batch の表記の桁数が個数で変わるため一回の測定は不可
    total = 1
    while True:
        found = build(*fixed, total)
        if len(found) <= total:
            return found
        total = len(found)


def longest_fit(text: str, fits: Callable[[str], bool]) -> int:
    high = min(len(text), PIECE_CHARS)
    if fits(text[:high]):
        return high
    low, high = 0, high - 1
    while low < high:
        middle = (low + high + 1) // 2
        if fits(text[:middle]):
            low = middle
        else:
            high = middle - 1
    return low


def split_text(item: Evidence, limit: int, total: int) -> list[str]:
    part = f"{total}/{total}" if total > 1 else None
    pieces: list[str] = []
    rest = item.text
    while rest:
        size = longest_fit(rest, lambda piece: record_size(record_of(item, piece, part)) <= limit)
        if size == 0:
            raise JournalError(
                f"{item.source}: the session information leaves no room for a record in the {CHUNK_CHARS} character extraction input"
            )
        newline = rest.rfind("\n", 0, size)
        if size < len(rest) and newline >= size // 2:
            size = newline + 1
        pieces.append(rest[:size])
        rest = rest[size:]
    return pieces


def records_of(items: list[Evidence], limit: int) -> list[dict[str, str]]:
    records = []
    for item in items:
        pieces = settled(split_text, item, limit)
        for number, text in enumerate(pieces, start=1):
            records.append(record_of(item, text, f"{number}/{len(pieces)}" if len(pieces) > 1 else None))
    return records


def newest_within(records: list[dict[str, str]], limit: int) -> list[dict[str, str]]:
    kept: list[dict[str, str]] = []
    used = 0
    for record in reversed(records):
        used += record_size(record)
        if used > limit:
            break
        kept.append(record)
    kept.reverse()
    return kept


def grouped(
    session: Session, background: list[Evidence], target: list[Evidence], total: int
) -> list[list[dict[str, str]]]:
    # batch 番号が詰める前は未定のため header は最大の total/total での測定
    capacity = CHUNK_CHARS - len(extraction_material(session, total, total, []))
    # 背景が上限を使い切ると対象の断片が極小になるため背景の無制限は不可
    context = newest_within(records_of(background, capacity // 2), capacity // 2)
    room = capacity - sum(map(record_size, context))
    groups: list[list[dict[str, str]]] = []
    size = 0
    for record in records_of(target, room):
        cost = record_size(record)
        if not groups or size + cost > room:
            groups.append([])
            size = 0
        groups[-1].append(record)
        size += cost
    return [context + group for group in groups]


def batches(session: Session) -> list[list[dict[str, str]]]:
    background = [item for item in session.evidence if not item.current]
    target = [item for item in session.evidence if item.current]
    return settled(grouped, session, background, target)


def grounds_of(records: list[dict[str, str]]) -> Grounds:
    grounds: Grounds = {}
    for record in records:
        grounds.setdefault(record["source"], []).append(Ground(record["text"], record["scope"] == "target", True))
    return grounds


def extraction_material(session: Session, number: int, total: int, records: list[dict[str, str]]) -> str:
    header = {"session": session.id, "title": session.title, "cwd": session.cwd, "batch": f"{number}/{total}"}
    return "\n".join(dump(item) for item in [header, *records]) + "\n"


def parse_insights(output: str, origin: str) -> list[Any]:
    text = output.strip()
    fenced = FENCED_JSON.match(text)
    if fenced:
        text = fenced.group(1)
    try:
        data = json.loads(text)
    except ValueError:
        raise JournalError(f"{origin}: the model output is not JSON") from None
    if not isinstance(data, dict) or set(data) != {"insights"} or not isinstance(data["insights"], list):
        raise JournalError(f"{origin}: the model output is not an object with exactly an insights array")
    return data["insights"]


def cite(item: Any, grounds: Grounds, origin: str, supported_only: bool) -> Citation:
    if not isinstance(item, dict) or set(item) != {"source", "quote"}:
        raise JournalError(f"{origin}: an evidence item does not have exactly source and quote")
    source, quote = item["source"], item["quote"]
    if not isinstance(source, str) or not isinstance(quote, str):
        raise JournalError(f"{origin}: an evidence source and quote must be strings")
    if source not in grounds:
        raise JournalError(f"{origin}: an evidence source was not among the supplied records")
    quote = quote.strip()
    if not quote:
        raise JournalError(f"{origin}: an empty quotation for {source}")
    for ground in grounds[source]:
        if quote in ground.text and (ground.supported or not supported_only):
            return Citation(source, quote, ground.current)
    raise JournalError(f"{origin}: a quotation for {source} is not in the supplied text usable for its status")


def insight_of(item: Any, grounds: Grounds, origin: str) -> Insight:
    if not isinstance(item, dict) or set(item) != INSIGHT_KEYS:
        raise JournalError(f"{origin}: an insight does not have exactly the keys {sorted(INSIGHT_KEYS)}")
    texts = {}
    for key in INSIGHT_TEXTS:
        value = item[key]
        if not isinstance(value, str):
            raise JournalError(f"{origin}: insight {key} must be a string")
        value = value.strip()
        if not value and key != "caveats":
            raise JournalError(f"{origin}: insight {key} is empty")
        texts[key] = value
    texts["title"] = " ".join(texts["title"].split())
    if not isinstance(item["status"], str) or item["status"] not in STATUS_LABELS:
        raise JournalError(f"{origin}: insight status must be supported or hypothesis")
    if not isinstance(item["evidence"], list) or not item["evidence"]:
        raise JournalError(f"{origin}: an insight has no evidence")
    citations: list[Citation] = []
    for raw in item["evidence"]:
        citation = cite(raw, grounds, origin, item["status"] == "supported")
        if citation not in citations:
            citations.append(citation)
    if not any(citation.current for citation in citations):
        raise JournalError(f"{origin}: an insight cites only background records")
    return Insight(status=item["status"], evidence=citations, **texts)


def ask(options: argparse.Namespace, prompt: Path, material: str, grounds: Grounds, origin: str) -> list[Insight]:
    items = parse_insights(summarize(options, prompt, material), origin)
    return [insight_of(item, grounds, origin) for item in items]


def extract(options: argparse.Namespace, sessions: list[Session]) -> list[Insight]:
    found: list[Insight] = []
    for session in sessions:
        groups = batches(session)
        for number, records in enumerate(groups, start=1):
            origin = f"extract.md (session {session.id} batch {number}/{len(groups)})"
            material = extraction_material(session, number, len(groups), records)
            found += ask(options, PROMPTS / "extract.md", material, grounds_of(records), origin)
    return found


def synthesis_item(insight: Insight) -> dict[str, Any]:
    return {
        **{key: getattr(insight, key) for key in INSIGHT_TEXTS},
        "status": insight.status,
        "evidence": [
            {"source": citation.source, "quote": citation.quote, "scope": "target" if citation.current else "background"}
            for citation in insight.evidence
        ],
    }


def listing(items: list[dict[str, Any]]) -> str:
    return '{"insights": [\n' + ",\n".join(dump(item) for item in items) + "\n]}\n"


def listing_size(insights: list[Insight]) -> int:
    return len(listing([synthesis_item(insight) for insight in insights]))


def packed(insights: list[Insight]) -> list[list[Insight]]:
    budget = SYNTHESIS_CHARS - len(listing([]))
    groups: list[list[Insight]] = []
    size = 0
    for number, insight in enumerate(insights, start=1):
        cost = len(dump(synthesis_item(insight))) + 2
        if cost > budget:
            raise JournalError(f"insight candidate {number} alone exceeds the {SYNTHESIS_CHARS} character synthesis input")
        if not groups or size + cost > budget:
            groups.append([])
            size = 0
        groups[-1].append(insight)
        size += cost
    return groups


def merge(options: argparse.Namespace, insights: list[Insight]) -> list[Insight]:
    grounds: Grounds = {}
    for insight in insights:
        for citation in insight.evidence:
            grounds.setdefault(citation.source, []).append(Ground(citation.quote, citation.current, insight.status == "supported"))
    material = listing([synthesis_item(insight) for insight in insights])
    return ask(options, PROMPTS / "synthesize.md", material, grounds, "synthesize.md")


def synthesize(options: argparse.Namespace, insights: list[Insight]) -> list[Insight]:
    rounds = 0
    while insights:
        groups = packed(insights)
        if len(groups) == 1:
            return merge(options, groups[0])
        if rounds == REDUCTION_ROUNDS:
            raise JournalError(f"the insight candidates did not fit one synthesis input within {REDUCTION_ROUNDS} reduction rounds")
        rounds += 1
        merged = [insight for group in groups for insight in merge(options, group)]
        if listing_size(merged) >= listing_size(insights):
            raise JournalError("the reduction of the insight candidates did not shrink them")
        insights = merged
    return []


def prose(text: str) -> str:
    return HEADING_LINE.sub(r"\1\\#", text)


def quoted(citation: Citation) -> list[str]:
    # 引用中の backtick の連なりより短い fence では引用が fence を閉じるため固定長の fence は不可
    fence = "`" * max(3, max(map(len, BACKTICK_RUN.findall(citation.quote)), default=0) + 1)
    # Markdown が行末とする CRLF CR LF 以外での分割は引用の改変のため splitlines は不可
    body = [fence, *LINE_BREAK.split(citation.quote), fence]
    scope = "" if citation.current else "（対象の時間帯より前の記録）"
    return [*(f"> {line}" if line else ">" for line in body), ">", f"> — `{citation.source}`{scope}"]


def article(insight: Insight) -> list[str]:
    lines = ["", f"## {insight.title}", "", f"**状態**: {STATUS_LABELS[insight.status]}"]
    for label, body in (
        ("知見", insight.finding),
        ("説明", insight.explanation),
        ("適用", insight.application),
        ("注意", insight.caveats),
    ):
        if body:
            lines += ["", f"**{label}**: {prose(body)}"]
    lines += ["", "**根拠**:"]
    for citation in insight.evidence:
        lines += ["", *quoted(citation)]
    return lines


def render(machine: str, day: date, start: datetime, end: datetime, insights: list[Insight]) -> str:
    lines = [
        FORMAT_MARKER,
        f"# {day.isoformat()} {machine}",
        "",
        f"対象期間は {start:%Y-%m-%d %H:%M} から {end:%Y-%m-%d %H:%M} まで（{start.tzinfo}）である。",
        "",
        LIMITATION,
    ]
    if not insights:
        lines += ["", NO_INSIGHTS]
    for insight in insights:
        lines += article(insight)
    return "\n".join(lines) + "\n"


def compose(
    options: argparse.Namespace, machine: str, day: date, start: datetime, end: datetime, sessions: list[Session]
) -> str:
    return render(machine, day, start, end, synthesize(options, extract(options, sessions)))


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


def day_file_pattern(machine: str) -> re.Pattern[str]:
    return re.compile(rf"(\d{{4}})/(\d{{2}})(\d{{2}})/{re.escape(machine)}\.md")


def unfinished_days(journal: Path, machine: str, branch: str) -> list[date]:
    candidates = {
        entry[3:]
        for entry in git(journal, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames").stdout.split("\0")
        if len(entry) > 3
    }
    if git(journal, "rev-parse", "--verify", "--quiet", f"origin/{branch}", check=False).returncode == 0:
        candidates |= set(filter(None, git(journal, "diff", "--name-only", "-z", f"origin/{branch}", "HEAD").stdout.split("\0")))
    pattern = day_file_pattern(machine)
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


TEMPORARY_SUFFIX = ".tmp"
TEMPORARY_TOKEN = "[a-z0-9_]{8}"


@contextlib.contextmanager
def directory_lock(directory: Path):
    """directory の排他 flock の保持

    directory: lock する directory
    副作用: 保持の間の同じ directory の lock の待機
    失敗: OSError の送出
    不変条件: SIGKILL を含む process の終了での kernel による解放
    """
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def abandoned_temporaries(directory: Path, name: str) -> list[Path]:
    """name の公開が強制終了で残した一時 file の列挙

    directory: 公開先の directory
    name: 公開先の file 名
    戻り値: 名前が一時 file の形で通常 file かつ所有者が自分かつ mode が 0600 の file
    """
    pattern = re.compile(rf"\.{re.escape(name)}\.{TEMPORARY_TOKEN}{re.escape(TEMPORARY_SUFFIX)}")
    uid = os.getuid()
    found = []
    with os.scandir(directory) as entries:
        for entry in entries:
            if pattern.fullmatch(entry.name) is None:
                continue
            status = entry.stat(follow_symlinks=False)
            if stat.S_ISREG(status.st_mode) and status.st_uid == uid and stat.S_IMODE(status.st_mode) == 0o600:
                found.append(Path(entry.path))
    return found


def discard_abandoned_temporaries(directory: Path, name: str) -> None:
    """name の公開が強制終了で残した一時 file の除去

    directory: 公開先の directory
    name: 公開先の file 名
    前提: directory の排他 flock の保持
    副作用: 列挙した一時 file の削除
    """
    for abandoned in abandoned_temporaries(directory, name):
        abandoned.unlink(missing_ok=True)


def atomic_write(path: Path, document: str) -> None:
    """path の内容の原子的な置換

    path: 置換先の file
    document: 置換後の本文
    副作用: path の親 directory の作成
    副作用: 公開の間の親 directory の排他 flock の保持
    副作用: 同じ path の強制終了が残した一時 file の除去
    失敗: OSError の送出
    不変条件: 置換前か置換後の完全な内容だけの公開
    不変条件: 例外と SIGTERM による中断での一時 file の削除の試行
    不変条件: 残った一時 file の同じ path の次の公開での除去
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    # 名前だけでの除去は並走する公開の一時 file を巻込むため強制終了でも kernel が放す親 directory の flock が必須
    with directory_lock(path.parent):
        discard_abandoned_temporaries(path.parent, path.name)
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", suffix=TEMPORARY_SUFFIX, delete=False
        )
        try:
            with handle:
                handle.write(document)
            os.replace(handle.name, path)
        except BaseException:
            # 元の例外を隠すため後片付けの失敗の送出は不可
            with contextlib.suppress(OSError):
                os.unlink(handle.name)
            raise


def real_directories(parent: Path, pattern: str) -> list[Path]:
    """名前が pattern に全て合う実 directory の列挙

    parent: 列挙する directory
    pattern: 子の名前に全て合う正規表現
    戻り値: 名前順の子 directory
    不変条件: symlink の子の除外
    """
    with os.scandir(parent) as entries:
        return sorted(
            Path(entry.path)
            for entry in entries
            if re.fullmatch(pattern, entry.name) and entry.is_dir(follow_symlinks=False)
        )


def is_calendar_day(year: str, month_day: str) -> bool:
    """実在の暦日の判定

    year: 年の 4 桁
    month_day: 月日の 4 桁
    戻り値: 実在の暦日のときの真
    """
    try:
        date(int(year), int(month_day[:2]), int(month_day[2:]))
    except ValueError:
        return False
    return True


def recover_abandoned_days(journal: Path, machine: str) -> list[str]:
    """日付 directory に残った machine の日誌の一時 file の除去

    journal: 日誌の checkout の root
    machine: 対象の機械名
    戻り値: 除去に失敗した directory と原因の説明の列
    副作用: lookback の外を含む実在の暦日の <yyyy>/<MMdd> の directory での強制終了が残した一時 file の除去
    不変条件: symlink の年と日の directory の非追従
    不変条件: 他の機械の日誌と名前の形が異なる file と旧来の無名の一時 file の維持
    """
    name = f"{machine}.md"
    failures = []
    try:
        years = real_directories(journal, "[0-9]{4}")
    except OSError as error:
        return [f"{journal}: {error}"]
    for year in years:
        try:
            days = real_directories(year, "[0-9]{4}")
        except OSError as error:
            failures.append(f"{year}: {error}")
            continue
        for directory in days:
            if not is_calendar_day(year.name, directory.name):
                continue
            try:
                if abandoned_temporaries(directory, name):
                    with directory_lock(directory):
                        discard_abandoned_temporaries(directory, name)
            except OSError as error:
                failures.append(f"{directory}: {error}")
    return failures


def commit(journal: Path, relative: str, day: date) -> None:
    git(journal, "add", "--", relative)
    if git(journal, "diff", "--cached", "--quiet", "--", relative, check=False).returncode != 0:
        git(journal, "commit", "--quiet", "-m", f"docs: {day.isoformat()} の日誌", "--", relative)


def publish(journal: Path, branch: str, relative: str) -> None:
    git(journal, "push", "--quiet", "origin", f"HEAD:{branch}")
    # remote の内容が公開の正本のため push の終了 status による判定は不可
    if blob(journal, f"origin/{branch}", relative) != (journal / relative).read_bytes():
        raise JournalError(f"{relative} is not at origin/{branch} with the expected content after the push")


def has_format_marker(body: bytes) -> bool:
    return body.split(b"\n", 1)[0].strip() == FORMAT_MARKER.encode("utf-8")


def legacy_error(relative: str) -> JournalError:
    return JournalError(
        f"{relative} is a legacy-format journal that is not published; "
        "review a regenerated document with --preview --date and rebuild this day with --date"
    )


def require_current_format(journal: Path, relative: str) -> None:
    if not has_format_marker((journal / relative).read_bytes()):
        raise legacy_error(relative)


def require_current_formats(journal: Path, branch: str) -> None:
    # push が HEAD の未公開 commit を全て送るため公開する日だけの形式確認は不可
    if git(journal, "rev-parse", "--verify", "--quiet", f"origin/{branch}", check=False).returncode == 0:
        names = git(journal, "diff", "--name-only", "-z", f"origin/{branch}", "HEAD").stdout
    else:
        names = git(journal, "ls-tree", "-r", "--name-only", "-z", "HEAD").stdout
    pattern = re.compile(r"([0-9]{4})/([0-9]{4})/[A-Za-z0-9][A-Za-z0-9._-]*\.md")
    for relative in sorted(filter(None, names.split("\0"))):
        match = pattern.fullmatch(relative)
        if match is None or not is_calendar_day(*match.groups()):
            continue
        body = blob(journal, "HEAD", relative)
        if body is not None and not has_format_marker(body):
            raise legacy_error(relative)


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
    parser.add_argument(
        "--preview", action="store_true", help="--date の日の日誌を標準出力へ出す。日誌の checkout には触れず、書込も公開もしない"
    )
    options = parser.parse_args(argv)
    if options.preview and options.date is None:
        parser.error("--preview requires --date")
    return options


def preview(options: argparse.Namespace, tz: ZoneInfo) -> int:
    day = options.date
    start, end = window(day, tz, options.start_hour)
    try:
        sessions = active_sessions(options.sessions_root, start, end, tz)
        if not sessions:
            print(f"{day}: omp の作業はない", file=sys.stderr)
            return 0
        document = compose(options, options.machine_name, day, start, end, sessions)
    except JournalError as error:
        print(f"dotfiles-agent-journal: {day}: {error}", file=sys.stderr)
        return 1
    sys.stdout.write(document)
    return 0


def main(argv: list[str] | None = None, now: datetime | None = None) -> int:
    options = parse(argv)
    tz = ZoneInfo(options.timezone)
    if options.preview:
        return preview(options, tz)
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
    unrecovered = recover_abandoned_days(journal, machine)
    for failure in unrecovered:
        print(f"dotfiles-agent-journal: could not remove an abandoned temporary in {failure}", file=sys.stderr)
    failed = []
    for day in days:
        path = output_path(journal, day, machine)
        relative = str(path.relative_to(journal))
        start, end = window(day, tz, options.start_hour)
        try:
            stage = Stage.ABSENT if options.date else stage_of(journal, relative, branch)
            entered = stage
            if stage is Stage.ABSENT:
                sessions = active_sessions(options.sessions_root, start, end, tz)
                if not sessions:
                    print(f"{day}: omp の作業はない")
                    continue
                atomic_write(path, compose(options, machine, day, start, end, sessions))
                stage = stage_of(journal, relative, branch)
            if stage in (Stage.GENERATED, Stage.COMMITTED):
                require_current_format(journal, relative)
            if stage is Stage.GENERATED:
                commit(journal, relative, day)
                stage = Stage.COMMITTED
            if stage is Stage.COMMITTED:
                require_current_formats(journal, branch)
                publish(journal, branch, relative)
        except (JournalError, OSError) as error:
            print(f"dotfiles-agent-journal: {day}: {error}", file=sys.stderr)
            failed.append(day)
            continue
        if entered is Stage.ABSENT:
            print(f"{day}: 技術的な知見を記録した")
        elif entered is Stage.GENERATED:
            print(f"{day}: 生成済みの日誌を commit して公開した")
        else:
            print(f"{day}: commit 済みの日誌を公開した")
    return 1 if failed or unrecovered else 0


if __name__ == "__main__":
    # 既定の SIGTERM は一時 directory と model の子を残すため既定動作は不可
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(128 + signal.SIGTERM))
    sys.exit(main())
