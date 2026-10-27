import errno
import fcntl
import io
import json
import os
import resource
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import contextmanager, redirect_stderr
from datetime import date, datetime, timezone
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

PACKAGE = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(PACKAGE))
import journal

TZ = ZoneInfo("Asia/Tokyo")
DAY = date(2026, 9, 23)
HOST = "testhost"
DAY_FILE = "2026/0923/testhost.md"
DEADLINE = "DOTFILES_JOB_DEADLINE"
SESSION_A = "01a0caa2-0000-7000-8000-000000000001"
SESSION_B = "02b0cbb3-0000-7000-8000-000000000002"
SESSION_C = "03c0ccc4-0000-7000-8000-000000000003"


def local(value: str) -> datetime:
    return datetime.fromisoformat(value).replace(tzinfo=TZ)


def stamp(value: str) -> str:
    return local(value).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def user(at: str, text: str) -> dict:
    return {
        "type": "message",
        "timestamp": stamp(at),
        "message": {"role": "user", "content": [{"type": "text", "text": text}], "attribution": "user"},
    }


def assistant(at: str, parts: list, stop: str, cost: float) -> dict:
    return {
        "type": "message",
        "timestamp": stamp(at),
        "message": {
            "role": "assistant",
            "content": parts,
            "stopReason": stop,
            "usage": {"cost": {"total": cost}},
        },
    }


def tool_result(at: str, text: str) -> dict:
    return {
        "type": "message",
        "timestamp": stamp(at),
        "message": {"role": "toolResult", "toolName": "read", "content": [{"type": "text", "text": text}]},
    }


def write_session(root: Path, bucket: str, session_id: str, cwd: Path, title: str, entries: list) -> Path:
    directory = root / bucket
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"2026-09-23T00-00-00-000Z_{session_id}.jsonl"
    lines = [
        {"type": "title", "v": 1, "title": title, "source": "auto"},
        {"type": "session", "version": 3, "id": session_id, "timestamp": entries[0]["timestamp"], "cwd": str(cwd)},
        *entries,
    ]
    path.write_text("".join(json.dumps(line, ensure_ascii=False) + "\n" for line in lines), encoding="utf-8")
    last = datetime.fromisoformat(entries[-1]["timestamp"].replace("Z", "+00:00")).timestamp()
    os.utime(path, (last, last))
    return path


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

        self.project = self.workspace / "projects" / "sample"
        self.project.mkdir(parents=True)
        git("init", "-q", cwd=self.project)
        for subject, at in (("feat: 窓の中の変更", "2026-09-23T10:00:00"), ("feat: 窓の外の変更", "2026-09-24T07:00:00")):
            dated = {**os.environ, "GIT_AUTHOR_DATE": local(at).isoformat(), "GIT_COMMITTER_DATE": local(at).isoformat()}
            git("commit", "-q", "--allow-empty", "-m", subject, cwd=self.project, env=dated)
        self.scratch = self.workspace / "scratch"
        self.scratch.mkdir()

        self.sessions = self.workspace / "sessions"
        path_a = write_session(self.sessions, "-projects-sample", SESSION_A, self.project, "境界の作業", [
            user("2026-09-23T05:59:59", "前日の依頼"),
            user("2026-09-23T06:00:00", "境界の依頼"),
            assistant("2026-09-23T06:01:00", [
                {"type": "thinking", "thinking": "内部推論の秘密"},
                {"type": "text", "text": "途中の説明"},
                {"type": "toolCall", "name": "edit", "intent": "Editing bootstrap", "arguments": {"path": "a", "i": "Editing bootstrap"}},
            ], "toolUse", 0.5),
            tool_result("2026-09-23T06:02:00", "ツール結果の本文"),
            assistant("2026-09-23T06:03:00", [{"type": "text", "text": "最終応答の決定"}], "stop", 0.25),
            user("2026-09-24T06:00:00", "翌日の依頼"),
        ])
        # subagent の記録も session と同じ形で親 session の隣の directory に置かれる
        write_session(self.sessions, f"-projects-sample/{path_a.stem}", "Scout", self.project, "subagent", [
            user("2026-09-23T07:00:00", "サブエージェントの本文"),
        ])
        write_session(self.sessions, "--tmp--", SESSION_B, self.scratch, "別の作業", [
            user("2026-09-23T23:00:00", "別プロジェクトの依頼"),
            assistant("2026-09-23T23:01:00", [{"type": "text", "text": "別プロジェクトの応答"}], "stop", 0.125),
        ])
        write_session(self.sessions, "-projects-sample", SESSION_C, self.project, "前々日の作業", [
            user("2026-09-21T12:00:00", "前々日の依頼"),
        ])

        self.prompts = self.workspace / "prompts.log"
        self.fake_omp = self.workspace / "omp"
        self.argv_log = self.workspace / "argv.log"
        self.fake_omp.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"with open({str(self.argv_log)!r}, 'a', encoding='utf-8') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"with open({str(self.prompts)!r}, 'a', encoding='utf-8') as log:\n"
            "    material = sys.stdin.read()\n"
            "    log.write(material + '\\n---\\n')\n"
            "marker = os.environ.get('FAKE_OMP_FAIL_ON')\n"
            "if marker and marker in material:\n"
            "    sys.exit('model unavailable')\n"
            "print('### 依頼\\n- 要約された依頼')\n"
        )
        self.fake_omp.chmod(0o755)

        self.remote = self.workspace / "remote.git"
        git("init", "-q", "--bare", str(self.remote))
        self.journal = self.workspace / "agent-journal"
        git("clone", "-q", str(self.remote), str(self.journal))

    def run_journal(self, *extra: str, now: datetime | None = None, status: int = 0) -> None:
        result = journal.main([
            "--sessions-root", str(self.sessions),
            "--journal-dir", str(self.journal),
            "--machine-name", HOST,
            "--timezone", "Asia/Tokyo",
            "--start-hour", "6",
            "--lookback-days", "7",
            "--omp", str(self.fake_omp),
            "--model", "fake/model",
            "--thinking", "low",
            *extra,
        ], now=now)
        self.assertEqual(result, status)

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

    def model_calls(self, marker: str) -> int:
        return self.prompts.read_text(encoding="utf-8").count(marker) if self.prompts.exists() else 0

    def model_argv(self) -> list[list[str]]:
        return [json.loads(line) for line in self.argv_log.read_text(encoding="utf-8").splitlines()]

    def test_day_is_summarized_from_its_window_and_published(self):
        self.run_journal("--date", DAY.isoformat())

        prompts = self.prompts.read_text(encoding="utf-8")
        for included in ("境界の依頼", "途中の説明", "Editing bootstrap", "最終応答の決定", "別プロジェクトの依頼", "feat: 窓の中の変更"):
            self.assertIn(included, prompts)
        for excluded in ("前日の依頼", "翌日の依頼", "内部推論の秘密", "ツール結果の本文", "サブエージェントの本文", "前々日の依頼", "feat: 窓の外の変更"):
            self.assertNotIn(excluded, prompts)

        published = git("--git-dir", str(self.remote), "show", "main:2026/0923/testhost.md")
        self.assertIn(SESSION_A, published)
        self.assertIn(SESSION_B, published)
        self.assertNotIn(SESSION_C[:8], published)
        self.assertIn("feat: 窓の中の変更", published)
        self.assertIn("0.875", published)

        commits = git("--git-dir", str(self.remote), "rev-list", "--count", "main")
        self.run_journal("--date", DAY.isoformat())
        self.assertEqual(git("--git-dir", str(self.remote), "rev-list", "--count", "main"), commits)

    def test_a_failed_day_does_not_block_other_days(self):
        os.environ["FAKE_OMP_FAIL_ON"] = "前々日の依頼"
        self.addCleanup(os.environ.pop, "FAKE_OMP_FAIL_ON", None)
        now = local("2026-09-24T06:00:00")

        # 09-21 は model が失敗し、それより後の 09-22 と 09-23 は記録される
        self.run_journal(now=now, status=1)
        self.assertEqual(self.published(), ["2026/0922/testhost.md", "2026/0923/testhost.md"])

        del os.environ["FAKE_OMP_FAIL_ON"]
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
        self.assertFalse(self.prompts.exists())

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
        calls = self.model_calls("境界の依頼")
        hook.unlink()

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertEqual(self.model_calls("境界の依頼"), calls)
        self.assertEqual(self.remote_file(DAY_FILE), edited)
        self.assertEqual(self.local_commit(DAY_FILE), self.remote_commit(DAY_FILE))
        self.assertEqual(len(git("log", "--format=%H", "--", DAY_FILE, cwd=self.journal).splitlines()), 1)

    def test_a_push_failure_keeps_the_local_commit_and_the_next_ordinary_run_only_publishes_it(self):
        git("config", "remote.origin.pushurl", str(self.workspace / "no-such-remote.git"), cwd=self.journal)

        self.run_journal("--date", DAY.isoformat(), status=1)

        self.assertTrue(self.committed(DAY_FILE))
        self.assertIsNone(self.remote_file(DAY_FILE))
        committed = self.local_commit(DAY_FILE)
        calls = self.model_calls("境界の依頼")
        git("config", "--unset", "remote.origin.pushurl", cwd=self.journal)

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertEqual(self.model_calls("境界の依頼"), calls)
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
        calls = self.model_calls("前日の依頼")
        hook.unlink()

        self.run_journal(now=now)

        self.assertEqual(self.published(), ["2026/0921/testhost.md", "2026/0922/testhost.md", "2026/0923/testhost.md"])
        self.assertEqual(self.model_calls("前日の依頼"), calls)
        self.assertEqual(before, {day: self.remote_commit(f"2026/{day}/testhost.md") for day in ("0921", "0923")})

    def test_an_unfinished_day_outside_the_lookback_is_resumed_from_its_file_without_the_model(self):
        old = self.journal / "2026" / "0910" / f"{HOST}.md"
        old.parent.mkdir(parents=True)
        old.write_text("# 2026-09-10 testhost\n\n以前に生成した本文\n", encoding="utf-8")
        git("add", "--", "2026/0910", cwd=self.journal)

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertEqual(self.remote_file("2026/0910/testhost.md"), old.read_text(encoding="utf-8"))
        self.assertNotIn("以前に生成した本文", self.prompts.read_text(encoding="utf-8"))

    def test_no_child_starts_after_the_job_deadline(self):
        os.environ[DEADLINE] = str(time.time() - 1)
        self.addCleanup(os.environ.pop, DEADLINE, None)

        self.run_journal("--date", DAY.isoformat(), status=1)

        self.assertFalse(self.prompts.exists())
        self.assertFalse((self.journal / DAY_FILE).exists())

    def test_the_job_deadline_bounds_the_model_it_is_passed_to(self):
        os.environ[DEADLINE] = str(time.time() + 400)
        self.addCleanup(os.environ.pop, DEADLINE, None)

        self.run_journal("--date", DAY.isoformat())

        limits = [int(argv[argv.index("--max-time") + 1]) for argv in self.model_argv()]
        self.assertTrue(limits)
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

        with mock.patch.object(journal, "atomic_write", constrained), self.assertRaises(OSError) as raised:
            self.run_journal("--date", DAY.isoformat())

        self.assertEqual(raised.exception.errno, errno.EFBIG)
        self.assertEqual(sorted(path.name for path in directory.iterdir()), ["other.md", "tmpkeep"])
        self.assertIsNone(self.remote_file(DAY_FILE))

        self.run_journal(now=local("2026-09-24T06:00:00"))

        self.assertEqual(sorted(path.name for path in directory.iterdir()), ["other.md", "testhost.md", "tmpkeep"])
        self.assertEqual(self.remote_file(DAY_FILE), (self.journal / DAY_FILE).read_text(encoding="utf-8"))
        self.assertEqual((directory / "other.md").read_text(encoding="utf-8"), "neighbor\n")
        self.assertEqual((directory / "tmpkeep").read_text(encoding="utf-8"), "neighbor\n")

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
