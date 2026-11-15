"""Exercise admission through the real supervisor without allocating the declared memory."""

import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(sys.argv.pop(1)).resolve()
MIB = 1024 ** 2
GIB = 1024 ** 3
DAY = 24 * 60 * 60
KEY = "verify\n/repository\nmake verify"
MEMORY_PERCENT = 40
# Files whose staged content the specification says identifies the toolchain, dependencies and verification entry.
DECLARED = ("flake.nix", "devenv.nix", "devenv.yaml", "package.json", "pnpm-lock.yaml", "package-lock.json",
            "Cargo.toml", "rust-toolchain", "rust-toolchain.toml", "global.json", "Directory.Build.props",
            "Directory.Packages.props", "nx.json", "tiergate.json", "justfile", "Makefile")
# A command that lives long enough for the first measurement and ends by itself.
QUICK = [sys.executable, "-c", "import time; time.sleep(0.3)"]
# The first measurement can precede the interpreter's start-up, so a peak that must exceed a small reservation is
# only guaranteed once the second measurement, about a second later, has seen the started interpreter.
MEASURED = [sys.executable, "-c", "import time; time.sleep(1.4)"]


def exits_with(status):
    """A command that ends by itself with the given status."""
    return [sys.executable, "-c", f"import time; time.sleep(0.3); raise SystemExit({status})"]


def percent_of(percent, value):
    """The specification's percentage of a limit, rounded up."""
    return -(-percent * value // 100)


class ResourceAdmission(unittest.TestCase):
    """Concurrent callers sharing one machine policy and isolated temporary state."""

    def setUp(self):
        """Create a policy, a deterministic resource-observation adapter and a repository for each case."""
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
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
            "memoryPercent": MEMORY_PERCENT,
            "cpuCount": 2,
            "maximumObservationAgeSeconds": 60,
        }))
        self.repo = self.root / "repo"
        (self.repo / "sub").mkdir(parents=True)
        (self.root / "outside").mkdir()
        self.git("init", "-q")
        (self.repo / "Cargo.toml").write_text("[package]\n")
        (self.repo / "flake.lock").write_text("{}\n")
        (self.repo / "README.md").write_text("undeclared\n")
        self.git("add", "-A")
        self.declared = self.declared_fingerprint()

    def environment(self):
        """The environment of every launched process: a private state directory and a git that ignores the host."""
        return {**os.environ, "XDG_STATE_HOME": str(self.state), "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CEILING_DIRECTORIES": str(self.root)}

    def git(self, *arguments):
        """Run git in the fixture repository."""
        subprocess.run(["git", *arguments], cwd=self.repo, env=self.environment(), check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def declared_fingerprint(self):
        """The sha256 of the staged declaration files listed by `git ls-files -s` at the repository root."""
        listing = subprocess.run(
            ["git", "ls-files", "-s", "--", ":(top,glob)*.lock", *DECLARED], cwd=self.repo, env=self.environment(),
            check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        return hashlib.sha256(listing).hexdigest()

    def stop_owned(self):
        """Cancel only supervisors launched by this test and wait for their descendants."""
        for process in self.children:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
        for process in self.children:
            process.communicate(timeout=10)

    def start(self, name, seconds=5, command=None, arguments=(), cwd=None):
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
            *arguments,
            "--", *worker,
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.environment(), cwd=cwd)
        self.children.append(process)
        return process, marker, release

    def run_command(self, name, command=QUICK, key=KEY, arguments=(), cwd=None):
        """Run a command that ends by itself and return its status, its stderr and its result record."""
        keyed = ["--resource-key", key] if key is not None else []
        process, _, _ = self.start(name, command=command, arguments=[*keyed, *arguments], cwd=cwd or self.repo)
        _, error = process.communicate(timeout=10)
        return process.returncode, error, json.loads((self.root / (name + ".result")).read_text())

    def wait_for(self, predicate, process):
        """Wait a bounded interval for an observable transition or fail on early exit."""
        until = time.monotonic() + 4
        while not predicate():
            if process.poll() is not None:
                self.fail(f"supervisor exited {process.returncode}: {process.communicate()[1]}")
            if time.monotonic() >= until:
                self.fail("transition did not occur")
            time.sleep(0.01)

    def limit(self, *limits):
        """Observe cgroup memory limits with ample headroom, so that only the demand is under test."""
        envelope = json.loads(self.snapshot.read_text())
        envelope["resources"][0]["value"]["memoryLimits"] = [
            {"path": f"/fixture-{index}.slice", "headroomBytes": 10 * GIB, "limitBytes": limit,
             "currentBytes": 0, "workingSetBytes": 0}
            for index, limit in enumerate(limits)]
        self.snapshot.write_text(json.dumps(envelope))

    def demand_file(self, key=KEY):
        """The record file the specification assigns to a key."""
        digest = hashlib.sha256(key.encode()).hexdigest()
        return self.state / "dotfiles-wsl" / "workload" / "demand" / f"{digest}.json"

    def seed(self, rows, key=KEY):
        """Write records as an earlier run would have left them, newest first."""
        path = self.demand_file(key)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_text(json.dumps({"version": 1, "records": rows}))

    def row(self, peak, age=0, fingerprint=None):
        """A record of the given peak made `age` seconds ago."""
        return {"at": int(time.time() - age), "peakBytes": peak, "reservedBytes": GIB,
                "fingerprint": self.declared if fingerprint is None else fingerprint, "exceeded": False}

    def stored(self, key=KEY):
        """The records kept for a key, newest first."""
        path = self.demand_file(key)
        return json.loads(path.read_text())["records"] if path.exists() else []

    def test_competing_projects_reserve_future_growth_before_start(self):
        """Two requests of 40% of the sixteen-GiB machine cannot both enter ten GiB of observed headroom."""
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

    def test_run_without_a_key_reserves_a_percent_of_the_machine_and_keeps_no_record(self):
        """Without a limit the default is the policy percentage of the physical total, and nothing is recorded."""
        status, _, result = self.run_command("unkeyed", key=None)
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], percent_of(MEMORY_PERCENT, 16 * GIB))
        self.assertFalse((self.state / "dotfiles-wsl").exists())

    def test_first_run_of_a_key_reserves_a_percent_of_the_tightest_limit_and_leaves_one_record(self):
        """An unrecorded key falls back to the percentage of the smallest limitBytes and then records its peak."""
        self.limit(8 * GIB, 4 * GIB)
        self.assertEqual(self.stored(), [])
        status, error, result = self.run_command("first-of-key")
        self.assertEqual(status, 0)
        reserved = percent_of(MEMORY_PERCENT, 4 * GIB)
        self.assertEqual(result["memoryReservedBytes"], reserved)
        self.assertNotIn("exceeded the reservation", error)
        records = self.stored()
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["reservedBytes"], reserved)
        self.assertEqual(records[0]["fingerprint"], self.declared)
        self.assertEqual(records[0]["peakBytes"], result["memoryPeakBytes"])
        self.assertGreater(records[0]["peakBytes"], 0)
        self.assertIs(records[0]["exceeded"], False)
        self.assertGreater(records[0]["at"], time.time() - 60)
        self.assertEqual(self.demand_file().parent.stat().st_mode & 0o777, 0o700)

    def test_recorded_peaks_set_the_demand_from_the_newest_five_with_a_margin(self):
        """The largest of the five newest peaks plus 20% is reserved; the older sixth peak is ignored."""
        peaks = [100_000_000, 300_000_000, 250_000_000, 200_000_000, 50_000_000]
        rows = [self.row(peak, age=index * 3600) for index, peak in enumerate(peaks)]
        rows.append(self.row(5_000_000_000, age=6 * 3600))
        self.seed(rows)
        status, _, result = self.run_command("recorded")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 360_000_000)
        self.assertEqual(len(self.stored()), 7)

    def test_a_peak_that_is_not_a_multiple_of_five_is_rounded_up(self):
        """The margin is rounded up to a whole byte."""
        self.seed([self.row(1_000_000_001)])
        _, _, result = self.run_command("rounded")
        self.assertEqual(result["memoryReservedBytes"], -(-1_000_000_001 * 6 // 5))

    def test_the_ten_newest_records_are_kept(self):
        """A key keeps the ten newest records."""
        self.seed([self.row(100_000_000 + index, age=(index + 1) * 60) for index in range(10)])
        self.run_command("rotated")
        records = self.stored()
        self.assertEqual(len(records), 10)
        self.assertEqual(records[0]["at"], max(record["at"] for record in records))
        self.assertNotIn(100_000_009, [record["peakBytes"] for record in records])

    def test_records_of_another_fingerprint_or_older_than_thirty_days_are_not_used(self):
        """A changed declaration or an old measurement returns the run to the default reservation."""
        default = percent_of(MEMORY_PERCENT, 16 * GIB)
        self.seed([self.row(2_000_000_000, age=31 * DAY)])
        _, _, result = self.run_command("old")
        self.assertEqual(result["memoryReservedBytes"], default)

        self.seed([self.row(2_000_000_000)])
        (self.repo / "Cargo.toml").write_text("[package]\nname = \"changed\"\n")
        self.git("add", "Cargo.toml")
        self.assertNotEqual(self.declared_fingerprint(), self.declared)
        _, _, result = self.run_command("changed")
        self.assertEqual(result["memoryReservedBytes"], default)

        self.declared = self.declared_fingerprint()
        self.seed([self.row(100_000_000, age=29 * DAY), self.row(2_000_000_000, age=31 * DAY),
                   self.row(3_000_000_000, fingerprint="0" * 64)])
        _, _, result = self.run_command("boundary")
        self.assertEqual(result["memoryReservedBytes"], 120_000_000)

    def test_recorded_demand_is_truncated_to_the_tightest_limit(self):
        """A recorded demand above the smallest limitBytes is cut to it instead of failing or waiting."""
        self.limit(4 * GIB, 2 * GIB)
        self.seed([self.row(3_000_000_000)])
        status, _, result = self.run_command("truncated")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 2 * GIB)
        self.assertEqual(self.stored()[0]["reservedBytes"], 2 * GIB)

    def test_explicit_demand_above_the_tightest_limit_fails_without_waiting_or_starting(self):
        """An explicit demand is never cut: above the smallest limitBytes it fails at once and nothing is started."""
        self.limit(4 * GIB, 2 * GIB)
        process, started, _ = self.start("explicit-over", seconds=5,
                                         arguments=["--resource-memory", str(3 * GIB)], cwd=self.repo)
        _, error = process.communicate(timeout=3)
        self.assertEqual(process.returncode, 70)
        self.assertIn("exceeds the tightest limit", error)
        self.assertFalse(started.exists())
        self.assertEqual(list((self.root / "leases").glob("*.json")), [])
        status, _, result = self.run_command("explicit-at", key=None, arguments=["--resource-memory", str(2 * GIB)])
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 2 * GIB)

    def test_nested_recorded_demand_is_cut_to_the_ancestor_and_explicit_demand_is_not(self):
        """Inside a reservation, a recorded or default demand never errors, while an explicit one is checked."""
        self.seed([self.row(3_000_000_000)])

        def nested(name, key, *arguments):
            inner = [sys.executable, str(SOURCE), "--resource-policy", str(self.policy),
                     "--resource-deadline", str(time.time() + 3),
                     "--result", str(self.root / (name + ".inner")),
                     "--resource-key", key, *arguments, "--", *QUICK]
            process, _, _ = self.start(name, command=inner, arguments=["--resource-memory", str(GIB)], cwd=self.repo)
            _, error = process.communicate(timeout=10)
            return process.returncode, error, self.root / (name + ".inner")

        status, _, inner = nested("nested-recorded", KEY)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(inner.read_text())["memoryReservedBytes"], GIB)
        status, _, inner = nested("nested-default", "a key without records")
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(inner.read_text())["memoryReservedBytes"], GIB)
        status, error, _ = nested("nested-explicit", KEY, "--resource-memory", str(2 * GIB))
        self.assertEqual(status, 70)
        self.assertIn("nested request exceeds its ancestor reservation", error)

    def test_runs_that_fail_are_cut_short_or_cancelled_leave_no_record(self):
        """Only a run that ends by itself with status 0 is recorded; failures, 124, 128 or more, cancellation and the deadline are not."""
        status, _, _ = self.run_command("control", command=exits_with(0))
        self.assertEqual(status, 0)
        self.assertEqual(len(self.stored()), 1)
        # A failure stops inside the entry with a peak below the demand, and recording it lowers the next reservation.
        for status in (1, 3, 124, 130):
            with self.subTest(status=status):
                self.assertEqual(self.run_command(f"status-{status}", command=exits_with(status))[0], status)
                self.assertEqual(len(self.stored()), 1)
        keyed = ["--resource-key", KEY]
        cancelled, started, _ = self.start("cancelled-run", arguments=keyed, cwd=self.repo)
        self.wait_for(started.exists, cancelled)
        cancelled.send_signal(signal.SIGTERM)
        cancelled.communicate(timeout=5)
        self.assertEqual(cancelled.returncode, 143)
        expiring, started, _ = self.start("expired-run", seconds=0.6, arguments=keyed, cwd=self.repo)
        self.wait_for(started.exists, expiring)
        expiring.communicate(timeout=5)
        self.assertEqual(expiring.returncode, 124)
        self.assertEqual(len(self.stored()), 1)

    def test_a_failed_run_whose_peak_exceeded_the_reservation_is_recorded(self):
        """A peak above the reservation is a lower bound of the demand even when the run fails, so it is kept."""
        self.limit(MIB)
        failing = [sys.executable, "-c", "import time; time.sleep(1.4); raise SystemExit(1)"]
        status, error, _ = self.run_command("exceeding-failure", command=failing)
        self.assertEqual(status, 1)
        self.assertIn("exceeded the reservation", error)
        records = self.stored()
        self.assertEqual(len(records), 1)
        self.assertIs(records[0]["exceeded"], True)
        self.assertGreater(records[0]["peakBytes"], records[0]["reservedBytes"])

    def test_peak_above_the_reservation_is_reported_once_and_recorded(self):
        """A measured peak above the settled demand prints one line and sets exceeded in the record."""
        self.limit(MIB)
        status, error, result = self.run_command("exceeding", command=MEASURED)
        self.assertEqual(status, 0)
        reserved = percent_of(MEMORY_PERCENT, MIB)
        lines = [line for line in error.splitlines() if "exceeded the reservation" in line]
        self.assertEqual(len(lines), 1)
        match = re.fullmatch(r"dotfiles-supervise: measured memory peak (\d+) bytes exceeded the reservation (\d+) bytes", lines[0])
        if match is None:
            self.fail(f"unexpected line: {lines[0]}")
        peak = int(match.group(1))
        self.assertEqual(int(match.group(2)), reserved)
        self.assertGreater(peak, reserved)
        self.assertEqual(result["memoryPeakBytes"], peak)
        self.assertEqual(result["memoryReservedBytes"], reserved)
        records = self.stored()
        self.assertEqual(len(records), 1)
        self.assertEqual((records[0]["peakBytes"], records[0]["reservedBytes"], records[0]["exceeded"]),
                         (peak, reserved, True))

    def test_fingerprint_follows_the_declared_files_of_the_repository_root(self):
        """The fingerprint is taken at the repository root and ignores undeclared files."""
        def recorded(name, cwd):
            self.run_command(name, cwd=cwd)
            return self.stored()[0]["fingerprint"]

        self.assertEqual(recorded("at-root", self.repo), self.declared)
        self.assertEqual(recorded("below-root", self.repo / "sub"), self.declared)
        (self.repo / "README.md").write_text("still undeclared\n")
        self.git("add", "README.md")
        self.assertEqual(recorded("undeclared-change", self.repo), self.declared)
        (self.repo / "Cargo.toml").write_text("[package]\nname = \"changed\"\n")
        self.git("add", "Cargo.toml")
        changed = recorded("declared-change", self.repo)
        self.assertNotEqual(changed, self.declared)
        self.assertEqual(changed, self.declared_fingerprint())
        self.assertEqual(recorded("outside-a-repository", self.root / "outside"), "")

    def test_unreadable_record_falls_back_to_the_default_and_keeps_the_exit_status(self):
        """A broken record file costs one stderr line and the default reservation, not the command's status."""
        default = percent_of(MEMORY_PERCENT, 16 * GIB)
        for content in ("{not json", '{"version":2,"records":[]}', "[]"):
            with self.subTest(content=content):
                path = self.demand_file()
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                path.write_text(content)
                status, error, result = self.run_command("unreadable", command=exits_with(0))
                self.assertEqual(status, 0)
                self.assertEqual(result["memoryReservedBytes"], default)
                self.assertEqual(len([line for line in error.splitlines()
                                      if line.startswith("dotfiles-supervise: cannot read the measured memory demand")]), 1)
                self.assertEqual(len(self.stored()), 1)

    def test_unwritable_state_costs_stderr_lines_and_not_the_exit_status(self):
        """A state directory that cannot be read or created leaves the run on the default reservation."""
        blocker = self.root / "blocker"
        blocker.write_text("")
        self.state = blocker / "state"
        status, error, result = self.run_command("unwritable", command=exits_with(0))
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], percent_of(MEMORY_PERCENT, 16 * GIB))
        self.assertEqual(len([line for line in error.splitlines() if "cannot read the measured memory demand" in line]), 1)
        self.assertEqual(len([line for line in error.splitlines() if "cannot record the measured memory peak" in line]), 1)


if __name__ == "__main__":
    unittest.main()
