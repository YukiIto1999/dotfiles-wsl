import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

PACKAGE = Path(sys.argv.pop(1)).resolve()
JOURNAL = Path(sys.argv.pop(1)).resolve()
sys.path[:0] = [str(PACKAGE), str(JOURNAL)]
import harvest

NOW = datetime(2026, 9, 30, 7, 0, tzinfo=timezone.utc)
SESSION = "01a0caa2-0000-7000-8000-000000000001"
CORRECTION = "検証は focused check を先に通してから全体の check を回す。"
CHATTER = "いまどこまで進みましたか"
EXISTING = "作業報告は日本語で書く。"
# 将来の別 session で同じ判断を迫られる場面を書けない発言。その場の禁止と許可、状況に依る優先度と締切、
# 個人名、正本へ入れるよう求めた規律、製品仕様である
NEGATIVES = [
    "モデルの切り替えは許可しない。現行のモデルのまま続けてください。",
    "git 履歴は全面的に直してよい",
    "山田さんから指摘された内容とその周辺を優先して対応する",
    "金曜までにこれを終わらせることを優先してください",
    "体言止めが望ましいので、標準に入れてください",
    "注文一覧は締め日の降順で表示する",
]
SITUATION = "別の変更を検証する順番を決めるとき"


def stamp(value: str) -> str:
    return value + "Z"


def user(entry_id: str, at: str, text: str, attribution: str = "user") -> dict:
    return {
        "type": "message",
        "id": entry_id,
        "timestamp": stamp(at),
        "message": {"role": "user", "content": [{"type": "text", "text": text}], "attribution": attribution},
    }


def assistant(entry_id: str, at: str, text: str) -> dict:
    return {
        "type": "message",
        "id": entry_id,
        "timestamp": stamp(at),
        "message": {"role": "assistant", "content": [{"type": "text", "text": text}], "stopReason": "stop"},
    }


# 利用者の訂正、進捗の問い合わせ、注入された記憶、既存の記憶と同じ発言、将来の場面を書けない発言を一つの session に並べる
ENTRIES = [
    user("u0000001", "2026-09-29T10:00:00", CORRECTION),
    assistant("a0000001", "2026-09-29T10:01:00", "応答の本文"),
    {
        "type": "message",
        "id": "t0000001",
        "timestamp": stamp("2026-09-29T10:02:00"),
        "message": {"role": "toolResult", "toolName": "read", "content": [{"type": "text", "text": "ツール結果の本文"}]},
    },
    user("u0000002", "2026-09-29T10:03:00", CHATTER),
    {
        "type": "custom_message",
        "id": "c0000001",
        "timestamp": stamp("2026-09-29T10:04:00"),
        "customType": "project-memory-context",
        "content": "<project_memory>\ncontext-memory-marker\n</project_memory>",
        "attribution": "agent",
    },
    user("u0000003", "2026-09-29T10:05:00", "<project_memory>\n{\"claim\": \"injected-memory-marker\"}\n</project_memory>"),
    user("u0000004", "2026-09-29T10:06:00", EXISTING),
    *(user(f"n{index:07d}", f"2026-09-29T10:{10 + index:02d}:00", text) for index, text in enumerate(NEGATIVES)),
]

# 発言をすべて候補にする model の代わり。将来の場面は訂正と既存の記憶と同じ発言にだけ書き、他は空にする
FAKE_OMP = f"""\
import json, os, re, sys
material = sys.stdin.read()
with open(os.environ["FAKE_OMP_LOG"], "a", encoding="utf-8") as log:
    log.write(material + "\\n---\\n")
if os.environ.get("FAKE_OMP_FAIL"):
    sys.exit("model unavailable")
situations = {{{CORRECTION!r}: {SITUATION!r}, {EXISTING!r}: "作業報告を書くとき"}}
candidates = [
    {{"ref": ref, "kind": "correction", "situation": situations.get(text, ""), "content": text}}
    for ref, text in re.findall(r"^\\[(m\\d+)\\] (.*)$", material, re.MULTILINE)
]
print(json.dumps(candidates, ensure_ascii=False))
"""

# dotfiles-memory の代わり。受けた要求を記録し、環境変数で指定した結果を返す
FAKE_MEMORY = """\
import json, os, sys
from pathlib import Path
command = sys.argv[1]
request = json.loads(sys.stdin.read() or "null")
with open(os.environ["FAKE_MEMORY_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"command": command, "argv": sys.argv[2:], "request": request}, ensure_ascii=False) + "\\n")
def fail(code):
    print(f"project-memory: {code}: fixture failure", file=sys.stderr)
    sys.exit(1)
if command == "project":
    if not Path(sys.argv[2]).is_dir():
        fail("invalid_input")
    print(json.dumps({"bank_id": "project-fixture"}))
elif command == "curated":
    memories = json.loads(Path(os.environ["FAKE_MEMORY_CURATED"]).read_text(encoding="utf-8"))
    print(json.dumps({"scope": "project", "bank_id": "project-fixture", "memories": memories}, ensure_ascii=False))
elif command == "save":
    if os.environ.get("FAKE_SAVE_FAIL"):
        fail(os.environ["FAKE_SAVE_FAIL"])
    state = os.environ.get("FAKE_SAVE_STATE", "saved")
    print(json.dumps({"state": state, "scope": "project", "operation_id": "operation-1", "document_id": "correction/document-1"}))
elif command == "status":
    print(json.dumps({"state": os.environ.get("FAKE_STATUS_STATE", "saved"), **request}))
else:
    fail("invalid_input")
"""


class HarvestTest(unittest.TestCase):
    def setUp(self):
        self.workspace = Path(tempfile.mkdtemp(prefix="memory-harvest-test-"))
        self.project = self.workspace / "projects" / "sample"
        self.project.mkdir(parents=True)
        self.sessions = self.workspace / "sessions"
        directory = self.sessions / "-projects-sample"
        directory.mkdir(parents=True)
        self.session_file = directory / f"2026-09-29T10-00-00-000Z_{SESSION}.jsonl"
        lines = [
            {"type": "title", "v": 1, "title": "訂正を受けた作業", "source": "auto"},
            {"type": "session", "version": 3, "id": SESSION, "timestamp": ENTRIES[0]["timestamp"], "cwd": str(self.project)},
            *ENTRIES,
        ]
        self.session_file.write_text("".join(json.dumps(line, ensure_ascii=False) + "\n" for line in lines), encoding="utf-8")
        # 実時刻に依らず、file の更新時刻を最後の entry に合わせる
        last = datetime.fromisoformat(ENTRIES[-1]["timestamp"].replace("Z", "+00:00")).timestamp()
        os.utime(self.session_file, (last, last))
        # subagent の記録は親 session の隣の directory に置かれ、利用者の発言ではない
        nested = directory / self.session_file.stem
        nested.mkdir()
        (nested / "Scout.jsonl").write_text(
            json.dumps({"type": "session", "version": 3, "id": "Scout", "timestamp": ENTRIES[0]["timestamp"], "cwd": str(self.project)}) + "\n"
            + json.dumps(user("s0000001", "2026-09-29T10:07:00", "subagent-instruction-marker", attribution="agent"), ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

        self.curated = self.workspace / "curated.json"
        self.curated.write_text(json.dumps([
            {"document_id": "preference/existing", "kind": "preference", "source": "user-confirmed:fixture", "content": EXISTING},
        ], ensure_ascii=False), encoding="utf-8")
        self.omp_log = self.workspace / "omp.log"
        self.memory_log = self.workspace / "memory.log"
        self.omp = self.script("omp", FAKE_OMP)
        self.memory = self.script("dotfiles-memory", FAKE_MEMORY)
        self.state = self.workspace / "state" / "memory-harvest.json"
        self.environment({
            "FAKE_OMP_LOG": str(self.omp_log),
            "FAKE_MEMORY_LOG": str(self.memory_log),
            "FAKE_MEMORY_CURATED": str(self.curated),
        })

    def environment(self, values: dict) -> None:
        for key, value in values.items():
            previous = os.environ.get(key)
            os.environ[key] = value
            self.addCleanup(self.restore, key, previous)

    @staticmethod
    def restore(key: str, previous: str | None) -> None:
        if previous is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = previous

    def script(self, name: str, body: str) -> Path:
        path = self.workspace / name
        path.write_text(f"#!{sys.executable}\n{body}", encoding="utf-8")
        path.chmod(0o755)
        return path

    def run_harvest(self, now: datetime = NOW, status: int = 0) -> str:
        output = io.StringIO()
        with redirect_stdout(output):
            result = harvest.main([
                "--sessions-root", str(self.sessions),
                "--state-file", str(self.state),
                "--lookback-days", "7",
                "--memory", str(self.memory),
                "--omp", str(self.omp),
                "--model", "fake/model",
                "--thinking", "low",
            ], now=now)
        self.assertEqual(result, status, output.getvalue())
        return output.getvalue()

    def calls(self, command: str) -> list[dict]:
        if not self.memory_log.exists():
            return []
        rows = [json.loads(line) for line in self.memory_log.read_text(encoding="utf-8").splitlines()]
        return [row["request"] for row in rows if row["command"] == command]

    def cursor(self) -> str | None:
        return json.loads(self.state.read_text(encoding="utf-8"))["since"] if self.state.exists() else None

    def locator(self, entry_id: str) -> str:
        return f"{self.session_file}#{entry_id}"

    def test_only_a_new_user_correction_is_saved_with_its_locator(self):
        output = self.run_harvest()

        # 将来の場面は判定にだけ使い、保存する本文には含めない
        self.assertEqual(self.calls("save"), [{
            "cwd": str(self.project),
            "content": CORRECTION,
            "source": self.locator("u0000001"),
            "scope": "project",
            "kind": "correction",
        }])
        self.assertIn(f"saved: {self.locator('u0000001')}", output)
        dropped = [self.locator("u0000002"), *(self.locator(f"n{index:07d}") for index in range(len(NEGATIVES)))]
        for source in dropped:
            self.assertIn(f"no-situation: {source}", output)
        material = self.omp_log.read_text(encoding="utf-8")
        for included in (CORRECTION, CHATTER, EXISTING):
            self.assertIn(included, material)
        for excluded in ("応答の本文", "ツール結果の本文", "context-memory-marker", "injected-memory-marker", "subagent-instruction-marker"):
            self.assertNotIn(excluded, material)
        self.assertEqual(self.cursor(), NOW.isoformat())

    def test_the_cursor_advances_only_after_a_successful_run(self):
        self.environment({"FAKE_OMP_FAIL": "1"})
        self.run_harvest(status=1)
        self.assertNotEqual(self.cursor(), NOW.isoformat())
        self.assertEqual(self.calls("save"), [])

        del os.environ["FAKE_OMP_FAIL"]
        self.environment({"FAKE_SAVE_FAIL": "backend_error"})
        self.run_harvest(status=1)
        self.assertNotEqual(self.cursor(), NOW.isoformat())

        del os.environ["FAKE_SAVE_FAIL"]
        self.run_harvest()
        self.assertEqual(self.cursor(), NOW.isoformat())
        self.assertEqual([save["source"] for save in self.calls("save")], [self.locator("u0000001")] * 2)

    def test_pending_is_not_reported_saved_until_status_confirms_it(self):
        self.environment({"FAKE_SAVE_STATE": "pending", "FAKE_STATUS_STATE": "pending"})
        first = self.run_harvest()
        self.assertIn(f"pending: {self.locator('u0000001')}", first)
        self.assertNotIn("saved:", first)
        self.assertEqual(self.cursor(), NOW.isoformat())

        still = self.run_harvest(now=NOW + timedelta(hours=1))
        self.assertNotIn("saved:", still)

        os.environ["FAKE_STATUS_STATE"] = "saved"
        confirmed = self.run_harvest(now=NOW + timedelta(days=1))
        self.assertIn(f"saved: {self.locator('u0000001')}", confirmed)
        self.assertEqual(len(self.calls("save")), 1)
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["pending"], [])

    def test_entries_whose_memory_is_already_saved_are_not_sent_again(self):
        memories = json.loads(self.curated.read_text(encoding="utf-8"))
        memories.append({"document_id": "correction/saved", "kind": "correction", "source": self.locator("u0000001"), "content": "言い換えた訂正"})
        self.curated.write_text(json.dumps(memories, ensure_ascii=False), encoding="utf-8")

        self.run_harvest()
        self.assertNotIn(CORRECTION, self.omp_log.read_text(encoding="utf-8"))
        self.assertEqual(self.calls("save"), [])

    def test_a_privacy_rejection_does_not_block_the_cursor(self):
        self.environment({"FAKE_SAVE_FAIL": "privacy"})
        output = self.run_harvest()
        self.assertIn(f"rejected: {self.locator('u0000001')}", output)
        self.assertEqual(self.cursor(), NOW.isoformat())


if __name__ == "__main__":
    unittest.main()
