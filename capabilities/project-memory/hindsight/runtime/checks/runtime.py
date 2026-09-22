import asyncio
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote, urlparse
import httpx

PACKAGE = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(PACKAGE))
from hooks import last_complete_turn, transcript_messages
import memory as memory_module
from memory import Client, MemoryFailure


class Backend(BaseHTTPRequestHandler):
    state = {}

    def log_message(self, *_):
        pass

    def respond(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        self.state["requests"].append(("GET", path))
        if path == "/v1/default/banks":
            self.respond(200, {"banks": [{"bank_id": bank} for bank in self.state["banks"]]})
        elif "/operations/" in path:
            self.respond(200, {"operation_id": path.rsplit("/", 1)[1], "status": self.state["operation_state"]})
        elif "/documents/" in path:
            document = self.state["document"]
            if document is None:
                self.respond(404, {})
            else:
                self.respond(200, document)
        elif path.endswith("/history"):
            self.respond(200, self.state["history"])
        elif "/memories/" in path:
            self.respond(200, self.state["memory"])
        elif path == "/health/ready":
            self.respond(200, {"status": "healthy"})
        elif path == "/version":
            self.respond(200, {"version": "fixture"})
        else:
            self.respond(404, {})

    def do_PATCH(self):
        self.state["requests"].append(("PATCH", self.path))
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        bank = self.path.split("/")[4]
        self.state["banks"].add(bank)
        self.respond(200, {"bank_id": bank, "overrides": body["updates"]})

    def do_POST(self):
        self.state["requests"].append(("POST", self.path))
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        bank = self.path.split("/")[4]
        if self.path.endswith("/memories/recall"):
            self.respond(self.state["recall_status"], {"results": []})
            return
        if self.state["retain_status"] != 200:
            self.respond(self.state["retain_status"], {})
            return
        item = body["items"][0]
        self.state["items"].append(item)
        self.state["document"] = {
            "id": item["document_id"], "bank_id": bank,
            "original_text": item["content"], "document_metadata": item["metadata"],
            "memory_unit_count": 1,
        }
        if self.state.get("drop_retain_response"):
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        self.respond(200, {"success": True, "bank_id": bank, "async": True, "items_count": 1, "operation_id": body["operation_id"]})


class RuntimeContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.root = Path(cls.workspace.name)
        cls.server = HTTPServer(("127.0.0.1", 0), Backend)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"
        cls.repo = cls.root / "one" / "same-name"
        cls.repo.mkdir(parents=True)
        cls.git("init", str(cls.repo))
        cls.git("-C", str(cls.repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "test: 作業ツリー識別のfixtureを作る")

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.workspace.cleanup()

    @staticmethod
    def git(*arguments):
        return subprocess.run(["git", *arguments], check=True, capture_output=True, text=True)

    def setUp(self):
        Backend.state = {"requests": [], "banks": set(), "operation_state": "completed", "document": None, "items": [], "retain_status": 200, "recall_status": 200}

    def command(self, command, payload=None, *arguments):
        result = subprocess.run(
            [sys.executable, str(PACKAGE / "main.py"), command, *arguments],
            input=json.dumps(payload) if payload is not None else "",
            capture_output=True, text=True, timeout=25,
            env={**os.environ, "PROJECT_MEMORY_URL": self.url},
        )
        return result

    def save(self):
        return self.command("save", {"cwd": str(self.repo), "content": "利用者の訂正は推測より優先する。", "source": "user-confirmed:fixture"})

    def test_retain_404_is_failure_not_saved(self):
        Backend.state["retain_status"] = 404
        result = self.save()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 404", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_pending_operation_is_not_saved(self):
        Backend.state["operation_state"] = "pending"
        result = self.command("hook", {"cwd": str(self.repo), "session_id": "pending-case", "messages": [{"role": "user", "content": "このprojectでは訂正を先に確認する。"}, {"role": "assistant", "content": "確認しました。", "complete": True}]}, "--harness", "omp", "stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["state"], "pending")

    def test_lost_retain_response_keeps_status_receipt(self):
        Backend.state["drop_retain_response"] = True
        result = self.save()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["state"], "indeterminate")
        checked = self.command("status", {"cwd": str(self.repo), **{key: receipt[key] for key in ("scope", "operation_id", "document_id")}})
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(json.loads(checked.stdout)["state"], "saved")
        self.assertEqual(len(Backend.state["items"]), 1)

    def test_retain_owner_deadline_returns_indeterminate_receipt(self):
        async def scenario():
            post_seen = asyncio.Event()
            gate = asyncio.Event()
            timeout_context = {}
            real_timeout = asyncio.timeout

            async def handler(request):
                path = request.url.path
                if request.method == "PATCH":
                    return httpx.Response(200, json={"bank_id": path.split("/")[4], "overrides": {}})
                if request.method == "POST" and path.endswith("/memories"):
                    post_seen.set()
                    timeout_context["value"].reschedule(asyncio.get_running_loop().time() - 1)
                    await gate.wait()
                raise AssertionError(f"unexpected request: {request.method} {path}")

            client = Client("http://memory.test")
            await client.http.aclose()
            client.http = httpx.AsyncClient(base_url="http://memory.test", transport=httpx.MockTransport(handler), timeout=None)

            def controlled_timeout(delay):
                timeout = real_timeout(delay)
                timeout_context["value"] = timeout
                return timeout

            try:
                with patch.object(memory_module.asyncio, "timeout", controlled_timeout):
                    receipt = await client.save(str(self.repo), "deadline content", "user-confirmed:deadline")
            finally:
                await client.http.aclose()
            self.assertTrue(post_seen.is_set())
            return receipt

        receipt = asyncio.run(scenario())
        self.assertEqual(receipt["state"], "indeterminate")
        self.assertIn("operation_id", receipt)
        self.assertIn("document_id", receipt)
        self.assertEqual(receipt["scope"], "project")

    def test_external_cancel_during_retain_propagates(self):
        async def scenario():
            post_seen = asyncio.Event()
            gate = asyncio.Event()

            async def handler(request):
                path = request.url.path
                if request.method == "PATCH":
                    return httpx.Response(200, json={"bank_id": path.split("/")[4], "overrides": {}})
                if request.method == "POST" and path.endswith("/memories"):
                    post_seen.set()
                    await gate.wait()
                raise AssertionError(f"unexpected request: {request.method} {path}")

            client = Client("http://memory.test")
            await client.http.aclose()
            client.http = httpx.AsyncClient(base_url="http://memory.test", transport=httpx.MockTransport(handler), timeout=None)
            task = asyncio.create_task(client.save(str(self.repo), "cancel content", "user-confirmed:cancel"))
            post_waiter = asyncio.create_task(post_seen.wait())
            try:
                await asyncio.wait((task, post_waiter), return_when=asyncio.FIRST_COMPLETED)
                self.assertTrue(post_seen.is_set())
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
            finally:
                gate.set()
                post_waiter.cancel()
                await asyncio.gather(task, post_waiter, return_exceptions=True)
                await client.http.aclose()

        asyncio.run(scenario())

    def test_recall_requires_explicit_scope(self):
        result = self.command("recall", {"cwd": str(self.repo), "query": "利用者の訂正"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_input", result.stderr)
        self.assertEqual(Backend.state["requests"], [])

    def test_incomplete_latest_assistant_is_not_captured(self):
        result = last_complete_turn([
            {"role": "user", "content": "genuine-user-correction"},
            {"role": "assistant", "content": "earlier-complete-answer", "complete": True},
            {"role": "assistant", "content": "", "complete": False},
        ])
        self.assertIsNone(result)

    def test_saved_requires_durable_matching_document(self):
        saved = self.save()
        self.assertEqual(saved.returncode, 0, saved.stderr)
        receipt = json.loads(saved.stdout)
        self.assertEqual(receipt["state"], "saved")
        Backend.state["document"]["original_text"] = "different persisted content"
        checked = self.command("status", {"cwd": str(self.repo), **{key: receipt[key] for key in ("scope", "operation_id", "document_id")}})
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("not_verified", checked.stderr)

    def test_status_rejects_unrelated_completed_operation(self):
        saved = self.save()
        self.assertEqual(saved.returncode, 0, saved.stderr)
        receipt = json.loads(saved.stdout)
        result = self.command("status", {"cwd": str(self.repo), "scope": receipt["scope"], "document_id": receipt["document_id"], "operation_id": str(uuid.uuid4())})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_input", result.stderr)

    def test_failed_operation_never_returns_saved(self):
        Backend.state["operation_state"] = "failed"
        result = self.save()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("retain_failed", result.stderr)

    def test_missing_recall_endpoint_is_not_empty_success(self):
        bank = json.loads(self.command("project", None, str(self.repo)).stdout)["bank_id"]
        Backend.state["banks"].add(bank)
        Backend.state["recall_status"] = 404
        result = self.command("recall", {"cwd": str(self.repo), "query": "利用者の訂正", "scope": "project"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 404", result.stderr)

    def test_verify_observation_with_array_history(self):
        Backend.state["memory"] = {
            "id": "observation", "type": "observation", "document_id": None,
            "source_memories": [{"id": "source-fact", "text": "利用者が訂正した検証条件", "type": "world"}],
        }
        Backend.state["history"] = []
        result = self.command("verify", {"cwd": str(self.repo), "memory_id": "observation", "scope": "project"})
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads(result.stdout)
        self.assertEqual(evidence["memory"]["source_memories"][0]["id"], "source-fact")
        self.assertEqual(evidence["history"], [])
        self.assertFalse(evidence["verified_against_primary_source"])

    def test_same_name_projects_isolate_worktrees_share(self):
        other = self.root / "two" / "same-name"
        other.mkdir(parents=True)
        self.git("init", str(other))
        worktree = self.root / "linked"
        self.git("-C", str(self.repo), "worktree", "add", "--detach", str(worktree))
        try:
            banks = [json.loads(self.command("project", None, str(path)).stdout)["bank_id"] for path in (self.repo, other, worktree)]
            self.assertNotEqual(banks[0], banks[1])
            self.assertEqual(banks[0], banks[2])
        finally:
            self.git("-C", str(self.repo), "worktree", "remove", str(worktree))

    def test_capture_rejects_credential_shaped_json_before_http(self):
        result = self.command("hook", {"cwd": str(self.repo), "session_id": "privacy-case", "messages": [{"role": "user", "content": '{"api_key": "synthetic-secret-value"}'}, {"role": "assistant", "content": "保存しません。", "complete": True}]}, "--harness", "omp", "stop")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("privacy", result.stderr)
        self.assertNotIn("synthetic-secret-value", result.stderr + result.stdout)
        self.assertEqual(Backend.state["requests"], [])

    def test_recalled_context_cannot_be_recaptured(self):
        result = last_complete_turn([
            {"role": "user", "content": "<project_memory>old-history-marker</project_memory>\n新しい訂正です。"},
            {"role": "assistant", "content": "訂正を確認しました。", "complete": True},
            {"role": "tool", "content": "raw-tool-secret"},
        ])
        self.assertIn("新しい訂正", result)
        self.assertNotIn("old-history-marker", result)
        self.assertNotIn("raw-tool-secret", result)

    def transcript(self, harness, rows):
        path = self.root / (harness + ".jsonl")
        path.write_text("\n".join(json.dumps(row) for row in rows))
        return last_complete_turn(transcript_messages(str(path), harness))

    def test_claude_summary_is_not_user_instruction(self):
        result = self.transcript("claude", [
            {"type": "user", "promptSource": "sdk", "message": {"role": "user", "content": "genuine-user-correction"}},
            {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "verified-answer"}], "stop_reason": "end_turn"}},
            {"type": "user", "isCompactSummary": True, "message": {"role": "user", "content": "synthetic-summary"}},
            {"type": "assistant", "isSidechain": True, "message": {"role": "assistant", "content": [{"type": "text", "text": "subagent-guess"}], "stop_reason": "end_turn"}},
        ])
        self.assertIn("genuine-user-correction", result)
        self.assertNotIn("synthetic-summary", result)
        self.assertNotIn("subagent-guess", result)

    def test_claude_stop_final_message_overrides_lagging_transcript(self):
        path = self.root / "claude-lagging.jsonl"
        rows = [
            {"type": "user", "promptSource": "sdk", "message": {"content": "genuine-user-correction"}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "partial-unverified"}], "stop_reason": None}},
        ]
        path.write_text("\n".join(json.dumps(row) for row in rows))
        payload = {
            "cwd": str(self.repo), "session_id": "lagging", "transcript_path": str(path),
            "hook_event_name": "StopFailure", "last_assistant_message": "verified-final",
        }
        failed = self.command("hook", payload, "--harness", "claude", "stop")
        self.assertEqual(failed.returncode, 0, failed.stderr)
        self.assertEqual(Backend.state["requests"], [])
        rows[-1]["message"]["stop_reason"] = "end_turn"
        path.write_text("\n".join(json.dumps(row) for row in rows))
        payload["hook_event_name"] = "Stop"
        completed = self.command("hook", payload, "--harness", "claude", "stop")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        content = Backend.state["document"]["original_text"]
        self.assertIn("genuine-user-correction", content)
        self.assertIn("verified-final", content)
        self.assertNotIn("partial-unverified", content)

    def test_codex_uses_actual_user_events_not_synthetic_messages(self):
        result = self.transcript("codex", [
            {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-1"}},
            {"type": "event_msg", "payload": {"type": "user_message", "message": "genuine-user-correction"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "synthetic-compaction"}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "verified-answer"}]}},
            {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "turn-1", "last_agent_message": "verified-answer", "error": None}},
        ])
        self.assertIn("genuine-user-correction", result)
        self.assertNotIn("synthetic-compaction", result)

    def test_codex_failed_terminal_event_invalidates_partial_answer(self):
        result = self.transcript("codex", [
            {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "failed-turn"}},
            {"type": "event_msg", "payload": {"type": "user_message", "message": "genuine-user-correction"}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "partial-unverified"}]}},
            {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "failed-turn", "last_agent_message": None, "error": {"message": "provider failed"}}},
        ])
        self.assertIsNone(result)

    def test_codex_stop_uses_current_turn_before_task_complete_is_recorded(self):
        path = self.root / "codex-stop.jsonl"
        path.write_text("\n".join(json.dumps(row) for row in [
            {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "current"}},
            {"type": "event_msg", "payload": {"type": "user_message", "message": "genuine-user-correction"}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "partial-commentary"}]}},
        ]))
        payload = {
            "cwd": str(self.repo), "session_id": "codex-stop", "transcript_path": str(path),
            "hook_event_name": "Stop", "turn_id": "wrong-turn", "last_assistant_message": "verified-final",
        }
        unrelated = self.command("hook", payload, "--harness", "codex", "stop")
        self.assertEqual(unrelated.returncode, 0, unrelated.stderr)
        self.assertEqual(Backend.state["requests"], [])
        payload["turn_id"] = "current"
        completed = self.command("hook", payload, "--harness", "codex", "stop")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        content = Backend.state["document"]["original_text"]
        self.assertIn("genuine-user-correction", content)
        self.assertIn("verified-final", content)
        self.assertNotIn("partial-commentary", content)


if __name__ == "__main__":
    unittest.main()
