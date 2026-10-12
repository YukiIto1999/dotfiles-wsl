import json
import os
from contextlib import suppress
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SCANNER_WRAPPER = sys.argv.pop(1)


class ScanEvidence(unittest.TestCase):
    """Consumer-visible evidence and process-lifetime regressions"""

    def setUp(self):
        """Isolated project with an observable native-process fixture

        Args:
            self: Current regression fixture
        Returns:
            None
        """
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        base = Path(self.directory.name)
        self.root = base / "project"
        self.root.mkdir()
        (self.root / "sonar-project.properties").write_text("sonar.sources=.\n")
        (self.root / "source.py").write_text("answer = 42\n")
        for arguments in [
            ["init", "-q"],
            ["add", "."],
            ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"],
        ]:
            subprocess.run(["git", "-C", str(self.root), *arguments], check=True)
        self.token = base / "token"
        self.token.write_text("fixture-token-not-a-credential")
        self.upstream = base / "scanner"
        self.upstream.write_text(
            "#!" + sys.executable + "\n"
            "import os, pathlib, signal, sys\n"
            "print(os.environ['SONAR_TOKEN'], flush=True)\n"
            "if os.environ.get('CHANGE_SOURCE'):\n"
            "    pathlib.Path('source.py').write_text('answer = 43\\n')\n"
            "report = next(value.split('=', 1)[1] for value in sys.argv if value.startswith('-Dsonar.scanner.metadataFilePath='))\n"
            "pathlib.Path(report).write_text('ceTaskId=fixture-task\\nprojectKey=fixture\\n')\n"
            "if os.environ.get('UNREADABLE_SOURCE'):\n"
            "    pathlib.Path('source.py').chmod(0)\n"
            "if os.environ.get('WAIT_FOR_CANCEL'):\n"
            "    if os.environ.get('IGNORE_TERM'):\n"
            "        signal.signal(signal.SIGTERM, lambda *_: pathlib.Path(os.environ['CANCEL_FIFO']).write_text('seen'))\n"
            "    print('READY ' + str(os.getpid()), flush=True)\n"
            "    while True:\n"
            "        signal.pause()\n"
            "if os.environ.get('SCANNER_SIGNAL'):\n"
            "    os.kill(os.getpid(), int(os.environ['SCANNER_SIGNAL']))\n"
            "sys.exit(int(os.environ.get('SCANNER_EXIT', '0')))\n"
        )
        self.upstream.chmod(0o700)
        self.environment = {**os.environ, "XDG_STATE_HOME": str(base / "state")}

    def scan_argv(self, token=None):
        """Public wrapper arguments for a fixture-owned project

        Args:
            self: Current regression fixture
            token: Credential path override or default fixture token
        Returns:
            CLI argument list without credential values
        """
        return [
            sys.executable, SCANNER_WRAPPER, "--scanner", str(self.upstream),
            "--scanner-package-version", "fixture", "--server-url", "http://127.0.0.1:9000",
            "--cwd", str(self.root), "--project-key", "fixture",
            "--token-file", str(token or self.token),
        ]

    def scan(self, token=None, **environment):
        """Completed public CLI observation with native behavior selection

        Args:
            self: Current regression fixture
            token: Credential path override or default fixture token
            environment: Native fixture behavior overrides
        Returns:
            Captured CLI result
        """
        return subprocess.run(
            self.scan_argv(token),
            env={**self.environment, **environment}, capture_output=True, text=True,
        )

    def wait_native_ready(self, process):
        """Owned native PID after public readiness evidence

        Args:
            self: Current regression fixture
            process: Running public wrapper process with captured stderr
        Returns:
            Native process-group leader PID
        Raises:
            AssertionError: Missing readiness within the bounded wait
        """
        output = b""
        deadline = time.monotonic() + 5
        with selectors.DefaultSelector() as selector:
            selector.register(process.stderr, selectors.EVENT_READ)
            while True:
                for line in output.splitlines():
                    if line.startswith(b"READY "):
                        return int(line.split()[1])
                self.assertTrue(selector.select(max(0, deadline - time.monotonic())), "native fixture did not become ready")
                chunk = os.read(process.stderr.fileno(), 4096)
                self.assertTrue(chunk, "wrapper ended before native fixture became ready")
                output += chunk

    def test_failed_scan_retains_failure_without_printing_token(self):
        """Failed native execution with private token-free evidence

        Args:
            self: Current regression fixture
        Returns:
            None
        """
        result = self.scan(SCANNER_EXIT="23")
        self.assertEqual(result.returncode, 23)
        self.assertNotIn(self.token.read_text(), result.stdout + result.stderr)
        receipt = Path(json.loads(result.stdout)["receipt"])
        evidence = json.loads(receipt.read_text())
        self.assertEqual(evidence["scanner_exit_code"], 23)
        self.assertEqual(evidence["current_applicability"], "unassessed")
        self.assertNotIn(self.token.read_text(), receipt.read_text())
        self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)

    def test_native_signal_is_a_failed_exit_and_is_recorded(self):
        """Native signal failure distinct from current applicability

        Args:
            self: Current regression fixture
        Returns:
            None
        """
        result = self.scan(SCANNER_SIGNAL=str(signal.SIGTERM))
        self.assertEqual(result.returncode, 128 + signal.SIGTERM)
        evidence = json.loads(Path(json.loads(result.stdout)["receipt"]).read_text())
        self.assertEqual(evidence["scanner_exit_code"], result.returncode)
        self.assertEqual(evidence["scanner_return_code"], -signal.SIGTERM)
        self.assertEqual(evidence["current_applicability"], "unassessed")

    def test_wrapper_cancellation_preserves_started_scan_receipt(self):
        """Wrapper cancellation with retained task evidence after native collection

        Args:
            self: Current regression fixture
        Returns:
            None
        """
        process = subprocess.Popen(
            self.scan_argv(), env={**self.environment, "WAIT_FOR_CANCEL": "1"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        native_pid = None
        try:
            native_pid = self.wait_native_ready(process)
            process.send_signal(signal.SIGTERM)
            stdout, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM)
            evidence = json.loads(Path(json.loads(stdout)["receipt"]).read_text())
            self.assertEqual(evidence["wrapper_cancel_signal"], signal.SIGTERM)
            self.assertEqual(evidence["scanner_return_code"], -signal.SIGTERM)
            self.assertEqual(evidence["report_task"]["ceTaskId"], "fixture-task")
            self.assertFalse(Path(f"/proc/{native_pid}").exists())
        finally:
            if native_pid is not None:
                with suppress(ProcessLookupError):
                    os.killpg(native_pid, signal.SIGKILL)
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    def test_repeated_wrapper_cancellation_reaps_unresponsive_native_process(self):
        """Repeated cancellation without an orphaned unresponsive native process

        Args:
            self: Current regression fixture
        Returns:
            None
        """
        fifo = Path(self.directory.name) / "cancel-seen"
        os.mkfifo(fifo, 0o600)
        descriptor = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        process = subprocess.Popen(
            self.scan_argv(),
            env={**self.environment, "WAIT_FOR_CANCEL": "1", "IGNORE_TERM": "1", "CANCEL_FIFO": str(fifo)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        native_pid = None
        try:
            native_pid = self.wait_native_ready(process)
            process.send_signal(signal.SIGTERM)
            with selectors.DefaultSelector() as selector:
                selector.register(descriptor, selectors.EVENT_READ)
                self.assertTrue(selector.select(5), "native fixture did not receive cleanup TERM")
                os.read(descriptor, 4096)
            process.send_signal(signal.SIGTERM)
            stdout, _ = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM)
            self.assertFalse(Path(f"/proc/{native_pid}").exists(), "native process outlived the wrapper")
            evidence = json.loads(Path(json.loads(stdout)["receipt"]).read_text())
            self.assertEqual(evidence["wrapper_cancel_signal"], signal.SIGTERM)
            self.assertEqual(evidence["scanner_return_code"], -signal.SIGKILL)
            self.assertEqual(evidence["report_task"]["ceTaskId"], "fixture-task")
        finally:
            if native_pid is not None:
                with suppress(ProcessLookupError):
                    os.killpg(native_pid, signal.SIGKILL)
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
            os.close(descriptor)

    def test_unreadable_post_scan_input_preserves_native_failure_and_task(self):
        """Unknown post-scan input without native failure or task evidence loss

        Args:
            self: Current regression fixture
        Returns:
            None
        """
        result = self.scan(UNREADABLE_SOURCE="1", SCANNER_EXIT="23")
        self.assertEqual(result.returncode, 23)
        evidence = json.loads(Path(json.loads(result.stdout)["receipt"]).read_text())
        self.assertEqual(evidence["scanner_return_code"], 23)
        self.assertEqual(evidence["report_task"]["ceTaskId"], "fixture-task")
        self.assertIsNotNone(evidence["input_before"]["fingerprint"])
        self.assertIsNone(evidence["input_after"]["fingerprint"])
        self.assertEqual(evidence["input_after"]["observation_error"], "PermissionError")
        self.assertIsNone(evidence["input_unchanged_at_observations"])

    def test_same_revision_does_not_hide_source_changes_during_scan(self):
        """Changed scan input despite unchanged repository revision

        Args:
            self: Current regression fixture
        Returns:
            None
        """
        result = self.scan(CHANGE_SOURCE="1")
        self.assertEqual(result.returncode, 0)
        evidence = json.loads(Path(json.loads(result.stdout)["receipt"]).read_text())
        self.assertEqual(evidence["input_before"]["git_revision"], evidence["input_after"]["git_revision"])
        self.assertNotEqual(evidence["input_before"]["fingerprint"], evidence["input_after"]["fingerprint"])
        self.assertFalse(evidence["input_unchanged_at_observations"])
        self.assertEqual(evidence["current_applicability"], "unassessed")

    def test_credential_inside_analyzed_source_is_rejected(self):
        """Source-contained credential rejection before native execution

        Args:
            self: Current regression fixture
        Returns:
            None
        """
        token = self.root / "analysis-token"
        token.write_text(self.token.read_text())
        result = self.scan(token=token)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(token.read_text(), result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
