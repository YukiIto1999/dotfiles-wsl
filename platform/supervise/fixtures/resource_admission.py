"""Exercise admission through the real supervisor without allocating the declared memory."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(sys.argv.pop(1)).resolve()
GIB = 1024 ** 3


class ResourceAdmission(unittest.TestCase):
    """Concurrent callers sharing one machine policy and isolated temporary state."""

    def setUp(self):
        """Create a policy and a deterministic resource-observation adapter for each case."""
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.children = []
        self.addCleanup(self.stop_owned)
        self.snapshot = self.root / "snapshot.json"
        self.snapshot.write_text(json.dumps({
            "schemaVersion": 1,
            "outcomes": [{"id": "resource/test", "status": "pass", "message": "fixture"}],
            "resources": [{"key": "workload", "value": {
                "observedAt": time.time(),
                "memoryTotalBytes": 16 * GIB,
                "memoryAvailableBytes": 10 * GIB,
                "hostMemoryHeadroomBytes": 10 * GIB,
                "memoryHeadroomBytes": 10 * GIB,
                "memoryLimits": [],
                "cpuCount": 4,
                "windowsCommitHeadroomBytes": 20 * GIB,
                "windowsPhysicalAvailableBytes": 10 * GIB,
                "windowsPhysicalHeadroomBytes": 2 * GIB,
            }}],
        }))
        self.policy = self.root / "policy.json"
        self.policy.write_text(json.dumps({
            "observation": [sys.executable, "-c", "import pathlib,sys;print(pathlib.Path(sys.argv[1]).read_text())", str(self.snapshot)],
            "runtimeDirectory": str(self.root / "leases"),
            "memoryBytes": 6 * GIB,
            "cpuCount": 2,
            "maximumObservationAgeSeconds": 60,
        }))

    def stop_owned(self):
        """Cancel only supervisors launched by this test and wait for their descendants."""
        for process in self.children:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
        for process in self.children:
            process.communicate(timeout=10)

    def start(self, name, seconds=5, command=None):
        """Start a declared workload with a separate public result and finite deadline."""
        marker = self.root / name
        release = self.root / (name + ".release")
        worker = command or [sys.executable, "-c",
            "import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();"
            "\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.01)",
            str(marker), str(release)]
        process = subprocess.Popen([
            sys.executable, str(SOURCE), "--require-drained", "--interrupt-cancels",
            "--result", str(self.root / (name + ".result")),
            "--resource-policy", str(self.policy),
            "--resource-deadline", str(time.time() + seconds),
            "--", *worker,
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(process)
        return process, marker, release

    def wait_for(self, predicate, process):
        """Wait a bounded interval for an observable transition or fail on early exit."""
        until = time.monotonic() + 4
        while not predicate():
            if process.poll() is not None:
                self.fail(f"supervisor exited {process.returncode}: {process.communicate()[1]}")
            if time.monotonic() >= until:
                self.fail("transition did not occur")
            time.sleep(0.01)

    def test_competing_projects_reserve_future_growth_before_start(self):
        """Two six-GiB requests cannot both enter ten GiB of observed headroom."""
        first, started, release = self.start("first")
        self.wait_for(started.exists, first)
        second, second_started, second_release = self.start("second")
        result = self.root / "second.result"
        self.wait_for(lambda: result.exists() and json.loads(result.read_text()).get("phase") == "waiting", second)
        self.assertFalse(second_started.exists())
        release.touch()
        first.communicate(timeout=5)
        self.assertEqual(first.returncode, 0)
        self.wait_for(second_started.exists, second)
        second_release.touch()
        second.communicate(timeout=5)
        self.assertEqual(second.returncode, 0)

    def test_pressure_defers_without_starting_and_keeps_deadline(self):
        """Pressure causes a bounded unstarted result rather than an execution failure."""
        envelope = json.loads(self.snapshot.read_text())
        envelope["outcomes"][0]["status"] = "warn"
        self.snapshot.write_text(json.dumps(envelope))
        process, started, _ = self.start("deferred", seconds=0.3)
        process.communicate(timeout=3)
        self.assertEqual(process.returncode, 124)
        self.assertFalse(started.exists())
        result = json.loads((self.root / "deferred.result").read_text())
        self.assertTrue(result["deferred"])
        self.assertFalse(result["spawned"])
        self.assertEqual(list((self.root / "leases").glob("*.json")), [])

    def test_nested_execution_reuses_ancestor_reservation(self):
        """Nested calls fit inside their outer reservation instead of waiting for themselves."""
        child = [sys.executable, str(SOURCE), "--resource-policy", str(self.policy),
                 "--resource-deadline", str(time.time() + 3), "--", sys.executable, "-c", "raise SystemExit(23)"]
        process, _, _ = self.start("nested", command=child)
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 23)
        self.assertEqual(list((self.root / "leases").glob("*.json")), [])

    def test_cancelled_waiter_does_not_cancel_admitted_work(self):
        """Cancelling a queued caller leaves the admitted caller and its reservation intact."""
        first, started, release = self.start("active")
        self.wait_for(started.exists, first)
        waiting, waiting_started, _ = self.start("cancelled")
        result = self.root / "cancelled.result"
        self.wait_for(lambda: result.exists() and json.loads(result.read_text()).get("phase") == "waiting", waiting)
        waiting.send_signal(signal.SIGTERM)
        waiting.communicate(timeout=3)
        self.assertEqual(waiting.returncode, 143)
        self.assertFalse(waiting_started.exists())
        self.assertIsNone(first.poll())
        release.touch()
        first.communicate(timeout=5)
        self.assertEqual(first.returncode, 0)

    def test_deadline_includes_wait_and_running_time(self):
        """An admitted command cannot restart its execution budget after admission."""
        process, started, _ = self.start("expiring", seconds=0.4)
        self.wait_for(started.exists, process)
        process.communicate(timeout=3)
        self.assertEqual(process.returncode, 124)
        result = json.loads((self.root / "expiring.result").read_text())
        self.assertTrue(result["spawned"])
        self.assertTrue(result["drained"])

    def test_stale_observation_never_authorizes_execution(self):
        """A stale successful envelope cannot admit a workload."""
        envelope = json.loads(self.snapshot.read_text())
        envelope["resources"][0]["value"]["observedAt"] = time.time() - 61
        self.snapshot.write_text(json.dumps(envelope))
        process, started, _ = self.start("stale", seconds=0.2)
        process.communicate(timeout=3)
        self.assertEqual(process.returncode, 124)
        self.assertFalse(started.exists())

    def test_forged_inherited_reservation_does_not_bypass_admission(self):
        """A copied environment reference without an ancestor owner cannot grant resources."""
        old = os.environ.get("DOTFILES_WORKLOAD_LEASE")
        os.environ["DOTFILES_WORKLOAD_LEASE"] = str(self.root / "unrelated.json")
        try:
            process, started, _ = self.start("forged")
        finally:
            if old is None:
                os.environ.pop("DOTFILES_WORKLOAD_LEASE")
            else:
                os.environ["DOTFILES_WORKLOAD_LEASE"] = old
        _, error = process.communicate(timeout=3)
        self.assertEqual(process.returncode, 70)
        self.assertIn("another policy", error)
        self.assertFalse(started.exists())


if __name__ == "__main__":
    unittest.main()
