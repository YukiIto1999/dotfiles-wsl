"""omp の session 記録から利用者の訂正、決定、好みを取り出し、project memory へ保存する。"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from journal import JournalError, Session, chunks, clip, project_root, sessions_in, summarize

PROG = "dotfiles-agent-memory-harvest"
PROMPT = Path(__file__).resolve().parent / "prompt.md"
KINDS = ("correction", "decision", "preference")
MEMORY_TIMEOUT_SECONDS = 120
# client が利用者の発言へ差し込む block。利用者の言葉ではないため model へ渡さない
INJECTED = re.compile(r"<(project_memory|system-reminder)\b[^>]*>.*?</\1\s*>", re.DOTALL | re.IGNORECASE)
# 再び確かめても結果が変わらない status の失敗。receipt を捨て、失敗として一度だけ報告する
TERMINAL = ("invalid_input", "not_found", "not_verified", "retain_failed")


class HarvestError(Exception):
    pass


class MemoryCommandError(HarvestError):
    def __init__(self, command: str, code: str, detail: str):
        self.code = code
        super().__init__(f"dotfiles-memory {command} failed: {detail}")


@dataclass
class Message:
    source: str
    cwd: str
    text: str


def memory(options: argparse.Namespace, command: str, request: dict | None = None, *arguments: str) -> dict:
    try:
        result = subprocess.run(
            [options.memory, command, *arguments],
            input="" if request is None else json.dumps(request, ensure_ascii=False),
            capture_output=True,
            text=True,
            timeout=MEMORY_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MemoryCommandError(command, "unavailable", str(error)) from None
    if result.returncode != 0:
        detail = result.stderr.strip()
        # dotfiles-memory は失敗を `project-memory: <code>: <detail>` の形で書く
        code = detail.splitlines()[0].removeprefix("project-memory: ").split(":", 1)[0] if detail else ""
        raise MemoryCommandError(command, code, detail[-500:])
    try:
        value = json.loads(result.stdout)
    except ValueError:
        value = None
    if not isinstance(value, dict):
        raise HarvestError(f"dotfiles-memory {command} did not print one JSON object")
    return value


def load_state(path: Path, now: datetime, lookback_days: int) -> dict:
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"since": (now - timedelta(days=lookback_days)).isoformat(), "pending": []}
    except (OSError, ValueError) as error:
        raise HarvestError(f"{path} could not be read: {error}") from None
    try:
        valid = isinstance(state["pending"], list) and datetime.fromisoformat(state["since"]).tzinfo is not None
    except (KeyError, TypeError, ValueError):
        valid = False
    if not valid:
        raise HarvestError(f"{path} is not a harvest state")
    return state


def store_state(path: Path, state: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
            json.dump(state, handle, ensure_ascii=False, indent=2)
        os.replace(handle.name, path)
    except OSError as error:
        raise HarvestError(f"{path} could not be written: {error}") from None


def report(receipt: dict) -> None:
    identity = f"operation_id={receipt['operation_id']} document_id={receipt['document_id']}"
    if receipt["state"] == "saved":
        print(f"saved: {receipt['source']} {identity}")
    else:
        print(f"{receipt['state']}: {receipt['source']} {identity}（保存を確認していない）")


def confirm(options: argparse.Namespace, pending: list[dict]) -> tuple[list[dict], int]:
    remaining: list[dict] = []
    failures = 0
    for receipt in pending:
        request = {key: receipt[key] for key in ("cwd", "scope", "operation_id", "document_id")}
        try:
            state = memory(options, "status", request).get("state")
        except MemoryCommandError as error:
            print(f"{PROG}: {receipt['source']}: {error}", file=sys.stderr)
            failures += 1
            if error.code not in TERMINAL:
                remaining.append(receipt)
            continue
        if state not in ("saved", "pending"):
            raise HarvestError("dotfiles-memory status returned an unknown state")
        receipt = {**receipt, "state": state}
        report(receipt)
        if state != "saved":
            remaining.append(receipt)
    return remaining, failures


def normalized(text: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", text).split())


def curated(options: argparse.Namespace, cwd: str) -> list[dict]:
    memories = memory(options, "curated", {"cwd": cwd, "scope": "project"}).get("memories")
    if not isinstance(memories, list) or not all(
        isinstance(item, dict) and isinstance(item.get("content"), str) for item in memories
    ):
        raise HarvestError("dotfiles-memory curated did not list memories")
    return memories


def messages_of(sessions: list[Session], stored: set[str]) -> list[Message]:
    found = []
    for session in sessions:
        for prompt in session.prompts:
            source = f"{session.path}#{prompt.id}"
            text = INJECTED.sub("", prompt.text).strip()
            if text and source not in stored:
                found.append(Message(source, session.cwd, clip(text)))
    return found


def candidates(answer: str, messages: dict[str, Message]) -> list[tuple[Message, str, str, str]]:
    text = answer.strip()
    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", text, re.DOTALL)
    try:
        value = json.loads(fenced.group(1) if fenced else text)
    except ValueError:
        value = None
    if not isinstance(value, list):
        raise HarvestError("the model did not answer a JSON array")
    found = []
    for item in value:
        if not isinstance(item, dict):
            raise HarvestError("the model answered a candidate that is not an object")
        message = messages.get(item.get("ref"))
        kind = item.get("kind")
        content = item.get("content")
        if message is None or kind not in KINDS or not isinstance(content, str) or not content.strip():
            raise HarvestError(f"the model answered an invalid candidate: ref={item.get('ref')!r} kind={kind!r}")
        # 将来の場面は保存の判定にだけ使う。書けなかった候補は空として返し、呼び出し側が捨てる
        situation = item.get("situation")
        found.append((message, kind, content.strip(), situation.strip() if isinstance(situation, str) else ""))
    return found


def receipt_of(value: dict, message: Message) -> dict:
    state = value.get("state")
    operation_id = value.get("operation_id")
    document_id = value.get("document_id")
    if state not in ("saved", "pending", "indeterminate") or not isinstance(operation_id, str) or not isinstance(document_id, str):
        raise HarvestError("dotfiles-memory save returned an invalid receipt")
    return {
        "state": state,
        "source": message.source,
        "cwd": message.cwd,
        "scope": "project",
        "operation_id": operation_id,
        "document_id": document_id,
    }


def harvest_project(options: argparse.Namespace, sessions: list[Session], pending: list[dict]) -> None:
    cwd = sessions[0].cwd
    existing = curated(options, cwd)
    # 保存済みの発言は送り直さない。失敗した実行を繰り返しても同じ発言から記憶を二つ作らない
    stored = {item["source"] for item in existing if isinstance(item.get("source"), str)}
    stored |= {receipt["source"] for receipt in pending}
    known = {normalized(item["content"]) for item in existing}
    messages = {f"m{index}": message for index, message in enumerate(messages_of(sessions, stored), start=1)}
    if not messages:
        return
    memories = "\n".join(f"- ({item.get('kind')}) {clip(item['content'])}" for item in existing) or "なし"
    for part in chunks([f"[{ref}] {message.text}" for ref, message in messages.items()]):
        material = f"project: {project_root(cwd)}\n\n## 保存済みの記憶\n{memories}\n\n## 利用者の発言\n{part}"
        for message, kind, content, situation in candidates(summarize(options, PROMPT, material), messages):
            if not situation:
                print(f"no-situation: {message.source}")
                continue
            if normalized(content) in known:
                print(f"duplicate: {message.source}")
                continue
            try:
                value = memory(options, "save", {
                    "cwd": message.cwd,
                    "content": content,
                    "source": message.source,
                    "scope": "project",
                    "kind": kind,
                })
            except MemoryCommandError as error:
                # 資格情報や個人情報に見える候補は保存しない。次の実行でも同じ理由で拒まれる
                if error.code != "privacy":
                    raise
                print(f"rejected: {message.source}: {error.code}")
                continue
            known.add(normalized(content))
            receipt = receipt_of(value, message)
            report(receipt)
            if receipt["state"] != "saved":
                pending.append(receipt)


def harvest(options: argparse.Namespace, state: dict, since: datetime, until: datetime) -> int:
    projects: dict[str, list[Session]] = {}
    for session in sessions_in(options.sessions_root, since, until, timezone.utc):
        if not session.prompts:
            continue
        try:
            bank = memory(options, "project", None, session.cwd).get("bank_id")
        except MemoryCommandError as error:
            if error.code != "invalid_input":
                raise
            print(f"skipped: {session.path}: {session.cwd} は Git の project ではない")
            continue
        if not isinstance(bank, str):
            raise HarvestError("dotfiles-memory project did not print a bank")
        projects.setdefault(bank, []).append(session)
    failures = 0
    for sessions in projects.values():
        try:
            harvest_project(options, sessions, state["pending"])
        except (HarvestError, JournalError) as error:
            print(f"{PROG}: {sessions[0].cwd}: {error}", file=sys.stderr)
            failures += 1
        # 送った保存の receipt は失敗した実行でも残し、次の実行で確かめる
        store_state(options.state_file, state)
    return failures


def parse(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog=PROG, description=__doc__)
    parser.add_argument("--sessions-root", required=True, type=Path)
    parser.add_argument("--state-file", required=True, type=Path)
    parser.add_argument("--lookback-days", required=True, type=int, help="初回に読む日数")
    parser.add_argument("--memory", required=True)
    parser.add_argument("--omp", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--thinking", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, now: datetime | None = None) -> int:
    options = parse(argv)
    until = now or datetime.now(timezone.utc)
    try:
        state = load_state(options.state_file, until, options.lookback_days)
        state["pending"], unconfirmed = confirm(options, state["pending"])
        store_state(options.state_file, state)
        failed = harvest(options, state, datetime.fromisoformat(state["since"]), until)
        # 読み終えた位置は全 project の取り出しが成功した場合だけ進める。失敗した範囲は次の実行が読み直す
        if not failed:
            state["since"] = until.isoformat()
            store_state(options.state_file, state)
    except HarvestError as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        return 1
    return 1 if unconfirmed or failed else 0


if __name__ == "__main__":
    sys.exit(main())
