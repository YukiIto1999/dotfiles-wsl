"""Exercise admission through the real supervisor without allocating the declared memory."""

import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
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
# How long a test waits for something that must happen before it calls the run hung.  It guards against a hang and decides
# nothing: what a test asserts about a run never depends on how fast the machine is.
HANG_SECONDS = 15
# A deadline that lets a run be judged before it runs out, even on a loaded machine, and the slack the deadline is allowed.
DEADLINE_SECONDS = 6
DEADLINE_SLACK = 1
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
        # Stands in for journald's native socket; the supervisors' datagrams are read back from it.
        self.journal = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(self.journal.close)
        self.journal.bind(str(self.root / "journal.sock"))
        self.journal.setblocking(False)
        self.policy = self.root / "policy.json"
        self.policy.write_text(json.dumps({
            "class": "acceptance",
            "journalSocket": str(self.root / "journal.sock"),
            "observation": [sys.executable, "-c", "import pathlib,sys;print(pathlib.Path(sys.argv[1]).read_text())", str(self.snapshot)],
            "runtimeDirectory": str(self.root / "leases"),
            "memoryPercent": MEMORY_PERCENT,
            "maximumObservationAgeSeconds": 60,
        }))
        # A directory to run in: the demand is keyed by the caller, not by what the working directory holds.
        self.repo = self.root / "repo"
        self.repo.mkdir()

    def environment(self):
        """The environment of every launched process: a private state directory."""
        return {**os.environ, "XDG_STATE_HOME": str(self.state)}

    def measurements(self):
        """The journal entries the supervisors have sent so far, oldest first, as (fields, message record) pairs."""
        entries = []
        while True:
            try:
                datagram = self.journal.recv(65536).decode()
            except BlockingIOError:
                return entries
            fields = dict(line.split("=", 1) for line in datagram.splitlines())
            entries.append((fields, json.loads(fields["MESSAGE"])))

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
        until = time.monotonic() + HANG_SECONDS
        while not predicate():
            if process.poll() is not None:
                self.fail(f"supervisor exited {process.returncode}: {process.communicate()[1]}")
            if time.monotonic() >= until:
                self.fail("transition did not occur")
            time.sleep(0.01)

    def waiting(self, name, process):
        """Wait until the named workload has told its result file that it waits for resources, and return the reason."""
        result = self.root / (name + ".result")
        self.wait_for(lambda: result.exists() and json.loads(result.read_text()).get("phase") == "waiting", process)
        return json.loads(result.read_text())["reason"]

    def limit(self, *limits):
        """Observe cgroup memory limits with ample headroom, so that only the demand is under test."""
        envelope = json.loads(self.snapshot.read_text())
        envelope["resources"][0]["value"]["memoryLimits"] = [
            {"path": f"/fixture-{index}.slice", "headroomBytes": 10 * GIB, "limitBytes": limit,
             "currentBytes": 0, "workingSetBytes": 0}
            for index, limit in enumerate(limits)]
        self.snapshot.write_text(json.dumps(envelope))

    def observe(self, **fields):
        """Replace fields of the observed workload resource."""
        envelope = json.loads(self.snapshot.read_text())
        envelope["resources"][0]["value"].update(fields)
        self.snapshot.write_text(json.dumps(envelope))

    def bounded(self, limit, headroom):
        """Observe one cgroup memory limit that leaves the given headroom."""
        self.observe(memoryLimits=[{"path": "/fixture-0.slice", "headroomBytes": headroom, "limitBytes": limit,
                                    "currentBytes": 0, "workingSetBytes": 0}])

    def deferred(self, name):
        """Start the keyed workload, cancel it once it says it waits, and return its stderr.

        The run is judged and found not to fit before it is cancelled, so no deadline is timed.
        """
        process, started, _ = self.start(name, seconds=2 * HANG_SECONDS, arguments=["--resource-key", KEY], cwd=self.repo)
        self.waiting(name, process)
        process.send_signal(signal.SIGTERM)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 143)
        self.assertFalse(started.exists())
        return error

    def demand_file(self, key=KEY):
        """The record file the specification assigns to a key."""
        digest = hashlib.sha256(key.encode()).hexdigest()
        return self.state / "dotfiles-wsl" / "workload" / "demand" / f"{digest}.json"

    def seed(self, rows, key=KEY):
        """Write records as an earlier run would have left them, newest first."""
        path = self.demand_file(key)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_text(json.dumps({"version": 1, "records": rows}))

    def row(self, peak, age=0):
        """A record of the given peak made `age` seconds ago."""
        return {"at": int(time.time() - age), "peakBytes": peak, "reservedBytes": GIB, "exceeded": False}

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
        self.assertEqual(records[0]["peakBytes"], result["memoryPeakBytes"])
        self.assertGreater(records[0]["peakBytes"], 0)
        self.assertIs(records[0]["exceeded"], False)
        self.assertGreater(records[0]["at"], time.time() - 60)
        self.assertEqual(self.demand_file().parent.stat().st_mode & 0o777, 0o700)

    def test_recorded_peaks_set_the_demand_from_the_newest_five(self):
        """The largest of the five newest peaks is reserved as it is; the older sixth peak is ignored."""
        peaks = [100_000_000, 300_000_000, 250_000_000, 200_000_000, 50_000_000]
        rows = [self.row(peak, age=index * 3600) for index, peak in enumerate(peaks)]
        rows.append(self.row(5_000_000_000, age=6 * 3600))
        self.seed(rows)
        status, _, result = self.run_command("recorded")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 300_000_000)
        self.assertEqual(len(self.stored()), 7)

    def test_a_recorded_peak_that_equals_the_cgroup_headroom_enters_and_one_byte_more_waits(self):
        """No margin is added to a peak, so a run whose peak fits the headroom alone is never shut out by a margin."""
        self.bounded(8 * GIB, 3 * GIB)
        self.seed([self.row(3 * GIB)])
        status, _, result = self.run_command("at-headroom")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 3 * GIB)
        self.seed([self.row(3 * GIB + 1)])
        error = self.deferred("over-headroom")
        self.assertIn("waiting for resources: memory headroom is reserved at /fixture-0.slice", error)

    def test_the_ten_newest_records_are_kept(self):
        """A key keeps the ten newest records."""
        self.seed([self.row(100_000_000 + index, age=(index + 1) * 60) for index in range(10)])
        self.run_command("rotated")
        records = self.stored()
        self.assertEqual(len(records), 10)
        self.assertEqual(records[0]["at"], max(record["at"] for record in records))
        self.assertNotIn(100_000_009, [record["peakBytes"] for record in records])

    def test_recorded_peaks_are_used_however_old_they_are(self):
        """No age limit: the five newest peaks set the demand even when they were measured months ago."""
        self.seed([self.row(100_000_000, age=100 * DAY), self.row(300_000_000, age=200 * DAY)])
        _, _, result = self.run_command("old")
        self.assertEqual(result["memoryReservedBytes"], 300_000_000)

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
        # A reservation far above any peak of these runs keeps a peak that merely jitters above the last one from counting as exceeding it.
        self.seed([self.row(GIB)])
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
        # The control: the same key and entry do record a run that ends by itself with status 0.
        status, _, _ = self.run_command("control", command=exits_with(0))
        self.assertEqual(status, 0)
        self.assertEqual(len(self.stored()), 2)

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

    def test_a_finished_run_sends_one_measurement_line_to_the_journal(self):
        """One journal entry per run: class, key, wait, run seconds, status, peak and reservation, on a single line."""
        requested = time.monotonic()
        process, started, release = self.start("measured", seconds=2 * HANG_SECONDS, arguments=["--resource-key", KEY],
                                               cwd=self.repo)
        self.wait_for(started.exists, process)
        # The command has run for at least this long when it is released.  Sleeping only ever makes that longer.
        held = 0.2
        time.sleep(held)
        release.touch()
        process.communicate(timeout=HANG_SECONDS)
        elapsed = time.monotonic() - requested
        self.assertEqual(process.returncode, 0)
        result = json.loads((self.root / "measured.result").read_text())
        entries = self.measurements()
        self.assertEqual(len(entries), 1)
        fields, record = entries[0]
        self.assertEqual(fields["SYSLOG_IDENTIFIER"], "dotfiles-supervise")
        self.assertNotIn("\n", fields["MESSAGE"])
        self.assertEqual((record["class"], record["key"], record["nested"], record["admitted"], record["status"]),
                         ("acceptance", KEY, False, True, 0))
        self.assertEqual(record["waitReasons"], [])
        self.assertGreaterEqual(record["waitSeconds"], 0)
        self.assertGreaterEqual(record["runSeconds"], held)
        self.assertLessEqual(record["runSeconds"], elapsed)
        self.assertEqual(record["peakBytes"], result["memoryPeakBytes"])
        self.assertEqual(record["reservedBytes"], result["memoryReservedBytes"])

    def test_a_run_that_never_started_reports_its_wait_and_reason(self):
        """A run that gave up while waiting says so: not admitted, no run seconds, the pressure as the reason."""
        envelope = json.loads(self.snapshot.read_text())
        envelope["outcomes"][0]["status"] = "warn"
        self.snapshot.write_text(json.dumps(envelope))
        process, started, _ = self.start("never-started", seconds=DEADLINE_SECONDS, arguments=["--resource-key", KEY], cwd=self.repo)
        # It is judged and found not to fit before the deadline runs out, so at least one reason is on record.
        self.waiting("never-started", process)
        process.communicate(timeout=HANG_SECONDS)
        self.assertFalse(started.exists())
        (_, record), = self.measurements()
        self.assertEqual((record["status"], record["admitted"], record["runSeconds"]), (124, False, None))
        # The last observation before the deadline runs out of time and its diagnosis is the final reason; the first is the cause.
        self.assertEqual(record["waitReasons"][0], "fixture")
        # The deadline starts before the supervisor's interpreter does, so the wait it measures cannot be longer than the deadline.
        self.assertGreater(record["waitSeconds"], 0)
        self.assertLessEqual(record["waitSeconds"], DEADLINE_SECONDS + DEADLINE_SLACK)

    def test_a_refused_run_reports_status_70(self):
        """A demand above the tightest limit is refused at once and the measurement still says so."""
        self.limit(4 * GIB, 2 * GIB)
        process, _, _ = self.start("refused", arguments=["--resource-memory", str(3 * GIB)], cwd=self.repo)
        process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 70)
        (_, record), = self.measurements()
        self.assertEqual((record["status"], record["admitted"]), (70, False))

    def test_a_nested_run_is_reported_as_nested_without_a_wait(self):
        """The inner supervisor of a nested run reports its own line, marked nested and with no wait."""
        inner = [sys.executable, str(SOURCE), "--resource-policy", str(self.policy),
                 "--resource-deadline", str(time.time() + 3), "--", *QUICK]
        process, _, _ = self.start("nesting", command=inner)
        process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 0)
        records = [record for _, record in self.measurements()]
        self.assertEqual(sorted(record["nested"] for record in records), [False, True])
        (nested_reasons,) = [record["waitReasons"] for record in records if record["nested"]]
        # A nested run is not admitted again, so it is never judged and has nothing to wait for.
        self.assertEqual(nested_reasons, [])

    def test_an_unreachable_journal_costs_one_stderr_line_and_not_the_exit_status(self):
        """The measurement is evidence for a later comparison and never decides the command's status."""
        policy = json.loads(self.policy.read_text())
        policy["journalSocket"] = str(self.root / "no-such-journal.sock")
        self.policy.write_text(json.dumps(policy))
        status, error, _ = self.run_command("unreachable", command=exits_with(0))
        self.assertEqual(status, 0)
        self.assertEqual(len([line for line in error.splitlines()
                              if line.startswith("dotfiles-supervise: cannot record the measurement in the journal")]), 1)

    def test_a_run_without_a_reservation_sends_nothing(self):
        """Only runs that took part in admission are measured."""
        subprocess.run([sys.executable, str(SOURCE), "--", *QUICK], check=True, env=self.environment())
        self.assertEqual(self.measurements(), [])


if __name__ == "__main__":
    unittest.main()
