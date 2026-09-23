import json
import os
import subprocess
import sys
import tempfile
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
        self.fake_omp.write_text(
            f"#!{sys.executable}\n"
            "import os, sys\n"
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
            "--host", HOST,
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

    def test_pending_days_end_at_the_last_completed_window(self):
        before = journal.pending_days(local("2026-09-24T05:59:59"), TZ, 6, 2, self.journal, HOST)
        at = journal.pending_days(local("2026-09-24T06:00:00"), TZ, 6, 2, self.journal, HOST)
        self.assertEqual(before, [date(2026, 9, 21), date(2026, 9, 22)])
        self.assertEqual(at, [date(2026, 9, 22), DAY])

        existing = self.journal / "2026" / "0922" / f"{HOST}.md"
        existing.parent.mkdir(parents=True)
        existing.write_text("# 既存\n")
        self.assertEqual(journal.pending_days(local("2026-09-24T06:00:00"), TZ, 6, 2, self.journal, HOST), [DAY])


if __name__ == "__main__":
    unittest.main()
