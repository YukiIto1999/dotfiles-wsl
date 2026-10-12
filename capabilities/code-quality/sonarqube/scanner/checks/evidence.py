import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

SCANNER_WRAPPER = sys.argv.pop(1)


class ScanEvidence(unittest.TestCase):
    def setUp(self):
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
            "if os.environ.get('SCANNER_SIGNAL'):\n"
            "    os.kill(os.getpid(), int(os.environ['SCANNER_SIGNAL']))\n"
            "sys.exit(int(os.environ.get('SCANNER_EXIT', '0')))\n"
        )
        self.upstream.chmod(0o700)
        self.environment = {**os.environ, "XDG_STATE_HOME": str(base / "state")}

    def scan(self, token=None, **environment):
        return subprocess.run(
            [sys.executable, SCANNER_WRAPPER, "--scanner", str(self.upstream),
             "--scanner-package-version", "fixture", "--server-url", "http://127.0.0.1:9000",
             "--cwd", str(self.root), "--project-key", "fixture", "--token-file", str(token or self.token)],
            env={**self.environment, **environment}, capture_output=True, text=True,
        )

    def test_failed_scan_retains_failure_without_printing_token(self):
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
        result = self.scan(SCANNER_SIGNAL=str(signal.SIGTERM))
        self.assertEqual(result.returncode, 128 + signal.SIGTERM)
        evidence = json.loads(Path(json.loads(result.stdout)["receipt"]).read_text())
        self.assertEqual(evidence["scanner_exit_code"], result.returncode)
        self.assertEqual(evidence["scanner_return_code"], -signal.SIGTERM)
        self.assertEqual(evidence["current_applicability"], "unassessed")

    def test_same_revision_does_not_hide_source_changes_during_scan(self):
        result = self.scan(CHANGE_SOURCE="1")
        self.assertEqual(result.returncode, 0)
        evidence = json.loads(Path(json.loads(result.stdout)["receipt"]).read_text())
        self.assertEqual(evidence["input_before"]["git_revision"], evidence["input_after"]["git_revision"])
        self.assertNotEqual(evidence["input_before"]["fingerprint"], evidence["input_after"]["fingerprint"])
        self.assertFalse(evidence["input_unchanged_at_observations"])
        self.assertEqual(evidence["current_applicability"], "unassessed")

    def test_credential_inside_analyzed_source_is_rejected(self):
        token = self.root / "analysis-token"
        token.write_text(self.token.read_text())
        result = self.scan(token=token)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(token.read_text(), result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
