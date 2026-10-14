import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import date, datetime, timezone
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
