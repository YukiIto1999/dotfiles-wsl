import errno
import fcntl
import io
import json
import os
import re
import resource
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo
from xml.etree import ElementTree

PACKAGE = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(PACKAGE))
import journal

TZ = ZoneInfo("Asia/Tokyo")
DAY = date(2026, 9, 23)
HOST = "testhost"
DAY_FILE = "2026/0923/testhost.md"
LEGACY_FILE = "2026/0922/testhost.md"
DEADLINE = "DOTFILES_JOB_DEADLINE"
MARKER = "<!-- agent-journal: technical-insights-v1 -->"
SESSION_A = "01a0caa2-0000-7000-8000-000000000001"
SESSION_B = "02b0cbb3-0000-7000-8000-000000000002"
SESSION_C = "03c0ccc4-0000-7000-8000-000000000003"
SESSION_D = "04d0cdd5-0000-7000-8000-000000000004"
SESSION_E = "05e0cee6-0000-7000-8000-000000000005"


def local(value: str) -> datetime:
    return datetime.fromisoformat(value).replace(tzinfo=TZ)


def stamp(value: str) -> str:
    return local(value).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def source(session_id: str, entry_id: str) -> str:
    return f"{session_id}#{entry_id}"


def record(entry_id: str | None, at: str, message: dict) -> dict:
    found = {"type": "message", "timestamp": stamp(at), "message": message}
    if entry_id is not None:
        found["id"] = entry_id
    return found


def user(entry_id: str | None, at: str, text: str, attribution: str | None = "user") -> dict:
    message = {"role": "user", "content": [{"type": "text", "text": text}]}
    if attribution is not None:
        message["attribution"] = attribution
    return record(entry_id, at, message)


def text_part(text: str) -> dict:
    return {"type": "text", "text": text}


def assistant(entry_id: str | None, at: str, parts: list) -> dict:
    return record(entry_id, at, {"role": "assistant", "content": parts, "stopReason": "stop"})


def tool_result(entry_id: str | None, at: str, text: str) -> dict:
    return record(entry_id, at, {"role": "toolResult", "toolName": "read", "content": [text_part(text)]})


def write_session(
    root: Path, bucket: str, session_id: str, cwd: Path, title: str, entries: list, modified: str | None = None
) -> Path:
    directory = root / bucket
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"2026-09-23T00-00-00-000Z_{session_id}.jsonl"
    lines = [
        {"type": "title", "v": 1, "title": title, "source": "auto"},
        {"type": "session", "version": 3, "id": session_id, "timestamp": entries[0]["timestamp"], "cwd": str(cwd)},
        *entries,
    ]
    path.write_text("".join(json.dumps(line, ensure_ascii=False) + "\n" for line in lines), encoding="utf-8")
    last = (
        local(modified).timestamp()
        if modified
        else datetime.fromisoformat(entries[-1]["timestamp"].replace("Z", "+00:00")).timestamp()
    )
    os.utime(path, (last, last))
    return path


# model が受け取らない記録と、受け取ってはならない内容。どれも引用すれば捏造になる
HIDDEN_REASONING = "内部推論の秘密"
TOOL_ARGUMENT = "ツール引数の秘密"
TOOL_OUTPUT = "ツール結果の本文"
INJECTED_MEMORY = "注入された記憶"
AGENT_INSTRUCTION = "エージェントが書いた指示"
SUBAGENT_TEXT = "サブエージェントの本文"
NEXT_DAY = "翌日の依頼"
# 対象の記録。ID と、その記録に実在する引用の組
FINAL_DECISION = "最終応答の決定"
TOOL_INTENT = "Editing bootstrap"
BESIDE_INJECTION = "注入の隣の本文"
A_PREVIOUS = (source(SESSION_A, "a0000001"), "前日の依頼")
A_BOUNDARY = (source(SESSION_A, "a0000002"), "境界の依頼")
A_INTERIM = (source(SESSION_A, "a0000003"), "途中の説明")
A_FINAL = (source(SESSION_A, "a0000005"), "窓の終了時刻は含めず開始時刻は含める")
A_BESIDE = (source(SESSION_A, "a0000007"), BESIDE_INJECTION)
B_REQUEST = (source(SESSION_B, "b0000001"), "別プロジェクトの依頼")
C_REQUEST = (source(SESSION_C, "c0000001"), "前々日の依頼")


def insight(title: str, *evidence: tuple[str, str], status: str = "supported") -> dict:
    return {
        "title": title,
        "finding": f"{title}という知見",
        "explanation": f"{title}に至った経緯",
        "application": f"{title}が使える場面",
        "caveats": "",
        "status": status,
        "evidence": [{"source": cited, "quote": quote} for cited, quote in evidence],
    }


INSIGHT_0921 = insight("前々日の知見", C_REQUEST)
INSIGHT_0922 = insight("前日の知見", A_PREVIOUS)
INSIGHT_0923 = insight("境界の知見", A_BOUNDARY, A_FINAL)
# 後の日の材料は前の日の発言を背景として含む。先に当てはまる rule が選ばれるため新しい日の根拠を先に並べる
ROUTES = ((A_BOUNDARY[1], INSIGHT_0923), (A_PREVIOUS[1], INSIGHT_0922), (C_REQUEST[1], INSIGHT_0921))
# 旧形式の日誌。format marker を持たない
LEGACY = "# 2026-09-22 testhost\n\n| project | session | request | 費用 (USD) |\n|---|---|---|---|\n| sample | 1 | 3 | 0.875 |\n"

# journal が呼ぶ omp の代わり。system prompt の file 名で extract と synthesize を区別し、
# 試験が書いた script の最初に当てはまる rule の応答をそのまま返す。意味の良し悪しは判定しない
FAKE_OMP = """\
import json, os, sys
from pathlib import Path

argv = sys.argv[1:]
stage = Path(argv[argv.index("--system-prompt") + 1]).stem
material = sys.stdin.read()
with open(os.environ["FAKE_OMP_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"stage": stage, "argv": argv, "material": material}, ensure_ascii=False) + "\\n")


def present(marker):
    return marker in material or json.dumps(marker)[1:-1] in material


def merged(title):
    supplied = json.loads(material[material.index("{"):])["insights"]
    evidence = []
    for found in supplied:
        for item in found["evidence"]:
            cited = {"source": item["source"], "quote": item["quote"]}
            if cited not in evidence:
                evidence.append(cited)
    return {"insights": [{
        "title": title, "finding": "統合", "explanation": "統合", "application": "統合",
        "caveats": "", "status": "supported", "evidence": evidence,
    }]}


for rule in json.loads(Path(os.environ["FAKE_OMP_SCRIPT"]).read_text(encoding="utf-8")).get(stage, []):
    if rule.get("when") is not None and not present(rule["when"]):
        continue
    if rule.get("fail"):
        sys.exit("model unavailable")
    reply = merged(rule["merge"]) if rule.get("merge") else rule["reply"]
    print(reply if isinstance(reply, str) else json.dumps(reply, ensure_ascii=False))
    break
else:
    print(json.dumps({"insights": []}))
"""


def git(*args: str, cwd: Path | None = None, env: dict | None = None) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True
    ).stdout.strip()


SIZE_LIMIT = 16


@contextmanager
def file_size_limit(limit: int):
    soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (limit, hard))
    try:
        yield
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, (soft, hard))


PUBLISHER = """\
import os, sys, time
from pathlib import Path
package, target, document, ready, release, started = sys.argv[1:7]
sys.path.insert(0, package)
import journal
if ready:
    replace = os.replace
    def held(source, destination):
        Path(ready).write_text(source, encoding="utf-8")
        while not Path(release).exists():
            time.sleep(0.01)
        replace(source, destination)
    os.replace = held
if started:
    Path(started).write_text("started", encoding="utf-8")
journal.atomic_write(Path(target), document)
"""


def reap(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.kill()
    process.wait()


def start_publisher(
    test: unittest.TestCase, target: Path, document: str, ready: Path | None = None, release: Path | None = None, started: Path | None = None
) -> subprocess.Popen:
    process = subprocess.Popen([
        sys.executable, "-c", PUBLISHER, str(PACKAGE), str(target), document,
        str(ready or ""), str(release or ""), str(started or ""),
    ])
    test.addCleanup(reap, process)
    return process


def wait_for(path: Path, process: subprocess.Popen) -> str:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size > 0:
            return path.read_text(encoding="utf-8")
        if process.poll() is not None:
            raise AssertionError(f"the publisher exited with {process.returncode} before writing {path}")
        time.sleep(0.01)
    raise AssertionError(f"{path} was not written")


class JournalTest(unittest.TestCase):
    def setUp(self):
        self.workspace = Path(tempfile.mkdtemp(prefix="agent-journal-test-"))
        os.environ["GIT_CONFIG_GLOBAL"] = str(self.workspace / "gitconfig")
        (self.workspace / "gitconfig").write_text("[init]\n\tdefaultBranch = main\n")
        for key, value in {
            "GIT_AUTHOR_NAME": "journal",
            "GIT_AUTHOR_EMAIL": "journal@example.invalid",
            "GIT_COMMITTER_NAME": "journal",
            "GIT_COMMITTER_EMAIL": "journal@example.invalid",
        }.items():
            os.environ[key] = value

        # model を Git の work tree の中で呼ばないことの検査に使う
        self.project = self.workspace / "projects" / "sample"
        self.project.mkdir(parents=True)
        git("init", "-q", cwd=self.project)
        self.scratch = self.workspace / "scratch"
        self.scratch.mkdir()

        self.sessions = self.workspace / "sessions"
        path_a = write_session(self.sessions, "-projects-sample", SESSION_A, self.project, "境界の作業", [
            user("a0000001", "2026-09-23T05:59:59", A_PREVIOUS[1]),
            user("a0000002", "2026-09-23T06:00:00", A_BOUNDARY[1]),
            assistant("a0000003", "2026-09-23T06:01:00", [
                {"type": "thinking", "thinking": HIDDEN_REASONING},
                text_part(A_INTERIM[1]),
                {
                    "type": "toolCall", "name": "edit", "intent": TOOL_INTENT,
                    "arguments": {"path": TOOL_ARGUMENT, "i": TOOL_INTENT},
                },
            ]),
            tool_result("a0000004", "2026-09-23T06:02:00", TOOL_OUTPUT),
            assistant("a0000005", "2026-09-23T06:03:00", [text_part(f"{FINAL_DECISION}：{A_FINAL[1]}")]),
            user("a0000007", "2026-09-23T06:04:00", f"<project_memory>\n{INJECTED_MEMORY}\n</project_memory>\n{BESIDE_INJECTION}"),
            user("a0000008", "2026-09-23T06:05:00", AGENT_INSTRUCTION, attribution="agent"),
            user("a0000006", "2026-09-24T06:00:00", NEXT_DAY),
        ])
        # subagent の記録も session と同じ形で親 session の隣の directory に置かれる
        write_session(self.sessions, f"-projects-sample/{path_a.stem}", "Scout", self.project, "subagent", [
            user("s0000001", "2026-09-23T07:00:00", SUBAGENT_TEXT),
        ])
        write_session(self.sessions, "--tmp--", SESSION_B, self.scratch, "別の作業", [
            user("b0000001", "2026-09-23T23:00:00", B_REQUEST[1]),
            assistant("b0000002", "2026-09-23T23:01:00", [text_part("別プロジェクトの応答")]),
        ])
        write_session(self.sessions, "-projects-sample", SESSION_C, self.project, "前々日の作業", [
            user("c0000001", "2026-09-21T12:00:00", C_REQUEST[1]),
        ])

        self.calls_log = self.workspace / "calls.jsonl"
        self.script_file = self.workspace / "script.json"
        for name, value in (("FAKE_OMP_LOG", self.calls_log), ("FAKE_OMP_SCRIPT", self.script_file)):
            os.environ[name] = str(value)
            self.addCleanup(os.environ.pop, name, None)
        self.fake_omp = self.workspace / "omp"
        self.fake_omp.write_text(f"#!{sys.executable}\n{FAKE_OMP}")
        self.fake_omp.chmod(0o755)
        self.script = {
            stage: [{"when": marker, "reply": {"insights": [found]}} for marker, found in ROUTES]
            for stage in ("extract", "synthesize")
        }
        self.save_script()

        self.remote = self.workspace / "remote.git"
        git("init", "-q", "--bare", str(self.remote))
        self.journal = self.workspace / "agent-journal"
        git("clone", "-q", str(self.remote), str(self.journal))

    def arguments(self, *extra: str, journal_dir: Path | None = None) -> list[str]:
        return [
            "--sessions-root", str(self.sessions),
            "--journal-dir", str(journal_dir or self.journal),
            "--machine-name", HOST,
            "--timezone", "Asia/Tokyo",
            "--start-hour", "6",
            "--lookback-days", "7",
            "--omp", str(self.fake_omp),
            "--model", "fake/model",
            "--thinking", "low",
            *extra,
        ]

    def run_journal(self, *extra: str, now: datetime | None = None, status: int = 0) -> None:
        self.assertEqual(journal.main(self.arguments(*extra), now=now), status)

    def captured(
        self, *extra: str, journal_dir: Path | None = None, now: datetime | None = None
    ) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = journal.main(self.arguments(*extra, journal_dir=journal_dir), now=now)
        return status, out.getvalue(), err.getvalue()

    def save_script(self) -> None:
        self.script_file.write_text(json.dumps(self.script, ensure_ascii=False), encoding="utf-8")

    @staticmethod
    def route(marker: str, reply) -> list[dict]:
        return [{"when": marker, "reply": reply}]

    def calls(self, stage: str | None = None) -> list[dict]:
        if not self.calls_log.exists():
            return []
        found = [json.loads(line) for line in self.calls_log.read_text(encoding="utf-8").split("\n") if line]
        return [call for call in found if stage is None or call["stage"] == stage]

    def mentions(self, marker: str) -> int:
        return sum(marker in call["material"] for call in self.calls())

    @staticmethod
    def parts(call: dict) -> tuple[dict, list[dict]]:
        head, *rest = call["material"].split("\n")
        return json.loads(head), [json.loads(line) for line in rest if line.strip()]

    def published(self) -> list[str]:
        return git("--git-dir", str(self.remote), "ls-tree", "-r", "--name-only", "main").splitlines()

    def remote_file(self, relative: str) -> str | None:
        shown = subprocess.run(
            ["git", "--git-dir", str(self.remote), "show", f"main:{relative}"], capture_output=True, text=True
        )
        return shown.stdout if shown.returncode == 0 else None

    def remote_commit(self, relative: str) -> str:
        return git("--git-dir", str(self.remote), "log", "-1", "--format=%H", "main", "--", relative)

    def local_commit(self, relative: str) -> str:
        return git("log", "-1", "--format=%H", "--", relative, cwd=self.journal)

    def committed(self, relative: str) -> bool:
        return subprocess.run(
            ["git", "-C", str(self.journal), "cat-file", "-e", f"HEAD:{relative}"], capture_output=True
        ).returncode == 0

    @staticmethod
    def tree(root: Path) -> dict[str, bytes | None]:
        return {
            str(path.relative_to(root)): path.read_bytes() if path.is_file() else None
            for path in sorted(root.rglob("*"))
        }

    def state(self) -> dict:
        """公開済みの DAY の日誌について、local と remote の観測できる全ての状態"""
        target = self.journal / DAY_FILE
        return {
            "file": target.read_bytes(),
            "directory": sorted(path.name for path in target.parent.iterdir()),
            "head": git("rev-parse", "HEAD", cwd=self.journal),
            "worktree": git("status", "--porcelain", cwd=self.journal),
            "remote": git("--git-dir", str(self.remote), "rev-parse", "main"),
            "remote file": self.remote_file(DAY_FILE),
        }

    def refuses(self, extract: list, synthesize: list | None = None) -> str:
        """model の出力を差し替えた DAY の再生成が失敗し、公開済みの日誌も remote も変わらないことの確認"""
        before = self.state()
        self.script["extract"] = extract
        self.script["synthesize"] = synthesize or []
        self.save_script()
        errors = io.StringIO()

        with redirect_stderr(errors):
            self.run_journal("--date", DAY.isoformat(), status=1)

        self.assertIn(DAY.isoformat(), errors.getvalue())
        self.assertEqual(self.state(), before)
        return errors.getvalue()

    def seed_legacy(self, committed: bool = False, published: bool = False) -> Path:
        path = self.journal / LEGACY_FILE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(LEGACY, encoding="utf-8")
        if committed or published:
            git("add", "--", LEGACY_FILE, cwd=self.journal)
            git("commit", "-q", "-m", "docs: 旧形式の日誌", cwd=self.journal)
        if published:
            git("push", "-q", "origin", "HEAD:main", cwd=self.journal)
        return path

    def test_the_window_decides_what_the_model_sees_and_the_validated_insight_is_published(self):
        self.run_journal("--date", DAY.isoformat())

        # 記録は session ごとの batch で渡る。対象の時間帯より前は背景、後や終了の瞬間は含まれない
        extract = self.calls("extract")
        self.assertEqual([self.parts(call)[0]["session"] for call in extract], [SESSION_A, SESSION_B])
        records = self.parts(extract[0])[1]
        self.assertEqual({found["source"]: found["scope"] for found in records}, {
            A_PREVIOUS[0]: "background",
            A_BOUNDARY[0]: "target",
            A_INTERIM[0]: "target",
            A_FINAL[0]: "target",
            A_BESIDE[0]: "target",
        })
        beside = next(found for found in records if found["source"] == A_BESIDE[0])
        self.assertEqual(beside["text"].strip(), BESIDE_INJECTION)

        sent = "\n".join(call["material"] for call in self.calls())
        for included in (A_BOUNDARY[1], A_INTERIM[1], TOOL_INTENT, FINAL_DECISION, A_PREVIOUS[1], B_REQUEST[1]):
            self.assertIn(included, sent)
        for excluded in (
            NEXT_DAY, HIDDEN_REASONING, TOOL_OUTPUT, TOOL_ARGUMENT, SUBAGENT_TEXT, C_REQUEST[1], INJECTED_MEMORY,
            AGENT_INSTRUCTION,
        ):
            self.assertNotIn(excluded, sent)

        document = self.remote_file(DAY_FILE)
        self.assertEqual(document.split("\n")[0], MARKER)
        self.assertIn(DAY.isoformat(), document)
        self.assertIn(f"\n## {INSIGHT_0923['title']}\n", document)
        for cited, quote in (A_BOUNDARY, A_FINAL):
            self.assertIn(cited, document)
            self.assertIn(quote, document)
        self.assertNotIn(SESSION_C, document)
        self.assertNotIn(str(self.project), document)
        self.assertNotRegex(document, r"(?m)^\|")

        commits = git("--git-dir", str(self.remote), "rev-list", "--count", "main")
        self.run_journal("--date", DAY.isoformat())
        self.assertEqual(git("--git-dir", str(self.remote), "rev-list", "--count", "main"), commits)

    def test_a_failed_day_does_not_block_other_days(self):
        self.script["extract"].insert(0, {"when": C_REQUEST[1], "fail": True})
        self.save_script()
        now = local("2026-09-24T06:00:00")

        # 09-21 は model が失敗し、それより後の 09-22 と 09-23 は記録される
        self.run_journal(now=now, status=1)
        self.assertEqual(self.published(), ["2026/0922/testhost.md", "2026/0923/testhost.md"])

        del self.script["extract"][0]
        self.save_script()
        self.run_journal(now=now)
        self.assertEqual(
            self.published(), ["2026/0921/testhost.md", "2026/0922/testhost.md", "2026/0923/testhost.md"]
        )

    def test_the_model_never_runs_inside_a_git_work_tree(self):
        # project memory は cwd の Git common directory から想起先を決める。work tree の中で呼ぶと記憶が model の入力に混ざる
        previous = tempfile.tempdir
        tempfile.tempdir = str(self.project)
        self.addCleanup(setattr, tempfile, "tempdir", previous)

        self.run_journal("--date", DAY.isoformat(), status=1)
        self.assertEqual(self.calls(), [])

    def test_pending_days_end_at_the_last_completed_window_and_skip_only_published_days(self):
        before = journal.pending_days(local("2026-09-24T05:59:59"), TZ, 6, 2, self.journal, HOST, "main")
        at = journal.pending_days(local("2026-09-24T06:00:00"), TZ, 6, 2, self.journal, HOST, "main")
        self.assertEqual(before, [date(2026, 9, 21), date(2026, 9, 22)])
        self.assertEqual(at, [date(2026, 9, 22), DAY])

        existing = self.journal / "2026" / "0922" / f"{HOST}.md"
        existing.parent.mkdir(parents=True)
        existing.write_text("# 既存\n")
        self.assertEqual(
            journal.pending_days(local("2026-09-24T06:00:00"), TZ, 6, 2, self.journal, HOST, "main"), [date(2026, 9, 22), DAY]
        )

        git("add", "--", "2026/0922", cwd=self.journal)
        git("commit", "-q", "-m", "docs: 既存", cwd=self.journal)
        self.assertEqual(
            journal.pending_days(local("2026-09-24T06:00:00"), TZ, 6, 2, self.journal, HOST, "main"), [date(2026, 9, 22), DAY]
        )

        git("push", "-q", "origin", "HEAD:main", cwd=self.journal)
        self.assertEqual(journal.pending_days(local("2026-09-24T06:00:00"), TZ, 6, 2, self.journal, HOST, "main"), [DAY])

    def test_a_commit_failure_keeps_the_generated_day_and_the_next_ordinary_run_publishes_that_body(self):
        hook = self.journal / ".git" / "hooks" / "pre-commit"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)

        self.run_journal("--date", DAY.isoformat(), status=1)

        generated = self.journal / DAY_FILE
        self.assertTrue(generated.is_file())
        self.assertFalse(self.committed(DAY_FILE))
        self.assertIsNone(self.remote_file(DAY_FILE))
        edited = generated.read_text(encoding="utf-8") + "\n手で足した行\n"
        generated.write_text(edited, encoding="utf-8")
        calls = self.mentions(A_BOUNDARY[1])
        hook.unlink()

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertEqual(self.mentions(A_BOUNDARY[1]), calls)
        self.assertEqual(self.remote_file(DAY_FILE), edited)
        self.assertEqual(self.local_commit(DAY_FILE), self.remote_commit(DAY_FILE))
        self.assertEqual(len(git("log", "--format=%H", "--", DAY_FILE, cwd=self.journal).splitlines()), 1)

    def test_a_push_failure_keeps_the_local_commit_and_the_next_ordinary_run_only_publishes_it(self):
        git("config", "remote.origin.pushurl", str(self.workspace / "no-such-remote.git"), cwd=self.journal)

        self.run_journal("--date", DAY.isoformat(), status=1)

        self.assertTrue(self.committed(DAY_FILE))
        self.assertIsNone(self.remote_file(DAY_FILE))
        committed = self.local_commit(DAY_FILE)
        calls = self.mentions(A_BOUNDARY[1])
        git("config", "--unset", "remote.origin.pushurl", cwd=self.journal)

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertEqual(self.mentions(A_BOUNDARY[1]), calls)
        self.assertEqual(self.remote_commit(DAY_FILE), committed)
        self.assertEqual(self.remote_file(DAY_FILE), (self.journal / DAY_FILE).read_text(encoding="utf-8"))

    def test_days_at_different_stages_are_isolated_and_each_resumes_from_its_own_stage(self):
        hook = self.journal / ".git" / "hooks" / "pre-commit"
        hook.write_text("#!/bin/sh\ngit diff --cached --name-only | grep -q 0922 && exit 1\nexit 0\n")
        hook.chmod(0o755)
        now = local("2026-09-24T06:00:00")

        self.run_journal(now=now, status=1)

        self.assertEqual(self.published(), ["2026/0921/testhost.md", "2026/0923/testhost.md"])
        stuck = "2026/0922/testhost.md"
        self.assertTrue((self.journal / stuck).is_file())
        self.assertFalse(self.committed(stuck))
        before = {day: self.remote_commit(f"2026/{day}/testhost.md") for day in ("0921", "0923")}
        calls = self.mentions(A_PREVIOUS[1])
        hook.unlink()

        self.run_journal(now=now)

        self.assertEqual(self.published(), ["2026/0921/testhost.md", "2026/0922/testhost.md", "2026/0923/testhost.md"])
        self.assertEqual(self.mentions(A_PREVIOUS[1]), calls)
        self.assertEqual(before, {day: self.remote_commit(f"2026/{day}/testhost.md") for day in ("0921", "0923")})

    def test_an_unfinished_day_outside_the_lookback_is_resumed_from_its_file_without_the_model(self):
        old = self.journal / "2026" / "0910" / f"{HOST}.md"
        old.parent.mkdir(parents=True)
        old.write_text(f"{MARKER}\n# 2026-09-10 testhost\n\n以前に生成した本文\n", encoding="utf-8")
        git("add", "--", "2026/0910", cwd=self.journal)

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertEqual(self.remote_file("2026/0910/testhost.md"), old.read_text(encoding="utf-8"))
        self.assertEqual(self.mentions("以前に生成した本文"), 0)

    def test_no_child_starts_after_the_job_deadline(self):
        os.environ[DEADLINE] = str(time.time() - 1)
        self.addCleanup(os.environ.pop, DEADLINE, None)

        self.run_journal("--date", DAY.isoformat(), status=1)

        self.assertEqual(self.calls(), [])
        self.assertFalse((self.journal / DAY_FILE).exists())

    def test_the_job_deadline_bounds_every_model_stage_it_is_passed_to(self):
        os.environ[DEADLINE] = str(time.time() + 400)
        self.addCleanup(os.environ.pop, DEADLINE, None)

        self.run_journal("--date", DAY.isoformat())

        self.assertEqual({call["stage"] for call in self.calls()}, {"extract", "synthesize"})
        limits = [int(call["argv"][call["argv"].index("--max-time") + 1]) for call in self.calls()]
        self.assertTrue(all(1 <= limit <= 340 for limit in limits), limits)

    def test_a_day_file_that_cannot_be_written_is_not_published_and_the_next_run_recovers(self):
        directory = self.journal / "2026" / "0923"
        directory.mkdir(parents=True)
        for name in ("other.md", "tmpkeep"):
            (directory / name).write_text("neighbor\n", encoding="utf-8")
        publish = journal.atomic_write

        def constrained(path, document):
            with file_size_limit(SIZE_LIMIT):
                publish(path, document)

        refs = git("--git-dir", str(self.remote), "for-each-ref")
        with mock.patch.object(journal, "atomic_write", constrained):
            status, stdout, errors = self.captured("--date", DAY.isoformat())

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn(f"dotfiles-agent-journal: {DAY}:", errors)
        self.assertIn(os.strerror(errno.EFBIG), errors)
        self.assertFalse(self.committed(DAY_FILE))
        self.assertEqual(git("--git-dir", str(self.remote), "for-each-ref"), refs)
        self.assertEqual(sorted(path.name for path in directory.iterdir()), ["other.md", "tmpkeep"])
        self.assertIsNone(self.remote_file(DAY_FILE))

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertEqual(sorted(path.name for path in directory.iterdir()), ["other.md", "testhost.md", "tmpkeep"])
        self.assertEqual(self.remote_file(DAY_FILE), (self.journal / DAY_FILE).read_text(encoding="utf-8"))
        self.assertEqual((directory / "other.md").read_text(encoding="utf-8"), "neighbor\n")
        self.assertEqual((directory / "tmpkeep").read_text(encoding="utf-8"), "neighbor\n")

    def test_a_failed_regeneration_keeps_the_published_body_neighbors_and_git_state(self):
        self.run_journal("--date", DAY.isoformat())
        directory = (self.journal / DAY_FILE).parent
        for name in ("other.md", "tmpkeep", ".other-host.md.abcdefgh.tmp"):
            (directory / name).write_text("neighbor\n", encoding="utf-8")
        before = self.state()
        files = self.tree(directory)
        publish = journal.atomic_write

        def constrained(path, document):
            with file_size_limit(SIZE_LIMIT):
                publish(path, document)

        with mock.patch.object(journal, "atomic_write", constrained):
            status, stdout, errors = self.captured("--date", DAY.isoformat())

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn(f"dotfiles-agent-journal: {DAY}:", errors)
        self.assertIn(os.strerror(errno.EFBIG), errors)
        self.assertEqual(self.state(), before)
        self.assertEqual(self.tree(directory), files)

        self.run_journal("--date", DAY.isoformat())
        self.assertEqual(self.state(), before)
        self.assertEqual(self.tree(directory), files)

    def test_a_write_failure_on_the_first_active_day_does_not_stop_later_days_and_is_retried(self):
        first = "2026/0921/testhost.md"
        directory = (self.journal / first).parent
        directory.mkdir(parents=True)
        for name in ("other.md", "tmpkeep", ".other-host.md.abcdefgh.tmp"):
            (directory / name).write_text("neighbor\n", encoding="utf-8")
        neighbors = self.tree(directory)
        publish = journal.atomic_write
        now = local("2026-09-24T06:00:00")

        def constrained(path, document):
            if path == self.journal / first:
                with file_size_limit(SIZE_LIMIT):
                    publish(path, document)
            else:
                publish(path, document)

        with mock.patch.object(journal, "atomic_write", constrained):
            status, stdout, errors = self.captured(now=now)

        self.assertEqual(status, 1)
        self.assertIn("dotfiles-agent-journal: 2026-09-21:", errors)
        self.assertIn(os.strerror(errno.EFBIG), errors)
        self.assertNotIn("2026-09-22", errors)
        self.assertNotIn("2026-09-23", errors)
        self.assertIn("2026-09-23: 技術的な知見を記録した", stdout)
        self.assertEqual(self.tree(directory), neighbors)
        self.assertFalse(self.committed(first))
        self.assertIsNone(self.remote_file(first))
        later = {f"2026/{day}/testhost.md": self.remote_commit(f"2026/{day}/testhost.md") for day in ("0922", "0923")}
        self.assertEqual(self.published(), list(later))
        calls = len(self.calls())

        self.run_journal(now=now)

        self.assertGreater(len(self.calls()), calls)
        self.assertEqual(self.published(), [first, *later])
        self.assertEqual(self.remote_file(first), (self.journal / first).read_text(encoding="utf-8"))
        self.assertEqual(later, {relative: self.remote_commit(relative) for relative in later})
        self.assertEqual(
            {name: body for name, body in self.tree(directory).items() if name != f"{HOST}.md"}, neighbors
        )

    def test_filesystem_failures_on_every_active_day_fail_the_run_without_publishing(self):
        failure = OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))
        refs = git("--git-dir", str(self.remote), "for-each-ref")

        with mock.patch.object(journal, "atomic_write", side_effect=failure):
            status, stdout, errors = self.captured(now=local("2026-09-24T06:00:00"))

        self.assertEqual(status, 1)
        self.assertNotIn("技術的な知見を記録した", stdout)
        for day in ("2026-09-21", "2026-09-22", "2026-09-23"):
            self.assertIn(f"dotfiles-agent-journal: {day}:", errors)
        self.assertEqual(errors.count(os.strerror(errno.ENOSPC)), 3)
        self.assertEqual(git("--git-dir", str(self.remote), "for-each-ref"), refs)
        self.assertFalse((self.journal / "2026").exists())

    def test_a_programming_error_is_not_reported_as_a_recoverable_day_failure(self):
        with mock.patch.object(journal, "atomic_write", side_effect=RuntimeError("programming error")):
            with self.assertRaisesRegex(RuntimeError, "programming error"):
                self.captured("--date", DAY.isoformat())

    def test_the_next_run_recovers_a_killed_publication_of_a_day_outside_the_lookback(self):
        old = self.journal / "2026" / "0910"
        old.mkdir(parents=True)
        legacy = old / "tmpabcdefgh"
        other_machine = old / ".other-host.md.abcdefgh.tmp"
        for path in (legacy, other_machine):
            path.write_text("neighbor\n", encoding="utf-8")
            path.chmod(0o600)
        ready, release = self.workspace / "ready", self.workspace / "release"
        child = start_publisher(self, old / f"{HOST}.md", "never published\n", ready, release)
        temporary = Path(wait_for(ready, child))
        child.kill()
        child.wait()
        self.assertTrue(temporary.is_file())

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertFalse(temporary.exists())
        self.assertFalse((old / f"{HOST}.md").exists())
        self.assertEqual(sorted(path.name for path in old.iterdir()), sorted([legacy.name, other_machine.name]))
        self.assertEqual(legacy.read_text(encoding="utf-8"), "neighbor\n")
        self.assertEqual(other_machine.read_text(encoding="utf-8"), "neighbor\n")
        self.assertEqual(self.remote_file(DAY_FILE), (self.journal / DAY_FILE).read_text(encoding="utf-8"))

    def test_an_abandoned_temporary_that_cannot_be_removed_fails_the_run_without_blocking_other_days(self):
        old = self.journal / "2026" / "0910"
        old.mkdir(parents=True)
        leftover = old / f".{HOST}.md.abcdefgh.tmp"
        leftover.write_text("abandoned\n", encoding="utf-8")
        leftover.chmod(0o600)
        old.chmod(0o555)
        self.addCleanup(old.chmod, 0o755)
        errors = io.StringIO()

        with redirect_stderr(errors):
            self.run_journal(now=local("2026-09-24T06:00:00"), status=1)

        self.assertIn("could not remove an abandoned temporary", errors.getvalue())
        self.assertTrue(leftover.exists())
        self.assertEqual(self.remote_file(DAY_FILE), (self.journal / DAY_FILE).read_text(encoding="utf-8"))

    def test_recovery_follows_no_symlinked_directory_and_skips_dates_that_do_not_exist(self):
        external = self.workspace / "external"
        sentinel = external / "0910" / f".{HOST}.md.abcdefgh.tmp"
        impossible = [self.journal / "2026" / name / f".{HOST}.md.abcdefgh.tmp" for name in ("9999", "0230")]
        (self.journal / "2025").mkdir()
        (self.journal / "2024").symlink_to(external)
        (self.journal / "2025" / "0910").symlink_to(external / "0910")
        for path in (sentinel, *impossible):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("keep\n", encoding="utf-8")
            path.chmod(0o600)

        self.run_journal(now=local("2026-09-24T06:00:00"))

        for path in (sentinel, *impossible):
            self.assertEqual(path.read_text(encoding="utf-8"), "keep\n")
        self.assertEqual(sorted(path.name for path in sentinel.parent.iterdir()), [sentinel.name])

    def test_a_citation_the_model_was_not_given_or_cannot_quote_fails_the_day_and_keeps_the_published_day(self):
        self.run_journal("--date", DAY.isoformat())
        fabricated = (A_BOUNDARY[0], "存在しない発言")
        cases = {
            "an entry that does not exist": [(source(SESSION_A, "a9999999"), A_BOUNDARY[1])],
            "a session that was not read for the day": [C_REQUEST],
            "a tool result": [(source(SESSION_A, "a0000004"), TOOL_OUTPUT)],
            "an entry at the end of the window": [(source(SESSION_A, "a0000006"), NEXT_DAY)],
            "an instruction written by an agent": [(source(SESSION_A, "a0000008"), AGENT_INSTRUCTION)],
            "an injected block": [(A_BESIDE[0], INJECTED_MEMORY)],
            "hidden reasoning": [(A_INTERIM[0], HIDDEN_REASONING)],
            "tool arguments": [(A_INTERIM[0], TOOL_ARGUMENT)],
            "a quote that belongs to another record": [(A_BOUNDARY[0], A_INTERIM[1])],
            "an invented quote": [fabricated],
            "an empty quote": [(A_BOUNDARY[0], "")],
            "a blank quote": [(A_BOUNDARY[0], " \n ")],
            "a valid citation next to an invented one": [A_BOUNDARY, fabricated],
            "records from before the window only": [A_PREVIOUS],
            "no citation": [],
        }
        for name, citations in cases.items():
            with self.subTest(name):
                self.refuses(self.route(A_BOUNDARY[1], {"insights": [insight("引用の検証", *citations)]}))

    def test_malformed_model_output_fails_the_day_and_keeps_the_published_day(self):
        self.run_journal("--date", DAY.isoformat())
        found = INSIGHT_0923
        cases = {
            "prose instead of JSON": "技術的な知見は見つからなかった。",
            "an array at the top level": [found],
            "an extra top-level key": {"insights": [], "note": "余分"},
            "no insights key": {"results": []},
            "a missing field": {"insights": [{key: value for key, value in found.items() if key != "finding"}]},
            "an extra field": {"insights": [{**found, "score": 1}]},
            "an empty explanation": {"insights": [{**found, "explanation": ""}]},
            "an unknown status": {"insights": [{**found, "status": "verified"}]},
            "an extra evidence field": {"insights": [{**found, "evidence": [{**found["evidence"][0], "note": "余分"}]}]},
        }
        for name, reply in cases.items():
            with self.subTest(f"extraction: {name}"):
                self.refuses(self.route(A_BOUNDARY[1], reply))
            with self.subTest(f"synthesis: {name}"):
                self.refuses(self.route(A_BOUNDARY[1], {"insights": [found]}), self.route(A_BOUNDARY[1], reply))

    def test_one_malformed_session_batch_publishes_nothing_even_when_another_is_valid(self):
        self.script["extract"] = [
            {"when": A_BOUNDARY[1], "reply": {"insights": [INSIGHT_0923]}},
            {"when": B_REQUEST[1], "reply": "知見なし"},
        ]
        self.save_script()

        self.run_journal("--date", DAY.isoformat(), status=1)

        self.assertEqual(len(self.calls("extract")), 2)
        self.assertEqual(self.calls("synthesize"), [])
        self.assertFalse((self.journal / "2026").exists())
        self.assertIsNone(self.remote_file(DAY_FILE))

    def test_synthesis_cannot_cite_what_the_accepted_candidates_did_not_supply(self):
        self.run_journal("--date", DAY.isoformat())
        accepted = self.route(A_BOUNDARY[1], {"insights": [INSIGHT_0923]})
        cases = {
            "another record of the same session": [A_INTERIM],
            "a record of another session": [B_REQUEST],
            "a supplied record together with an unsupplied one": [A_BOUNDARY, A_INTERIM],
            "a supplied quote extended with unsupplied text": [(A_BOUNDARY[0], A_BOUNDARY[1] + "と存在しない続き")],
            "an unknown entry": [(source(SESSION_A, "a9999999"), A_BOUNDARY[1])],
            "no citation": [],
        }
        for name, citations in cases.items():
            with self.subTest(name):
                self.refuses(accepted, self.route(A_BOUNDARY[1], {"insights": [insight("統合した知見", *citations)]}))

    def test_synthesis_cannot_rest_an_article_on_background_records_alone(self):
        self.run_journal("--date", DAY.isoformat())
        mixed = insight("背景と対象", A_PREVIOUS, A_BOUNDARY)

        self.refuses(
            self.route(A_BOUNDARY[1], {"insights": [mixed]}),
            self.route(A_BOUNDARY[1], {"insights": [insight("背景だけ", A_PREVIOUS)]}),
        )

    def test_synthesis_cannot_upgrade_a_hypothesis_to_a_supported_claim(self):
        self.run_journal("--date", DAY.isoformat())
        guess = insight("推測", A_BOUNDARY, status="hypothesis")

        self.refuses(
            self.route(A_BOUNDARY[1], {"insights": [guess]}),
            self.route(A_BOUNDARY[1], {"insights": [{**guess, "status": "supported"}]}),
        )

    def test_synthesis_may_downgrade_a_supported_claim_to_a_hypothesis(self):
        downgraded = {**INSIGHT_0923, "status": "hypothesis"}
        self.script["extract"] = self.route(A_BOUNDARY[1], {"insights": [INSIGHT_0923]})
        self.script["synthesize"] = self.route(A_BOUNDARY[1], {"insights": [downgraded]})
        self.save_script()

        self.run_journal("--date", DAY.isoformat())

        self.assertIn(f"\n## {INSIGHT_0923['title']}\n", self.remote_file(DAY_FILE))

    def test_a_merged_supported_claim_may_rest_only_on_the_quotes_of_supported_candidates(self):
        self.run_journal("--date", DAY.isoformat())
        solid = insight("確かな部分", A_BOUNDARY)
        guess = insight("推測の部分", A_FINAL, status="hypothesis")
        extract = self.route(A_BOUNDARY[1], {"insights": [solid, guess]})

        self.refuses(extract, self.route(A_BOUNDARY[1], {"insights": [insight("統合", A_BOUNDARY, A_FINAL)]}))

        merged = insight("統合", A_BOUNDARY)
        self.script["synthesize"] = self.route(A_BOUNDARY[1], {"insights": [merged]})
        self.save_script()
        self.run_journal("--date", DAY.isoformat())
        document = self.remote_file(DAY_FILE)
        self.assertIn(f"\n## {merged['title']}\n", document)
        self.assertNotIn(A_FINAL[1], document)

    def test_a_claim_may_cite_background_next_to_a_record_of_the_day_and_a_shorter_quote(self):
        mixed = insight("背景を踏まえた知見", A_PREVIOUS, A_BOUNDARY, A_FINAL, status="hypothesis")
        shortened = insight("背景を踏まえた知見", A_PREVIOUS, A_BOUNDARY, (A_FINAL[0], "終了時刻は含めず"), status="hypothesis")
        self.script["extract"] = self.route(A_BOUNDARY[1], {"insights": [mixed]})
        self.script["synthesize"] = self.route(A_BOUNDARY[1], {"insights": [shortened]})
        self.save_script()

        self.run_journal("--date", DAY.isoformat())

        document = self.remote_file(DAY_FILE)
        self.assertIn(f"\n## {mixed['title']}\n", document)
        for cited, quote in (A_PREVIOUS, A_BOUNDARY, (A_FINAL[0], "終了時刻は含めず")):
            self.assertIn(cited, document)
            self.assertIn(quote, document)

    def test_candidates_of_every_session_reach_one_synthesis_and_the_merged_article_is_published_once(self):
        self.script["extract"] = [
            {"when": A_BOUNDARY[1], "reply": {"insights": [insight("境界の扱い", A_BOUNDARY)]}},
            {"when": B_REQUEST[1], "reply": {"insights": [insight("境界の扱い", B_REQUEST)]}},
        ]
        merged = insight("日付の境界は開始を含み終了を含まない", A_BOUNDARY, B_REQUEST)
        self.script["synthesize"] = [{"when": None, "reply": {"insights": [merged]}}]
        self.save_script()

        self.run_journal("--date", DAY.isoformat())

        [synthesis] = self.calls("synthesize")
        for cited, _ in (A_BOUNDARY, B_REQUEST):
            self.assertIn(cited, synthesis["material"])
        document = self.remote_file(DAY_FILE)
        self.assertEqual(document.count("\n## "), 1)
        for cited, quote in (A_BOUNDARY, B_REQUEST):
            self.assertIn(cited, document)
            self.assertIn(quote, document)

    def test_a_large_candidate_set_is_reduced_in_bounded_rounds_without_dropping_evidence(self):
        cited = (A_BOUNDARY, A_INTERIM, A_FINAL, A_BESIDE)
        padding = "detail " * (journal.SYNTHESIS_CHARS * 2 // 5 // 7)
        candidates = [{**insight(f"候補{number}", evidence), "explanation": padding} for number, evidence in enumerate(cited)]
        self.script["extract"] = self.route(A_BOUNDARY[1], {"insights": candidates})
        self.script["synthesize"] = [{"when": None, "merge": "統合された知見"}]
        self.save_script()

        self.run_journal("--date", DAY.isoformat())

        synthesis = self.calls("synthesize")
        self.assertGreater(len(synthesis), 1)
        self.assertTrue(all(len(call["material"]) <= journal.SYNTHESIS_CHARS for call in synthesis))
        document = self.remote_file(DAY_FILE)
        for found, quote in cited:
            self.assertIn(found, document)
            self.assertIn(quote, document)

    def test_a_candidate_that_cannot_fit_a_synthesis_call_fails_the_day_instead_of_being_dropped(self):
        self.run_journal("--date", DAY.isoformat())
        calls = len(self.calls("synthesize"))
        oversize = {**INSIGHT_0923, "explanation": "detail " * (journal.SYNTHESIS_CHARS // 7 + 1)}

        self.refuses(self.route(A_BOUNDARY[1], {"insights": [oversize]}))

        self.assertEqual(len(self.calls("synthesize")), calls)

    def test_a_day_with_activity_but_no_grounded_insight_is_a_dated_document_not_a_failure(self):
        self.script["extract"] = []
        self.save_script()

        self.run_journal("--date", DAY.isoformat())

        document = self.remote_file(DAY_FILE)
        self.assertEqual(document.split("\n")[0], MARKER)
        self.assertIn(DAY.isoformat(), document)
        self.assertNotIn("\n## ", document)
        self.assertEqual(self.calls("synthesize"), [])
        for quote in (A_BOUNDARY[1], B_REQUEST[1]):
            self.assertNotIn(quote, document)

    def test_a_day_without_activity_keeps_no_document(self):
        self.run_journal("--date", "2026-09-20")

        self.assertEqual(self.calls(), [])
        self.assertFalse((self.journal / "2026" / "0920").exists())
        self.assertIsNone(self.remote_file("2026/0920/testhost.md"))

    def test_a_day_with_only_automatic_user_records_keeps_no_document(self):
        write_session(self.sessions, "-projects-sample", SESSION_E, self.project, "自動通知だけ", [
            user("e0000001", "2026-09-26T10:00:00", "<system-reminder>\n自動で差し込まれた注意\n</system-reminder>"),
            user("e0000002", "2026-09-26T10:01:00", AGENT_INSTRUCTION, attribution="agent"),
        ])

        self.run_journal("--date", "2026-09-26")

        self.assertEqual(self.calls(), [])
        self.assertFalse((self.journal / "2026" / "0926").exists())

    def test_long_visible_text_reaches_the_model_whole_in_bounded_batches_and_its_tail_can_be_cited(self):
        tokens = [f"{number:05d}," for number in range(3 * journal.CHUNK_CHARS // 6)]
        text = "".join(tokens)
        tail = tokens[-1]
        cited = source(SESSION_D, "d0000001")
        write_session(self.sessions, "-projects-sample", SESSION_D, self.project, "長い発言", [
            user("d0000001", "2026-09-25T10:00:00", text),
        ])
        found = {"insights": [insight("末尾の知見", (cited, tail))]}
        self.script["extract"] = self.route(tail, found)
        self.script["synthesize"] = self.route(tail, found)
        self.save_script()

        self.run_journal("--date", "2026-09-25")

        extract = self.calls("extract")
        self.assertGreater(len(extract), 1)
        self.assertTrue(all(len(call["material"]) <= journal.CHUNK_CHARS for call in extract))
        delivered = [piece["text"] for call in extract for piece in self.parts(call)[1] if piece["scope"] == "target"]
        self.assertEqual("".join(delivered), text)
        document = self.remote_file("2026/0925/testhost.md")
        self.assertIn(cited, document)
        self.assertIn(tail, document)

    def test_a_flood_of_short_background_records_cannot_push_the_extraction_input_past_the_limit(self):
        flood = 1000
        write_session(self.sessions, "-projects-sample", SESSION_D, self.project, "背景の多い作業", [
            *(user(f"g{number:07d}", "2026-09-25T05:00:00", "ok") for number in range(flood)),
            user("d0000001", "2026-09-25T10:00:00", "対象の依頼"),
        ])

        self.run_journal("--date", "2026-09-25")

        [call] = self.calls("extract")
        self.assertLessEqual(len(call["material"]), journal.CHUNK_CHARS)
        records = self.parts(call)[1]
        background = [found["source"] for found in records if found["scope"] == "background"]
        newest = [source(SESSION_D, f"g{number:07d}") for number in range(flood)]
        self.assertTrue(0 < len(background) < flood)
        self.assertEqual(background, newest[flood - len(background):])
        self.assertEqual([found["text"] for found in records if found["scope"] == "target"], ["対象の依頼"])

    def test_every_batch_repeats_the_same_newest_background_within_the_input_limit(self):
        flood = 300
        text = "".join(f"{number:05d}," for number in range(3 * journal.CHUNK_CHARS // 6))
        write_session(self.sessions, "-projects-sample", SESSION_D, self.project, "背景と長い発言", [
            *(user(f"g{number:07d}", "2026-09-25T05:00:00", "ok") for number in range(flood)),
            user("d0000001", "2026-09-25T10:00:00", text),
        ])

        self.run_journal("--date", "2026-09-25")

        extract = self.calls("extract")
        self.assertGreater(len(extract), 3)
        self.assertTrue(all(len(call["material"]) <= journal.CHUNK_CHARS for call in extract))
        contexts = [
            [found["source"] for found in self.parts(call)[1] if found["scope"] == "background"] for call in extract
        ]
        newest = [source(SESSION_D, f"g{number:07d}") for number in range(flood)]
        self.assertTrue(0 < len(contexts[0]) < flood)
        self.assertEqual(contexts[0], newest[flood - len(contexts[0]):])
        self.assertEqual(contexts, [contexts[0]] * len(extract))
        delivered = [found["text"] for call in extract for found in self.parts(call)[1] if found["scope"] == "target"]
        self.assertEqual("".join(delivered), text)

    def test_json_escaping_cannot_push_a_long_target_past_the_input_limit_and_its_text_stays_whole(self):
        # 制御文字は JSON で 6 文字になり PIECE_CHARS の断片でも上限超過
        tokens = [f"{number:03d}{chr(1) * 30}\n" for number in range(3 * journal.CHUNK_CHARS // 34)]
        tail = "終端"
        text = "".join(tokens) + tail
        cited = source(SESSION_D, "d0000001")
        write_session(self.sessions, "-projects-sample", SESSION_D, self.project, "制御文字の多い発言", [
            user("d0000001", "2026-09-25T10:00:00", text),
        ])
        found = {"insights": [insight("末尾の知見", (cited, tail))]}
        self.script["extract"] = self.route(tail, found)
        self.script["synthesize"] = self.route(tail, found)
        self.save_script()

        self.run_journal("--date", "2026-09-25")

        extract = self.calls("extract")
        self.assertGreater(len(extract), 9)
        self.assertTrue(all(len(call["material"]) <= journal.CHUNK_CHARS for call in extract))
        self.assertEqual(
            [self.parts(call)[0]["batch"] for call in extract],
            [f"{number}/{len(extract)}" for number in range(1, len(extract) + 1)],
        )
        pieces = [piece for call in extract for piece in self.parts(call)[1]]
        self.assertEqual("".join(piece["text"] for piece in pieces), text)
        self.assertEqual(
            [piece["part"] for piece in pieces], [f"{number}/{len(pieces)}" for number in range(1, len(pieces) + 1)]
        )
        self.assertIn(tail, self.remote_file("2026/0925/testhost.md"))

    def test_session_information_that_cannot_fit_the_extraction_input_fails_the_day_explicitly(self):
        write_session(self.sessions, "-projects-sample", SESSION_D, self.project, "長" * journal.CHUNK_CHARS, [
            user("d0000001", "2026-09-25T10:00:00", "対象の依頼"),
        ])

        status, _, errors = self.captured("--date", "2026-09-25")

        self.assertEqual(status, 1)
        self.assertIn("2026-09-25", errors)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.journal / "2026" / "0925").exists())
        self.assertIsNone(self.remote_file("2026/0925/testhost.md"))

    def test_a_clipped_background_is_a_contiguous_suffix_and_a_quote_with_an_added_lead_is_rejected(self):
        tokens = [f"{number:05d}," for number in range(journal.BACKGROUND_CHARS // 3)]
        original = "".join(tokens)
        earlier, latest = source(SESSION_D, "d0000001"), source(SESSION_D, "d0000002")
        write_session(self.sessions, "-projects-sample", SESSION_D, self.project, "背景を切り詰める作業", [
            user("d0000001", "2026-09-25T05:00:00", original),
            user("d0000002", "2026-09-25T10:00:00", "対象の依頼"),
        ])
        kept = tokens[-1]
        cases = {
            "a lead the record does not have": (earlier, "（前略）" + kept),
            "text before the clipped suffix": (earlier, tokens[0]),
        }
        for name, cited in cases.items():
            with self.subTest(name):
                self.script["extract"] = self.route("対象の依頼", {"insights": [insight("背景の引用", cited, (latest, "対象の依頼"))]})
                self.save_script()

                status, _, errors = self.captured("--date", "2026-09-25")

                self.assertEqual(status, 1)
                self.assertIn("2026-09-25", errors)
                self.assertIsNone(self.remote_file("2026/0925/testhost.md"))
        accepted = {"insights": [insight("背景の引用", (earlier, kept), (latest, "対象の依頼"))]}
        self.script["extract"] = self.route("対象の依頼", accepted)
        self.script["synthesize"] = self.route("対象の依頼", accepted)
        self.save_script()

        self.run_journal("--date", "2026-09-25")

        call = self.calls("extract")[-1]
        background = "".join(found["text"] for found in self.parts(call)[1] if found["scope"] == "background")
        self.assertEqual(background, original[-journal.BACKGROUND_CHARS:])
        self.assertNotIn("（前略）", call["material"])
        self.assertIn(kept, self.remote_file("2026/0925/testhost.md"))

    def test_a_published_quotation_is_literal_text_that_markdown_and_html_cannot_interpret(self):
        cited = source(SESSION_D, "d0000001")
        write_session(self.sessions, "-projects-sample", SESSION_D, self.project, "記法を含む発言", [
            user("d0000001", "2026-09-25T10:00:00", LITERAL_QUOTE),
        ])
        found = {"insights": [insight("記法を含む引用", (cited, LITERAL_QUOTE))]}
        self.script["extract"] = self.route("caching disabled", found)
        self.script["synthesize"] = self.route("caching disabled", found)
        self.save_script()

        self.run_journal("--date", "2026-09-25")

        blocks, outside = fenced_blocks(self.remote_file("2026/0925/testhost.md"))
        self.assertEqual(blocks, [LITERAL_QUOTE.split("\n")])
        self.assertTrue(any(cited in line for line in outside))
        for line in filter(None, LITERAL_QUOTE.split("\n")):
            self.assertNotIn(line, "\n".join(outside))

    def test_an_unpublished_generated_legacy_day_is_not_published_and_a_rebuild_by_date_replaces_it(self):
        legacy = self.seed_legacy()
        now = local("2026-09-24T06:00:00")

        status, _, errors = self.captured(now=now)

        self.assertEqual(status, 1)
        self.assertIn("2026-09-22", errors)
        self.assertIn("--date", errors)
        self.assertEqual(legacy.read_text(encoding="utf-8"), LEGACY)
        self.assertFalse(self.committed(LEGACY_FILE))
        self.assertIsNone(self.remote_file(LEGACY_FILE))
        # 旧形式の日が失敗しても、他の日は記録される
        self.assertEqual(self.published(), ["2026/0921/testhost.md", "2026/0923/testhost.md"])

        self.run_journal("--date", "2026-09-22")

        rebuilt = legacy.read_text(encoding="utf-8")
        self.assertEqual(rebuilt.split("\n")[0], MARKER)
        self.assertEqual(self.remote_file(LEGACY_FILE), rebuilt)

    def test_a_committed_but_unpublished_legacy_day_never_reaches_the_remote_until_it_is_rebuilt(self):
        self.seed_legacy(committed=True)
        now = local("2026-09-24T06:00:00")

        status, _, errors = self.captured(now=now)

        self.assertEqual(status, 1)
        self.assertIn("--date", errors)
        self.assertIsNone(self.remote_file(LEGACY_FILE))
        self.assertEqual((self.journal / LEGACY_FILE).read_text(encoding="utf-8"), LEGACY)
        self.assertEqual(git("show", f"HEAD:{LEGACY_FILE}", cwd=self.journal), LEGACY.strip())

        self.run_journal("--date", "2026-09-22")

        rebuilt = (self.journal / LEGACY_FILE).read_text(encoding="utf-8")
        self.assertEqual(rebuilt.split("\n")[0], MARKER)
        self.assertEqual(self.remote_file(LEGACY_FILE), rebuilt)
        self.run_journal(now=now)
        self.assertEqual(self.published(), ["2026/0921/testhost.md", "2026/0922/testhost.md", "2026/0923/testhost.md"])

    def test_another_machines_unpublished_legacy_day_blocks_the_whole_push_until_it_is_rebuilt(self):
        readme = self.journal / "README.md"
        readme.write_text("published notes\n", encoding="utf-8")
        git("add", "--", "README.md", cwd=self.journal)
        git("commit", "-q", "-m", "docs: 公開済みの説明", cwd=self.journal)
        git("push", "-q", "origin", "HEAD:main", cwd=self.journal)
        refs = git("--git-dir", str(self.remote), "for-each-ref")
        machine = "other-host.2"
        relative = f"2026/0922/{machine}.md"
        legacy = self.journal / relative
        legacy.parent.mkdir(parents=True)
        body = LEGACY.replace(HOST, machine)
        legacy.write_text(body, encoding="utf-8")
        readme.write_text("unpublished notes\n", encoding="utf-8")
        git("add", "--", relative, "README.md", cwd=self.journal)
        git("commit", "-q", "-m", "docs: 別機械の未公開の旧形式", cwd=self.journal)
        now = local("2026-09-24T06:00:00")

        status, _, errors = self.captured(now=now)

        self.assertEqual(status, 1)
        self.assertIn(relative, errors)
        self.assertIn("--date", errors)
        self.assertEqual(legacy.read_text(encoding="utf-8"), body)
        self.assertEqual(git("show", f"HEAD:{relative}", cwd=self.journal), body.strip())
        self.assertEqual(git("--git-dir", str(self.remote), "for-each-ref"), refs)
        self.assertIsNone(self.remote_file(relative))
        self.assertEqual(self.published(), ["README.md"])
        self.assertEqual(self.remote_file("README.md"), "published notes\n")
        pending = {f"2026/{day}/testhost.md": self.local_commit(f"2026/{day}/testhost.md") for day in ("0921", "0922", "0923")}
        calls = len(self.calls())

        status, _, _ = self.captured(now=now)

        self.assertEqual(status, 1)
        self.assertEqual(len(self.calls()), calls)
        self.assertEqual(git("--git-dir", str(self.remote), "for-each-ref"), refs)

        self.run_journal("--date", "2026-09-22", "--machine-name", machine)

        rebuilt = legacy.read_text(encoding="utf-8")
        self.assertEqual(rebuilt.split("\n")[0], MARKER)
        self.assertEqual(self.remote_file(relative), rebuilt)
        calls = len(self.calls())
        self.run_journal(now=now)
        self.assertEqual(len(self.calls()), calls)
        self.assertEqual(self.published(), sorted([*pending, relative, "README.md"]))
        self.assertEqual(pending, {path: self.remote_commit(path) for path in pending})
        self.assertEqual(self.remote_file("README.md"), "unpublished notes\n")

    def test_another_machines_legacy_day_cannot_create_the_first_remote_branch(self):
        relative = "2026/0922/otherhost.md"
        legacy = self.journal / relative
        legacy.parent.mkdir(parents=True)
        body = LEGACY.replace(HOST, "otherhost")
        legacy.write_text(body, encoding="utf-8")
        git("add", "--", relative, cwd=self.journal)
        git("commit", "-q", "-m", "docs: 別機械の未公開の旧形式", cwd=self.journal)
        refs = git("--git-dir", str(self.remote), "for-each-ref")

        status, _, errors = self.captured("--date", DAY.isoformat())

        self.assertEqual(status, 1)
        self.assertIn(relative, errors)
        self.assertEqual(git("--git-dir", str(self.remote), "for-each-ref"), refs)
        self.assertEqual(legacy.read_text(encoding="utf-8"), body)
        self.assertTrue(self.committed(DAY_FILE))
        self.assertIsNone(self.remote_file(relative))
        self.assertIsNone(self.remote_file(DAY_FILE))

    def test_non_journal_paths_are_not_rejected_as_legacy_journals(self):
        paths = [
            "README.md", "notes/README.md", "2026/README.md", "2026/0230/otherhost.md",
            "2026/0922/.hidden.md", "2026/0922/unsafe host.md",
        ]
        for relative in paths:
            path = self.journal / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("not a journal\n", encoding="utf-8")
        git("add", "--", *paths, cwd=self.journal)
        git("commit", "-q", "-m", "docs: 日誌でない file", cwd=self.journal)

        self.run_journal("--date", DAY.isoformat())

        self.assertEqual(self.published(), sorted([*paths, DAY_FILE]))
        for relative in paths:
            self.assertEqual(self.remote_file(relative), "not a journal\n")

    def test_a_published_legacy_day_is_left_alone_by_ordinary_runs(self):
        legacy = self.seed_legacy(published=True)
        published = self.remote_commit(LEGACY_FILE)

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertEqual(legacy.read_text(encoding="utf-8"), LEGACY)
        self.assertEqual(self.remote_file(LEGACY_FILE), LEGACY)
        self.assertEqual(self.remote_commit(LEGACY_FILE), published)

    def test_preview_is_the_document_a_normal_run_publishes_and_changes_nothing(self):
        tree = self.tree(self.journal)
        refs = git("--git-dir", str(self.remote), "for-each-ref")

        status, stdout, _ = self.captured("--preview", "--date", DAY.isoformat())

        self.assertEqual(status, 0)
        self.assertEqual(self.tree(self.journal), tree)
        self.assertEqual(git("--git-dir", str(self.remote), "for-each-ref"), refs)
        self.assertEqual(stdout.split("\n")[0], MARKER)
        self.run_journal("--date", DAY.isoformat())
        self.assertEqual(stdout, (self.journal / DAY_FILE).read_text(encoding="utf-8"))
        self.assertEqual(stdout, self.remote_file(DAY_FILE))

    def test_preview_does_not_open_the_journal_directory(self):
        absent = self.workspace / "absent-journal"

        status, stdout, _ = self.captured("--preview", "--date", DAY.isoformat(), journal_dir=absent)

        self.assertEqual(status, 0)
        self.assertEqual(stdout.split("\n")[0], MARKER)
        self.assertFalse(absent.exists())

    def test_preview_requires_a_date(self):
        errors = io.StringIO()

        with redirect_stderr(errors), self.assertRaises(SystemExit) as raised:
            journal.main(self.arguments("--preview"))

        self.assertNotEqual(raised.exception.code, 0)
        self.assertEqual(self.calls(), [])

    def test_a_preview_that_cannot_be_generated_prints_no_markdown_and_changes_nothing(self):
        self.script["extract"] = [
            {"when": A_BOUNDARY[1], "reply": {"insights": [INSIGHT_0923]}},
            {"when": B_REQUEST[1], "reply": "知見なし"},
        ]
        self.save_script()
        tree = self.tree(self.journal)

        status, stdout, errors = self.captured("--preview", "--date", DAY.isoformat())

        self.assertNotEqual(status, 0)
        self.assertEqual(stdout, "")
        self.assertIn(DAY.isoformat(), errors)
        self.assertEqual(self.tree(self.journal), tree)

    def test_a_preview_of_a_day_without_activity_prints_no_markdown(self):
        status, stdout, _ = self.captured("--preview", "--date", "2026-09-20")

        self.assertEqual(status, 0)
        self.assertEqual(stdout, "")
        self.assertEqual(self.calls(), [])


class SessionReaderTest(unittest.TestCase):
    START = local("2026-09-23T06:00:00")
    END = START + timedelta(days=1)

    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="agent-journal-reader-test-")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name) / "sessions"
        self.cwd = Path(workspace.name) / "work"
        self.cwd.mkdir()

    def write(self, session_id: str, entries: list, modified: str | None = None) -> Path:
        return write_session(self.root, "-work", session_id, self.cwd, "読み取りの試験", entries, modified)

    def read(self, **options) -> list:
        return journal.sessions_in(self.root, self.START, self.END, TZ, **options)

    def around_the_window(self) -> list:
        return [
            user("r0000001", "2026-09-23T05:00:00", "古い前提"),
            assistant("r0000002", "2026-09-23T05:59:59", [text_part("前の応答")]),
            user("r0000003", "2026-09-23T06:00:00", "窓の開始"),
            assistant("r0000004", "2026-09-23T12:00:00", [text_part("窓の応答")]),
            user("r0000005", "2026-09-23T23:59:59", "窓の最後"),
            user("r0000006", "2026-09-24T06:00:00", "窓の終了"),
            user("r0000007", "2026-09-24T07:00:00", "翌日"),
        ]

    def test_the_window_is_half_open_and_earlier_records_are_background_that_is_not_current(self):
        self.write(SESSION_A, self.around_the_window())

        [session] = self.read(context_chars=1000)

        current = {e.source for e in session.evidence if e.current}
        background = {e.source for e in session.evidence if not e.current}
        self.assertEqual(current, {source(SESSION_A, entry) for entry in ("r0000003", "r0000004", "r0000005")})
        self.assertEqual(background, {source(SESSION_A, entry) for entry in ("r0000001", "r0000002")})
        self.assertEqual(session.id, SESSION_A)
        self.assertEqual(session.cwd, str(self.cwd))
        self.assertEqual(session.first, self.START)
        self.assertEqual(session.last, local("2026-09-23T23:59:59"))

    def test_the_default_reader_keeps_the_window_only_view_memory_harvest_depends_on(self):
        path = self.write(SESSION_A, self.around_the_window())

        [session] = self.read()

        self.assertTrue(all(e.current for e in session.evidence))
        self.assertEqual([prompt.id for prompt in session.prompts], ["r0000003", "r0000005"])
        self.assertEqual([prompt.text for prompt in session.prompts], ["窓の開始", "窓の最後"])
        self.assertEqual(session.path, path)

    def test_background_never_makes_a_session_eligible(self):
        self.write(SESSION_A, [
            user("p0000001", "2026-09-23T05:00:00", "窓より前だけ"),
            assistant("p0000002", "2026-09-23T05:59:59", [text_part("窓より前の応答")]),
        ], modified="2026-09-23T12:00:00")
        self.write(SESSION_B, [user("n0000001", "2026-09-24T06:00:00", "窓の終了から")])
        self.write(SESSION_C, [
            user("q0000001", "2026-09-23T05:00:00", "背景になる前提"),
            user("q0000002", "2026-09-23T07:00:00", "窓の中の発言"),
        ])

        for options in ({}, {"context_chars": 1000}):
            with self.subTest(options):
                self.assertEqual([session.id for session in self.read(**options)], [SESSION_C])

    def test_the_background_tail_keeps_the_newest_records_and_clips_only_to_a_suffix_of_the_original(self):
        labels = "甲乙丙丁戊"
        originals = {source(SESSION_A, f"t000000{number}"): f"{label}abcdefghi" for number, label in enumerate(labels)}
        self.write(SESSION_A, [
            *(user(f"t000000{number}", f"2026-09-23T0{number}:00:00", f"{label}abcdefghi") for number, label in enumerate(labels)),
            user("t0000009", "2026-09-23T06:00:00", "窓の発言"),
        ])
        limit = 24

        [session] = self.read(context_chars=limit)

        background = {e.source: e.text for e in session.evidence if not e.current}
        self.assertLessEqual(sum(len(text) for text in background.values()), limit)
        self.assertEqual(background.keys() & {source(SESSION_A, "t0000000"), source(SESSION_A, "t0000001")}, set())
        for found in (source(SESSION_A, "t0000004"), source(SESSION_A, "t0000003")):
            self.assertEqual(background[found], originals[found])
        clipped = source(SESSION_A, "t0000002")
        self.assertEqual(background[clipped], originals[clipped][-4:])
        for found, text in background.items():
            self.assertTrue(originals[found].endswith(text), (found, text))
        self.assertEqual([e for e in self.read()[0].evidence if not e.current], [])

    def test_every_record_is_cited_by_its_full_session_id_and_real_entry_id_or_a_physical_line(self):
        path = self.write(SESSION_A, [
            user("p0000001", "2026-09-23T10:00:00", "IDのある発言"),
            user(None, "2026-09-23T10:01:00", "IDのない発言NOID"),
            user("", "2026-09-23T10:02:00", "空IDの発言EMPTYID"),
        ])
        lines = path.read_text(encoding="utf-8").split("\n")

        def line_of(marker: str) -> int:
            return next(number for number, line in enumerate(lines, start=1) if marker in line)

        [session] = self.read()

        self.assertEqual({e.source for e in session.evidence}, {
            source(SESSION_A, "p0000001"),
            source(SESSION_A, f"line-{line_of('NOID')}"),
            source(SESSION_A, f"line-{line_of('EMPTYID')}"),
        })

    def test_only_visible_text_is_evidence_and_long_text_is_kept_whole(self):
        long_text = "".join(f"{number:05d}," for number in range(journal.MESSAGE_CHARS))
        self.write(SESSION_A, [
            user("v0000001", "2026-09-23T10:00:00", long_text),
            assistant("v0000002", "2026-09-23T10:01:00", [
                {"type": "thinking", "thinking": HIDDEN_REASONING},
                text_part("見える応答"),
                {
                    "type": "toolCall", "name": "edit", "intent": TOOL_INTENT,
                    "arguments": {"path": TOOL_ARGUMENT, "i": TOOL_INTENT},
                },
            ]),
            tool_result("v0000003", "2026-09-23T10:02:00", TOOL_OUTPUT),
        ])

        [session] = self.read()

        self.assertGreater(len(long_text), journal.MESSAGE_CHARS)
        self.assertEqual("".join(e.text for e in session.evidence if e.source == source(SESSION_A, "v0000001")), long_text)
        reply = [e for e in session.evidence if e.source == source(SESSION_A, "v0000002")]
        self.assertEqual({e.kind for e in reply}, {"assistant", "tool"})
        tool = next(e for e in reply if e.kind == "tool")
        self.assertIn("edit", tool.text)
        self.assertIn(TOOL_INTENT, tool.text)
        shown = "\n".join(e.text for e in session.evidence)
        for hidden in (HIDDEN_REASONING, TOOL_ARGUMENT, TOOL_OUTPUT):
            self.assertNotIn(hidden, shown)
        self.assertNotIn(source(SESSION_A, "v0000003"), {e.source for e in session.evidence})

    def test_injected_and_automatic_content_is_not_evidence_but_harvest_prompts_stay_raw(self):
        raw = {
            "i0000001": "確認する。\n<system-reminder>\n注入された規則\n</system-reminder>",
            "i0000002": f"<project_memory>\n{INJECTED_MEMORY}\n</project_memory>",
            "i0000003": "<task-notification>タスクの完了通知</task-notification>",
        }
        self.write(SESSION_A, [
            user("i0000001", "2026-09-23T10:00:00", raw["i0000001"]),
            user("i0000002", "2026-09-23T10:01:00", raw["i0000002"]),
            user("i0000003", "2026-09-23T10:02:00", raw["i0000003"]),
            user("i0000004", "2026-09-23T10:03:00", AGENT_INSTRUCTION, attribution="agent"),
            user("i0000005", "2026-09-23T10:04:00", AGENT_INSTRUCTION, attribution="system"),
            user("i0000006", "2026-09-23T10:05:00", AGENT_INSTRUCTION, attribution=None),
        ])

        [session] = self.read()

        self.assertEqual([e.source for e in session.evidence], [source(SESSION_A, "i0000001")])
        self.assertEqual(session.evidence[0].text.strip(), "確認する。")
        self.assertEqual([(prompt.id, prompt.text) for prompt in session.prompts], list(raw.items()))


# 引用に Markdown と HTML として解釈される記法を全て含む。見出し、HTML comment、長さの異なる fence、引用、空行、行末の空白
LITERAL_QUOTE = "\n".join([
    "<!-- caching disabled -->",
    "# 見出しに見える行",
    "```python",
    "print('fence')",
    "````",
    "~~~",
    "> 引用に見える行",
    "- [リンク](http://example.invalid/) と <b>強調</b>",
    "",
    "末尾に空白がある行  ",
    "最後の行 \\ &lt;",
])


def fenced_blocks(document: str) -> tuple[list[list[str]], list[str]]:
    rendered = subprocess.run(
        ["cmark", "--to", "xml"], input=document, capture_output=True, text=True, check=True
    )
    tree = ElementTree.fromstring(rendered.stdout)
    namespace = "{http://commonmark.org/xml/1.0}"
    blocks = [
        (node.text or "").removesuffix("\n").split("\n")
        for node in tree.iter(f"{namespace}code_block")
    ]
    outside = "".join(
        node.text or "" for node in tree.iter() if node.tag in {f"{namespace}text", f"{namespace}code"}
    )
    return blocks, [outside]


class QuotedEvidenceTest(unittest.TestCase):
    CASES = {
        "an HTML comment": "<!-- caching disabled -->",
        "an HTML block and entities": "<script>alert(1)</script>\n&lt;b&gt; &amp;",
        "a heading and a setext underline": "# 見出し\n段落\n=====",
        "a list and a table": "- 項目\n1. 番号\n| a | b |\n|---|---|",
        "inline code": "`code` と ``double``",
        "an inline run of backticks": "x ````` y",
        "a short fence": "```\nbody\n```",
        "a long fence": "`````\nbody\n`````",
        "a tilde fence": "~~~\nbody\n~~~",
        "a blockquote": "> 引用\n>> 入れ子",
        "indented fence-like lines": "   ```\n    ```\n\t```",
        "blank lines and trailing spaces": "最初  \n\n\n最後",
        "CR and CRLF line breaks": "一行目\r\n二行目\r三行目",
    }

    @staticmethod
    def rendered(quote: str, current: bool = True) -> str:
        cited = journal.Citation(source(SESSION_A, "q0000001"), quote, current)
        found = journal.Insight("題", "知見", "説明", "適用", "", "supported", [cited])
        start = local("2026-09-23T06:00:00")
        return journal.render(HOST, DAY, start, start + timedelta(days=1), [found])

    def test_a_quotation_is_rendered_as_the_literal_lines_of_one_code_block(self):
        for name, quote in self.CASES.items():
            with self.subTest(name):
                document = self.rendered(quote)

                blocks, outside = fenced_blocks(document)

                self.assertNotIn("\r", document)
                self.assertEqual(blocks, [quote.replace("\r\n", "\n").replace("\r", "\n").split("\n")])
                for line in filter(str.strip, blocks[0]):
                    self.assertNotIn(line, "\n".join(outside))

    def test_a_background_quotation_names_its_scope_outside_the_literal_block(self):
        blocks, outside = fenced_blocks(self.rendered("背景の本文", current=False))

        self.assertEqual(blocks, [["背景の本文"]])
        self.assertTrue(
            any(source(SESSION_A, "q0000001") in line and "対象の時間帯より前の記録" in line for line in outside)
        )


class ExtractionBatchTest(unittest.TestCase):
    @staticmethod
    def item(number: int, text: str, current: bool = True) -> journal.Evidence:
        return journal.Evidence(source(SESSION_A, f"u{number:07d}"), text, current, "user")

    @staticmethod
    def session(items: list, title: str = "題") -> journal.Session:
        moment = local("2026-09-23T06:00:00")
        return journal.Session(SESSION_A, title, "/work", Path("/work/session.jsonl"), moment, moment, items)

    def materials(self, session: journal.Session) -> list[str]:
        groups = journal.batches(session)
        return [
            journal.extraction_material(session, number, len(groups), group) for number, group in enumerate(groups, start=1)
        ]

    def test_a_batch_may_be_exactly_the_limit_and_one_more_character_starts_another_batch(self):
        fixed = [self.item(number, "x" * 7000) for number in range(5)]

        def lengths(last: int) -> list[int]:
            return [len(material) for material in self.materials(self.session([*fixed, self.item(5, "y" * last)]))]

        [base] = lengths(1)
        last = 1 + journal.CHUNK_CHARS - base
        self.assertLess(last, journal.PIECE_CHARS)
        self.assertEqual(lengths(last), [journal.CHUNK_CHARS])
        over = lengths(last + 1)
        self.assertEqual(len(over), 2)
        self.assertLessEqual(max(over), journal.CHUNK_CHARS)

    def test_a_batch_count_that_widens_the_header_cannot_overflow_a_tightly_packed_batch(self):
        for length in range(7840, 7900):
            with self.subTest(length=length):
                materials = self.materials(self.session([self.item(number, "x" * length) for number in range(50)]))

                self.assertGreaterEqual(len(materials), 10)
                self.assertLessEqual(max(map(len, materials)), journal.CHUNK_CHARS)

    def test_background_is_dropped_oldest_first_and_target_text_is_never_dropped(self):
        background = [self.item(number, "ok", current=False) for number in range(1000)]
        target = [self.item(5000 + number, "z" * 7000) for number in range(12)]
        session = self.session([*background, *target])
        groups = journal.batches(session)

        self.assertGreater(len(groups), 1)
        self.assertLessEqual(max(map(len, self.materials(session))), journal.CHUNK_CHARS)
        contexts = [[found["source"] for found in group if found["scope"] == "background"] for group in groups]
        newest = [item.source for item in background]
        self.assertTrue(0 < len(contexts[0]) < len(background))
        self.assertEqual(contexts[0], newest[len(newest) - len(contexts[0]):])
        self.assertEqual(contexts, [contexts[0]] * len(groups))
        for item in target:
            delivered = "".join(found["text"] for group in groups for found in group if found["source"] == item.source)
            self.assertEqual(delivered, item.text)

    def test_session_information_may_leave_room_for_exactly_one_character_and_one_more_is_an_error(self):
        [base] = map(len, self.materials(self.session([self.item(0, "x")], title="")))
        title = "長" * (journal.CHUNK_CHARS - base)

        self.assertEqual(list(map(len, self.materials(self.session([self.item(0, "x")], title=title)))), [journal.CHUNK_CHARS])
        with self.assertRaises(journal.JournalError):
            journal.batches(self.session([self.item(0, "x")], title=title + "長"))

    def test_every_character_of_a_long_text_is_delivered_including_whitespace_only_pieces(self):
        text = "a" + " \n" * 10000 + "b"
        session = self.session([self.item(0, text)])

        pieces = [found["text"] for group in journal.batches(session) for found in group]

        self.assertGreater(len(pieces), 2)
        self.assertTrue(any(not piece.strip() for piece in pieces))
        self.assertEqual("".join(pieces), text)


class AtomicWriteTest(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="agent-journal-write-test-")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name)

    def populate(self) -> Path:
        directory = self.root / "2026" / "0923"
        directory.mkdir(parents=True)
        target = directory / "host.md"
        target.write_text("previous\n", encoding="utf-8")
        target.chmod(0o644)
        for name in ("other.md", "tmpkeep"):
            (directory / name).write_text("neighbor\n", encoding="utf-8")
        return target

    @staticmethod
    def names(directory: Path) -> list[str]:
        return sorted(path.name for path in directory.iterdir())

    def test_a_write_that_fails_keeps_the_previous_file_and_leaves_no_temporary(self):
        target = self.populate()
        listing = self.names(target.parent)

        for label, document in (("flush at close", "a document longer than the limit\n"), ("direct write", "x" * (1 << 20))):
            with self.subTest(label):
                with file_size_limit(SIZE_LIMIT), self.assertRaises(OSError) as raised:
                    journal.atomic_write(target, document)

                self.assertEqual(raised.exception.errno, errno.EFBIG)
                self.assertEqual(target.read_text(encoding="utf-8"), "previous\n")
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
                self.assertEqual(self.names(target.parent), listing)

    def test_a_replacement_that_fails_keeps_the_destination_and_the_neighbors(self):
        target = self.populate()
        target.unlink()
        target.mkdir()
        (target / "inner").write_text("inner\n", encoding="utf-8")
        listing = self.names(target.parent)

        with self.assertRaises(IsADirectoryError):
            journal.atomic_write(target, "replacement\n")

        self.assertEqual(self.names(target), ["inner"])
        self.assertEqual(self.names(target.parent), listing)

    def test_a_first_publication_that_fails_leaves_no_file_and_the_next_one_succeeds(self):
        target = self.root / "2026" / "0923" / "host.md"

        with file_size_limit(SIZE_LIMIT), self.assertRaises(OSError):
            journal.atomic_write(target, "x" * 100)

        self.assertFalse(target.exists())
        self.assertEqual(self.names(target.parent), [])

        journal.atomic_write(target, "published\n")

        self.assertEqual(target.read_text(encoding="utf-8"), "published\n")
        self.assertEqual(self.names(target.parent), ["host.md"])
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    def test_an_interruption_during_the_replacement_keeps_the_previous_file_and_leaves_no_temporary(self):
        target = self.populate()
        listing = self.names(target.parent)
        previous = signal.signal(signal.SIGTERM, lambda *_: sys.exit(128 + signal.SIGTERM))
        self.addCleanup(signal.signal, signal.SIGTERM, previous)
        temporary_existed = []

        def interrupt(source, _destination):
            temporary_existed.append(Path(source).exists())
            signal.raise_signal(signal.SIGTERM)

        with mock.patch.object(os, "replace", interrupt), self.assertRaises(SystemExit) as raised:
            journal.atomic_write(target, "replacement\n")

        self.assertEqual(temporary_existed, [True])
        self.assertEqual(raised.exception.code, 128 + signal.SIGTERM)
        self.assertEqual(target.read_text(encoding="utf-8"), "previous\n")
        self.assertEqual(self.names(target.parent), listing)

    def test_a_publisher_killed_mid_publication_leaves_its_temporary_and_the_next_writer_removes_only_that(self):
        target = self.populate()
        directory = target.parent
        stale = directory / ".host.md.stale001.tmp"
        foreign_mode = directory / ".host.md.abcdefgh.tmp"
        other_target = directory / ".other.md.abcdefgh.tmp"
        short_token = directory / ".host.md.abc.tmp"
        legacy = directory / "tmpabcdefgh"
        symlink = directory / ".host.md.linkname.tmp"
        folder = directory / ".host.md.dirnames.tmp"
        kept = {foreign_mode: 0o644, other_target: 0o600, short_token: 0o600, legacy: 0o600}
        for path, mode in {stale: 0o600, **kept}.items():
            path.write_text(f"{path.name}\n", encoding="utf-8")
            path.chmod(mode)
        symlink.symlink_to("/elsewhere")
        folder.mkdir()
        ready, release = self.root / "ready", self.root / "release"
        publisher = start_publisher(self, target, "never published\n", ready, release)
        temporary = Path(wait_for(ready, publisher))

        publisher.kill()
        publisher.wait()

        self.assertTrue(temporary.is_file())
        self.assertEqual(target.read_text(encoding="utf-8"), "previous\n")
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(descriptor)
        leftover = self.names(directory)

        journal.atomic_write(target, "after\n")

        self.assertEqual(target.read_text(encoding="utf-8"), "after\n")
        self.assertEqual(self.names(directory), sorted(set(leftover) - {temporary.name, stale.name}))
        for path, mode in kept.items():
            self.assertEqual(path.read_text(encoding="utf-8"), f"{path.name}\n")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)
        self.assertEqual(os.readlink(symlink), "/elsewhere")
        self.assertTrue(folder.is_dir())

    def test_a_live_publisher_keeps_its_temporary_and_the_next_one_waits_for_it(self):
        target = self.populate()
        listing = self.names(target.parent)
        ready, release, started = self.root / "ready", self.root / "release", self.root / "started"
        first = start_publisher(self, target, "first\n", ready, release)
        temporary = Path(wait_for(ready, first))
        second = start_publisher(self, target, "second\n", started=started)
        wait_for(started, second)
        time.sleep(0.5)

        self.assertIsNone(second.poll())
        self.assertTrue(temporary.is_file())
        self.assertEqual(target.read_text(encoding="utf-8"), "previous\n")

        release.touch()

        self.assertEqual(first.wait(timeout=30), 0)
        self.assertEqual(second.wait(timeout=30), 0)
        self.assertEqual(target.read_text(encoding="utf-8"), "second\n")
        self.assertEqual(self.names(target.parent), listing)


if __name__ == "__main__":
    unittest.main()
