"""Exercise admission through the real supervisor, a fake systemd and a fake cgroup tree, without allocating the declared memory.

The invariants under test (the design's I1 to I7):

  I1  The future growth of the running acceptance scopes, together with a new request, never exceeds a free amount.
  I2  An acceptance is not held back because other acceptances wait.
  I3  A deep run does not enter while an acceptance waits.
  I4  An acceptance that lacks memory cancels the running deep run, and nothing else.
  I5  At most one deep run exists.
  I6  A run that did not run, was cancelled or ran past its limit is neither a success nor a record of demand.
  I7  Who owns a run is decided by its scope and by waitpid, never by a record file: a supervisor that is killed
      neither blocks the others nor releases what its command still holds.
"""

import fcntl
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
FAKE = Path(sys.argv.pop(1)).resolve()
MIB = 1024 ** 2
GIB = 1024 ** 3
DAY = 24 * 60 * 60
KEY = "verify\n/repository\nmake verify"
MEMORY_PERCENT = 40
SLICES = {"acceptance": "agents.slice/agents-acceptance.slice", "deep": "agents.slice/agents-deep.slice"}
# How long a test waits for something that must happen before it calls the run hung.  It guards against a hang and decides
# nothing: what a test asserts about a run never depends on how fast the machine is.
HANG_SECONDS = 15
# A wait limit that lets a run be judged before it runs out, even on a loaded machine, and the slack the limit is allowed.
WAIT_LIMIT = 6
WAIT_SLACK = 1
# How old the observation may be.  It is taken once, when a test is set up, and every judgement of the test reads it, so
# this is far longer than any test takes, even on a loaded machine; a test that wants it stale makes it older than this.
OBSERVATION_AGE = 600
# A command that ends at once, for runs of which nothing is asked about their duration or their peak.
INSTANT = [sys.executable, "-c", "pass"]
# A limit so small that the reservation taken from it lies below the memory of any process.  One sample of a live process then
# exceeds it, so the peak a test expects does not depend on where the samples, about a second apart, happen to fall.
TINY_LIMIT = 1024
# How many more times a run that says it waits must set about judging before it is taken to stay waiting.  Every attempt runs
# the observation once, so the count of observations is the count of attempts and does not depend on how fast the machine is.
ROUNDS = 10
# The janitor of the fake systemd polls and removes a scope once EMPTY_POLLS (3) polls in a row find no member of it; this many
# polls would have removed a scope that has none many times over.
JANITOR_POLLS = 20
# Run inside a scope: write the scope's own oom_score_adj and wait until released.
OOM_SCORE = [sys.executable, "-c",
             "import pathlib,sys,time;"
             "pathlib.Path(sys.argv[1]).write_text(pathlib.Path('/proc/self/oom_score_adj').read_text());"
             "\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.01)"]
# Stands in for `dotfiles-observe-workload [CGROUP]`: the snapshot, with the limits of every ancestor of the cgroup the caller
# asked about added (`destinationLimits`), as the real observation walks up from the cgroup it is given.  It also appends the
# pid of its caller, the supervisor that judges, to `<snapshot>.observed`, so that a test can count the judgements.
OBSERVE = [sys.executable, "-c",
           "import json,os,pathlib,sys\n"
           "snapshot=json.loads(pathlib.Path(sys.argv[1]).read_text())\n"
           "value=snapshot['resources'][0]['value']\n"
           "where=sys.argv[2] if len(sys.argv)>2 else ''\n"
           "for limit in value.pop('destinationLimits',[]):\n"
           "    if where==limit['path'] or where.startswith(limit['path']+'/'): value['memoryLimits']=[*value['memoryLimits'],limit]\n"
           "with open(sys.argv[1]+'.observed','a') as log: log.write(str(os.getppid())+'\\n')\n"
           "print(json.dumps(snapshot))"]
# Run inside a scope: a descendant that outlives the command, then the command itself, which ends when released and says so.
DESCENDANT = [sys.executable, "-c",
              "import pathlib,subprocess,sys,time\n"
              "ready, ends, held, exited = map(pathlib.Path, sys.argv[1:5])\n"
              "subprocess.Popen([sys.executable, '-c', 'import pathlib,sys,time\\n"
              "while not pathlib.Path(sys.argv[1]).exists(): time.sleep(0.01)', str(held)],\n"
              "                 start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
              "ready.touch()\n"
              "while not ends.exists(): time.sleep(0.01)\n"
              "exited.touch()"]
# Run inside a scope: a command that handles SIGTERM and then ends with 0, as a graceful one does.
def graceful(marker, release):
    """A command that handles SIGTERM by ending with 0, touches `marker` when it runs and ends when `release` exists."""
    return [sys.executable, "-c",
            "import pathlib,signal,sys,time;signal.signal(signal.SIGTERM, lambda *_: sys.exit(0));"
            "pathlib.Path(sys.argv[1]).touch();"
            "\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.01)",
            str(marker), str(release)]
# Run inside a scope: stand for the command's own nested call by finding the scope it runs in, telling the inner
# supervisor so through its own-cgroup file, and running that supervisor.  It ignores SIGTERM, as a command that is
# cancelled while it waits for a stage does, and leaves the inner supervisor's status in a file for the test to read.
NESTED = r"""
import os, pathlib, signal, subprocess, sys
signal.signal(signal.SIGTERM, signal.SIG_IGN)
slice_directory, own_file, status_file, source, policy, *arguments = sys.argv[1:]
scope = pathlib.Path(os.environ["DOTFILES_FAKE_SCOPE"]).name
slice_relative = pathlib.Path(slice_directory).relative_to(pathlib.Path(own_file).parent / "cgroup")
pathlib.Path(own_file).write_text("0::/" + str(slice_relative) + "/" + scope + "\n")
result = subprocess.run([sys.executable, source, "--resource-policy", policy, *arguments])
pathlib.Path(status_file).write_text(str(result.returncode))
"""


def percent_of(percent, value):
    """The specification's percentage of a limit, rounded up."""
    return -(-percent * value // 100)


def agents_path():
    """The cgroup path of agents.slice as the observation reports it."""
    uid = os.getuid()
    return f"/user.slice/user-{uid}.slice/user@{uid}.service/agents.slice"


class ResourceAdmission(unittest.TestCase):
    """Concurrent callers sharing one machine policy and isolated temporary state."""

    def setUp(self):
        """Create policies, a deterministic resource-observation adapter, a fake cgroup tree and a journal for each case."""
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.cgroup = self.root / "cgroup"
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
                "memoryScopes": [],
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
        self.policy = self.write_policy("acceptance")
        self.deep_policy = self.write_policy("deep")
        # A directory to run in: the demand is keyed by the caller, not by what the working directory holds.
        self.repo = self.root / "repo"
        self.repo.mkdir()

    def write_policy(self, klass, name=None, fail=False, gate=None, **changes):
        """Write a policy file for a class: the real fields, with the fakes standing in for systemd and the cgroup tree."""
        slow = ["--gate", str(gate)] if gate else []
        policy = {
            "class": klass,
            "journalSocket": str(self.root / "journal.sock"),
            "observation": [*OBSERVE, str(self.snapshot)],
            "runtimeDirectory": str(self.root / "run"),
            "memoryPercent": MEMORY_PERCENT,
            "maximumObservationAgeSeconds": OBSERVATION_AGE,
            "systemdRun": [sys.executable, str(FAKE), "--cgroup-root", str(self.cgroup), *(["--fail"] if fail else []), *slow, "run"],
            "systemctl": [sys.executable, str(FAKE), "--cgroup-root", str(self.cgroup), "ctl"],
            "cgroupRoot": str(self.cgroup),
            "slices": SLICES,
            **changes,
        }
        path = self.root / (name or f"policy-{klass}.json")
        path.write_text(json.dumps(policy))
        return path

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
            try:
                process.communicate(timeout=HANG_SECONDS)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()

    def start(self, name, wait=2 * HANG_SECONDS, run=30, command=None, arguments=(), cwd=None, klass="acceptance", policy=None,
              status=0):
        """Start a workload with its own public result, a wait limit and a run limit; it holds until released.

        Without a command of its own, the workload touches its marker when it runs, ends when its release exists and then
        ends with `status`.  The marker and the release are named after the workload, so a name is used once.
        """
        marker = self.root / name
        release = self.root / (name + ".release")
        self.assertFalse(marker.exists(), f"{name} has been started before, so its marker would stand for the earlier run")
        worker = command or [sys.executable, "-c",
            "import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();"
            "\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.01)"
            "\nraise SystemExit(int(sys.argv[3]))",
            str(marker), str(release), str(status)]
        process = subprocess.Popen([
            sys.executable, str(SOURCE), "--require-drained", "--interrupt-cancels",
            "--result", str(self.root / (name + ".result")),
            "--resource-policy", str(policy or (self.policy if klass == "acceptance" else self.deep_policy)),
            "--resource-wait-until", str(time.time() + wait),
            "--resource-run-seconds", str(run),
            *arguments,
            "--", *worker,
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.environment(), cwd=cwd)
        self.children.append(process)
        # Whatever the test did, a command that is still waiting for its release must be able to end.
        self.addCleanup(release.touch)
        return process, marker, release

    def run_command(self, name, command=None, status=0, key=KEY, arguments=(), cwd=None, **options):
        """Run a command that ends by itself and return its status, its stderr and its result record.

        Unless the test brings a command of its own, the command is released as soon as it runs.  It then lives for as long
        as the machine takes to schedule the test and the command again, which grows with the load, so the supervisor has the
        longer to take a sample of it the busier the machine is.  A command that sleeps a fixed time has no such margin.
        """
        keyed = ["--resource-key", key] if key is not None else []
        process, started, release = self.start(name, command=command, status=status, arguments=[*keyed, *arguments],
                                               cwd=cwd or self.repo, **options)
        if command is None:
            self.wait_for(started.exists, process)
            release.touch()
        _, error = process.communicate(timeout=HANG_SECONDS)
        return process.returncode, error, json.loads((self.root / (name + ".result")).read_text())

    def wait_for(self, predicate, process=None):
        """Wait a bounded interval for an observable transition or fail on early exit."""
        until = time.monotonic() + HANG_SECONDS
        while not predicate():
            if process is not None and process.poll() is not None:
                self.fail(f"supervisor exited {process.returncode}: {process.communicate()[1]}")
            if time.monotonic() >= until:
                self.fail("transition did not occur")
            time.sleep(0.01)

    def waiting(self, name, process):
        """Wait until the named workload has told its result file that it waits for resources, and return the reason."""
        result = self.root / (name + ".result")
        self.wait_for(lambda: result.exists() and json.loads(result.read_text()).get("phase") == "waiting", process)
        return json.loads(result.read_text())["reason"]

    def finish(self, process):
        """The status of a workload that was told to end."""
        process.communicate(timeout=HANG_SECONDS)
        return process.returncode

    def scopes(self, klass):
        """The scope directories that exist now in the class's slice of the fake cgroup tree."""
        uid = os.getuid()
        directory = self.cgroup / "user.slice" / f"user-{uid}.slice" / f"user@{uid}.service" / SLICES[klass]
        return sorted(directory.iterdir()) if directory.exists() else []

    def calls(self, tool):
        """What the supervisor asked the fake systemd for, one list of arguments per call."""
        log = self.cgroup / "calls.log"
        rows = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return [row["arguments"] for row in rows if row["tool"] == tool]

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

    def uses(self, scope, working_set, current=None):
        """Observe the scope as using the memory given, as the real observation reports the scopes below a slice."""
        path = "/" + str(scope.relative_to(self.cgroup))
        self.observe(memoryScopes=[{"path": path, "currentBytes": working_set if current is None else current,
                                    "workingSetBytes": working_set}])

    def outcome(self, status):
        """Observe a pressure outcome of the given status next to the passing one."""
        envelope = json.loads(self.snapshot.read_text())
        envelope["outcomes"][0]["status"] = status
        self.snapshot.write_text(json.dumps(envelope))

    def judged(self, process):
        """How many times the workload has set about judging whether it may enter: its observation runs once for each."""
        log = Path(f"{self.snapshot}.observed")
        return log.read_text().split().count(str(process.pid)) if log.exists() else 0

    def keeps_waiting(self, process):
        """Wait until the workload has set about judging ROUNDS more times, so that what it waits for is known to last."""
        seen = self.judged(process)
        self.wait_for(lambda: self.judged(process) >= seen + ROUNDS, process)

    def held_back(self, name, **options):
        """Start a workload that must not be admitted, cancel it once it says it waits, and return its reason and its stderr.

        The run is judged and found not to be admitted before it is cancelled, so no wait limit is timed and no run that
        never got as far as a judgement passes for one that was refused.
        """
        process, started, _ = self.start(name, **options)
        reason = self.waiting(name, process)
        process.send_signal(signal.SIGTERM)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 143)
        self.assertFalse(started.exists())
        return reason, error

    def exhaust_windows_reserve(self):
        """Observe the Windows physical memory below its reserve, so that no headroom is left."""
        self.observe(windowsPhysicalAvailableBytes=5 * GIB, windowsPhysicalHeadroomBytes=0)

    def restore_windows_reserve(self):
        """Observe the Windows physical memory above its reserve again."""
        self.observe(windowsPhysicalAvailableBytes=10 * GIB, windowsPhysicalHeadroomBytes=2 * GIB)

    def polls(self, scope):
        """How many times the janitor of the fake systemd has looked at the scope for a member."""
        log = scope / "janitor.polls"
        return log.stat().st_size if log.exists() else 0

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

    # I1: reserved future growth

    def test_i1_competing_acceptances_reserve_future_growth_before_start(self):
        """Two requests of 40% of the sixteen-GiB machine cannot both enter ten GiB of observed headroom."""
        first, started, release = self.start("first")
        self.wait_for(started.exists, first)
        second, second_started, second_release = self.start("second")
        self.assertEqual(self.waiting("second", second), "Linux memory or Windows commit headroom is reserved")
        self.assertFalse(second_started.exists())
        release.touch()
        self.assertEqual(self.finish(first), 0)
        self.wait_for(second_started.exists, second)
        second_release.touch()
        self.assertEqual(self.finish(second), 0)

    def test_i1_the_memory_a_scope_already_uses_is_credited_to_it(self):
        """Only what a running acceptance may still claim is reserved: its reservation less the memory it already uses."""
        first, started, release = self.start("first")
        self.wait_for(started.exists, first)
        reserved = percent_of(MEMORY_PERCENT, 16 * GIB)
        (scope,) = self.scopes("acceptance")
        self.assertEqual((scope / "memory.low").read_text().strip(), str(reserved))
        # 8 GiB beside the 6.4 GiB reserved would not fit into 10 GiB; beside what is still unclaimed of it, it does.
        self.uses(scope, 5 * GIB)
        second, second_started, second_release = self.start("second", arguments=["--resource-memory", str(8 * GIB)])
        self.wait_for(second_started.exists, second)
        second_release.touch()
        self.assertEqual(self.finish(second), 0)
        release.touch()
        self.assertEqual(self.finish(first), 0)

    def test_i1_a_scope_that_uses_more_than_it_reserved_claims_nothing_more(self):
        """A scope above its reservation cannot grow into a reservation, so it adds no claim."""
        first, started, release = self.start("first")
        self.wait_for(started.exists, first)
        (scope,) = self.scopes("acceptance")
        self.uses(scope, 9 * GIB)
        # Beside a whole 6.4 GiB reservation 4 GiB would not fit into 10 GiB; beside a scope that has outgrown it, it does.
        second, second_started, second_release = self.start("second", arguments=["--resource-memory", str(4 * GIB)])
        self.wait_for(second_started.exists, second)
        second_release.touch()
        self.assertEqual(self.finish(second), 0)
        release.touch()
        self.assertEqual(self.finish(first), 0)

    def test_i1_a_recorded_peak_that_equals_the_cgroup_headroom_enters_and_one_byte_more_waits(self):
        """No margin is added to a peak, so a run whose peak fits the headroom alone is never shut out by a margin."""
        self.bounded(8 * GIB, 3 * GIB)
        self.seed([self.row(3 * GIB)])
        status, _, result = self.run_command("at-headroom")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 3 * GIB)
        self.seed([self.row(3 * GIB + 1)])
        reason, _ = self.held_back("over-headroom", arguments=["--resource-key", KEY], cwd=self.repo)
        self.assertEqual(reason, "memory headroom is reserved at /fixture-0.slice")

    # I2: no queue among acceptances

    def test_i2_an_acceptance_that_fits_enters_while_a_larger_one_waits(self):
        """A request that does not fit waits alone; it holds nobody else back, however long it has waited."""
        holder, held, holder_release = self.start("holder", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(held.exists, holder)
        large, large_started, large_release = self.start("large", arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("large", large)
        small, small_started, small_release = self.start("small", arguments=["--resource-memory", str(100 * MIB)])
        self.wait_for(small_started.exists, small)
        self.assertFalse(large_started.exists())
        small_release.touch()
        self.assertEqual(self.finish(small), 0)
        holder_release.touch()
        self.assertEqual(self.finish(holder), 0)
        self.wait_for(large_started.exists, large)
        large_release.touch()
        self.assertEqual(self.finish(large), 0)

    # I3: deep waits for waiting acceptances

    def test_i3_a_deep_run_does_not_enter_while_an_acceptance_waits(self):
        """A deep run that would fit still waits as long as an acceptance waits, and enters once none does."""
        holder, held, holder_release = self.start("holder", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(held.exists, holder)
        large, large_started, large_release = self.start("large", arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("large", large)
        deep, deep_started, deep_release = self.start("deep", klass="deep", arguments=["--resource-memory", str(100 * MIB)])
        self.assertEqual(self.waiting("deep", deep), "an acceptance verification is waiting")
        self.keeps_waiting(deep)
        self.assertFalse(deep_started.exists())
        holder_release.touch()
        self.assertEqual(self.finish(holder), 0)
        self.wait_for(large_started.exists, large)
        # The acceptance has entered, so none waits any more.
        self.wait_for(deep_started.exists, deep)
        deep_release.touch()
        self.assertEqual(self.finish(deep), 0)
        large_release.touch()
        self.assertEqual(self.finish(large), 0)

    def test_i3_pressure_stops_a_deep_run_at_a_warning_and_an_acceptance_only_at_a_failure(self):
        """The warning level that holds a deep run back leaves an acceptance running; a failure stops both."""
        self.outcome("warn")
        status, _, _ = self.run_command("acceptance-at-warning", key=None)
        self.assertEqual(status, 0)
        # A run that must not be admitted is judged, and found to wait for the pressure, before it is cancelled.
        reason, _ = self.held_back("deep-at-warning", klass="deep")
        self.assertEqual(reason, "fixture")
        self.outcome("fail")
        for klass in ("acceptance", "deep"):
            reason, _ = self.held_back(f"{klass}-at-failure", klass=klass)
            self.assertEqual(reason, "fixture", klass)

    # I4: only an acceptance without memory cancels, and only deep runs

    def test_i4_an_acceptance_without_memory_cancels_the_deep_run(self):
        """The deep run is stopped, ends with 143, records nothing and is not what the acceptance then waits for."""
        deep, deep_started, _ = self.start("deep", klass="deep", arguments=["--resource-key", "deep key", "--resource-memory", str(4 * GIB)])
        self.wait_for(deep_started.exists, deep)
        (deep_scope,) = self.scopes("deep")
        bystander = subprocess.Popen(["sleep", "30"])
        self.addCleanup(bystander.kill)
        self.observe(hostMemoryHeadroomBytes=GIB, memoryHeadroomBytes=GIB)
        acceptance, started, release = self.start("acceptance", arguments=["--resource-memory", str(2 * GIB)])
        self.wait_for(lambda: deep.poll() is not None, acceptance)
        # What the deep run held is free now.
        self.observe(hostMemoryHeadroomBytes=10 * GIB, memoryHeadroomBytes=10 * GIB)
        self.wait_for(started.exists, acceptance)
        self.assertEqual(deep.returncode, 143)
        result = json.loads((self.root / "deep.result").read_text())
        # The command was killed by SIGTERM: the result keeps the signal and the status is its 128 + 15.
        self.assertEqual((result["phase"], result["client_status"], result["status"]), ("finished", -signal.SIGTERM, 143))
        self.assertEqual(self.stored("deep key"), [])
        stops = self.calls("ctl")
        self.assertEqual([call for call in stops if "stop" in call], [["--user", "stop", "--no-block", deep_scope.name]])
        self.assertIsNone(bystander.poll())
        release.touch()
        self.assertEqual(self.finish(acceptance), 0)
        # The cancellation record was read and removed by the deep run; only the two locks are left.
        self.assertEqual(sorted(path.name for path in (self.root / "run").iterdir()), ["acceptance.waiting", "registry.lock"])

    def test_i6_a_cancelled_deep_run_is_a_cancellation_even_when_its_command_exits_0(self):
        """A command that handles SIGTERM and ends with 0 is still reported cancelled: 143, unfinished, no record of demand."""
        marker = self.root / "graceful"
        graceful = [sys.executable, "-c",
                    "import pathlib,signal,sys,time;signal.signal(signal.SIGTERM, lambda *_: sys.exit(0));"
                    "pathlib.Path(sys.argv[1]).touch();"
                    "\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.01)",
                    str(marker), str(self.root / "graceful.release")]
        deep, deep_started, _ = self.start("graceful", klass="deep", command=graceful,
                                           arguments=["--resource-key", "deep key", "--resource-memory", str(4 * GIB)])
        self.wait_for(deep_started.exists, deep)
        run_directory = self.root / "run"
        stale = run_directory / "cancel-dotfiles-workload-deep-1-stale.scope"
        stale.touch()
        os.utime(stale, (time.time() - 2 * 3600, time.time() - 2 * 3600))
        self.observe(hostMemoryHeadroomBytes=GIB, memoryHeadroomBytes=GIB)
        acceptance, started, release = self.start("acceptance", arguments=["--resource-memory", str(2 * GIB)])
        self.wait_for(lambda: deep.poll() is not None, acceptance)
        self.observe(hostMemoryHeadroomBytes=10 * GIB, memoryHeadroomBytes=10 * GIB)
        self.wait_for(started.exists, acceptance)
        result = json.loads((self.root / "graceful.result").read_text())
        self.assertEqual((deep.returncode, result["client_status"], result["status"], result["cancelled"]), (143, 0, 143, True))
        self.assertEqual(self.stored("deep key"), [])
        (_, record), = [entry for entry in self.measurements() if entry[1]["class"] == "deep"]
        self.assertEqual(record["status"], 143)
        # The record of an older cancellation whose scope is long gone is cleared when a new one is made.
        self.assertFalse(stale.exists())
        release.touch()
        self.assertEqual(self.finish(acceptance), 0)
        self.assertEqual(sorted(path.name for path in run_directory.iterdir()), ["acceptance.waiting", "registry.lock"])

    def test_i6_a_deep_run_that_is_not_cancelled_keeps_its_own_status(self):
        """The control: a deep run whose command ends with 0 on its own reports 0 and records its peak."""
        status, _, result = self.run_command("control", klass="deep", key="deep key")
        self.assertEqual((status, result["cancelled"]), (0, False))
        self.assertEqual(len(self.stored("deep key")), 1)

    def test_i6_a_deep_run_whose_stop_the_manager_refused_keeps_its_own_status(self):
        """A cancellation that never reached the scope is not one: the run ends by itself with 0 and records its peak."""
        deep, deep_started, deep_release = self.start("deep", klass="deep",
                                                      arguments=["--resource-key", "deep key", "--resource-memory", str(4 * GIB)])
        self.wait_for(deep_started.exists, deep)
        self.observe(hostMemoryHeadroomBytes=GIB, memoryHeadroomBytes=GIB)
        refusing = self.write_policy("acceptance", name="policy-refusing.json", systemctl=["false"])
        acceptance, started, _ = self.start("acceptance", policy=refusing, arguments=["--resource-memory", str(2 * GIB)])
        self.keeps_waiting(acceptance)
        # The acceptance is gone before the deep run ends, so no attempt of its is under way when the deep run looks.
        acceptance.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(acceptance), 143)
        self.assertFalse(started.exists())
        deep_release.touch()
        self.assertEqual(self.finish(deep), 0)
        result = json.loads((self.root / "deep.result").read_text())
        self.assertEqual((result["status"], result["cancelled"]), (0, False))
        self.assertEqual(len(self.stored("deep key")), 1)
        self.assertEqual(sorted(path.name for path in (self.root / "run").iterdir()), ["acceptance.waiting", "registry.lock"])

    def test_i4_a_waiting_acceptance_leaves_the_running_acceptances_alone(self):
        """With no deep run to give way, a request that lacks memory only waits: nothing is stopped."""
        holder, held, holder_release = self.start("holder", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(held.exists, holder)
        large, large_started, _ = self.start("large", arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("large", large)
        self.keeps_waiting(large)
        self.assertIsNone(holder.poll())
        self.assertEqual([call for call in self.calls("ctl") if "stop" in call], [])
        holder_release.touch()
        self.assertEqual(self.finish(holder), 0)
        self.wait_for(large_started.exists, large)

    def test_i4_a_deep_run_never_cancels_anything(self):
        """A deep run that lacks memory waits; the deep run that runs and the acceptances are left as they are."""
        holder, held, holder_release = self.start("holder", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(held.exists, holder)
        deep, deep_started, _ = self.start("deep", klass="deep", arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("deep", deep)
        self.keeps_waiting(deep)
        self.assertIsNone(holder.poll())
        self.assertEqual([call for call in self.calls("ctl") if "stop" in call], [])
        holder_release.touch()
        self.assertEqual(self.finish(holder), 0)
        self.wait_for(deep_started.exists, deep)

    # I5: one deep run

    def test_i5_only_one_deep_run_at_a_time(self):
        """A second deep run waits for the first, however much memory is free."""
        first, first_started, first_release = self.start("first", klass="deep", arguments=["--resource-memory", str(100 * MIB)])
        self.wait_for(first_started.exists, first)
        second, second_started, second_release = self.start("second", klass="deep", arguments=["--resource-memory", str(100 * MIB)])
        self.assertEqual(self.waiting("second", second), "another deep verification is running")
        self.keeps_waiting(second)
        self.assertFalse(second_started.exists())
        first_release.touch()
        self.assertEqual(self.finish(first), 0)
        self.wait_for(second_started.exists, second)
        second_release.touch()
        self.assertEqual(self.finish(second), 0)

    # I6: what is not a success and not a record

    def test_i6_the_wait_limit_returns_75_and_nothing_is_started(self):
        """A run that could not enter within the wait limit is reported unstarted, with its wait, and records nothing."""
        self.outcome("fail")
        process, started, _ = self.start("never", wait=WAIT_LIMIT, arguments=["--resource-key", KEY], cwd=self.repo)
        # It is judged and found not to fit before the limit runs out; the limit then ends the wait.
        self.waiting("never", process)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 75)
        self.assertFalse(started.exists())
        self.assertIn("gave up waiting for resources", error)
        result = json.loads((self.root / "never.result").read_text())
        self.assertEqual((result["phase"], result["spawned"], result["deferred"], result["status"]), ("finished", False, True, 75))
        # The limit starts before the supervisor's interpreter does, so the wait it measures cannot be longer than the limit.
        self.assertGreater(result["waitSeconds"], 0)
        self.assertLessEqual(result["waitSeconds"], WAIT_LIMIT + WAIT_SLACK)
        self.assertEqual(self.stored(), [])
        self.assertEqual(self.scopes("acceptance"), [])

    def test_i6_the_run_limit_counts_from_admission_not_from_the_request(self):
        """Waiting for room does not use up the run limit: a command that waited longer than its limit still gets all of it."""
        holder, held, holder_release = self.start("holder", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(held.exists, holder)
        waiter, _, _ = self.start("waiter", wait=2 * HANG_SECONDS, run=3, command=INSTANT,
                                  arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("waiter", waiter)
        # The wait outlasts the run limit.  Sleeping only ever makes it longer, so no load can make it too short.
        time.sleep(3.5)
        holder_release.touch()
        self.assertEqual(self.finish(holder), 0)
        self.assertEqual(self.finish(waiter), 0)
        result = json.loads((self.root / "waiter.result").read_text())
        self.assertGreaterEqual(result["waitSeconds"], 3)

    def test_i6_a_run_past_its_run_limit_ends_with_124_and_records_nothing(self):
        """A command that outlives its run limit is stopped, reports 124 and leaves no record of its demand."""
        status, _, result = self.run_command("overrun", run=0.6, command=[sys.executable, "-c", "import time; time.sleep(30)"])
        self.assertEqual(status, 124)
        self.assertTrue(result["spawned"])
        self.assertEqual(self.stored(), [])

    def test_i6_runs_that_fail_are_cut_short_or_cancelled_leave_no_record(self):
        """Only a run that ends by itself with status 0 is recorded; failures, 124, 128 or more, cancellation and the limit are not."""
        # A reservation far above any peak of these runs keeps a peak that merely jitters above the last one from counting as exceeding it.
        self.seed([self.row(GIB)])
        # A failure stops inside the entry with a peak below the demand, and recording it lowers the next reservation.
        for status in (1, 3, 124, 130):
            with self.subTest(status=status):
                self.assertEqual(self.run_command(f"status-{status}", status=status)[0], status)
                self.assertEqual(len(self.stored()), 1)
        keyed = ["--resource-key", KEY]
        cancelled, started, _ = self.start("cancelled-run", arguments=keyed, cwd=self.repo)
        self.wait_for(started.exists, cancelled)
        cancelled.send_signal(signal.SIGTERM)
        cancelled.communicate(timeout=HANG_SECONDS)
        self.assertEqual(cancelled.returncode, 143)
        expiring, _, _ = self.start("expired-run", run=0.6, command=[sys.executable, "-c", "import time; time.sleep(30)"],
                                    arguments=keyed, cwd=self.repo)
        expiring.communicate(timeout=HANG_SECONDS)
        self.assertEqual(expiring.returncode, 124)
        self.assertEqual(len(self.stored()), 1)
        # The control: the same key and entry do record a run that ends by itself with status 0.
        status, _, _ = self.run_command("control")
        self.assertEqual(status, 0)
        self.assertEqual(len(self.stored()), 2)

    def test_i6_a_cancelled_waiter_does_not_cancel_admitted_work(self):
        """Cancelling a queued caller leaves the admitted caller and its scope intact."""
        first, started, release = self.start("active", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(started.exists, first)
        waiting, waiting_started, _ = self.start("cancelled", arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("cancelled", waiting)
        waiting.send_signal(signal.SIGTERM)
        waiting.communicate(timeout=HANG_SECONDS)
        self.assertEqual(waiting.returncode, 143)
        self.assertFalse(waiting_started.exists())
        self.assertIsNone(first.poll())
        self.assertEqual(len(self.scopes("acceptance")), 1)
        release.touch()
        self.assertEqual(self.finish(first), 0)

    def test_i6_pressure_defers_without_starting(self):
        """Pressure leaves a run waiting, with nothing started, rather than failing it."""
        self.outcome("fail")
        reason, _ = self.held_back("deferred")
        self.assertEqual(reason, "fixture")
        result = json.loads((self.root / "deferred.result").read_text())
        self.assertTrue(result["deferred"])
        self.assertFalse(result["spawned"])
        self.assertEqual(self.scopes("acceptance"), [])

    def test_i6_a_stale_observation_never_authorizes_execution(self):
        """A stale successful envelope cannot admit a workload."""
        self.observe(observedAt=time.time() - OBSERVATION_AGE - 1)
        reason, _ = self.held_back("stale")
        self.assertEqual(reason, "resource observation is stale")

    # I7: ownership is the scope and waitpid

    def test_i7_a_killed_supervisor_blocks_nobody_and_its_scope_keeps_counting(self):
        """Killing a supervisor leaves no record that stops the others with 70; what its command still holds stays reserved."""
        first, started, release = self.start("first", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(started.exists, first)
        first.kill()
        first.wait()
        first.stdout.close()
        first.stderr.close()
        self.assertEqual(len(self.scopes("acceptance")), 1)
        small, small_started, small_release = self.start("small", arguments=["--resource-memory", str(100 * MIB)])
        self.wait_for(small_started.exists, small)
        small_release.touch()
        self.assertEqual(self.finish(small), 0)
        large, large_started, large_release = self.start("large", arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("large", large)
        release.touch()
        self.wait_for(large_started.exists, large)
        large_release.touch()
        self.assertEqual(self.finish(large), 0)
        self.assertEqual(sorted(path.name for path in (self.root / "run").iterdir()), ["acceptance.waiting", "registry.lock"])

    def test_i7_a_killed_deep_supervisor_still_occupies_the_deep_slot(self):
        """The deep run's command goes on after its supervisor is killed, so a second deep run keeps waiting for it."""
        first, started, release = self.start("first", klass="deep", arguments=["--resource-memory", str(100 * MIB)])
        self.wait_for(started.exists, first)
        first.kill()
        first.wait()
        first.stdout.close()
        first.stderr.close()
        second, second_started, second_release = self.start("second", klass="deep", arguments=["--resource-memory", str(100 * MIB)])
        self.assertEqual(self.waiting("second", second), "another deep verification is running")
        self.keeps_waiting(second)
        self.assertFalse(second_started.exists())
        release.touch()
        self.wait_for(second_started.exists, second)
        second_release.touch()
        self.assertEqual(self.finish(second), 0)

    # Review findings: each test below was written to fail before its fix

    def test_i1_the_limits_of_the_slice_a_run_is_placed_in_are_judged_even_when_it_starts_elsewhere(self):
        """The limits that bind a run are those of the slice it is moved into, not only those above whoever started it."""
        self.observe(destinationLimits=[{"path": agents_path(), "headroomBytes": GIB, "limitBytes": 8 * GIB,
                                         "currentBytes": 0, "workingSetBytes": 0}])
        reason, _ = self.held_back("over", arguments=["--resource-memory", str(2 * GIB)])
        self.assertEqual(reason, f"memory headroom is reserved at {agents_path()}")
        status, _, _ = self.run_command("under", key=None, arguments=["--resource-memory", str(512 * MIB)])
        self.assertEqual(status, 0)

    def test_i1_the_remaining_reservation_is_the_reported_working_set_not_the_reported_current_usage(self):
        """What a scope may still claim is its reservation less the working set the observation reports for it.

        The observation owns what counts as reclaimable; the supervisor takes the value and does not work it out again.
        """
        first, started, release = self.start("first", arguments=["--resource-memory", str(6 * GIB)])
        self.wait_for(started.exists, first)
        (scope,) = self.scopes("acceptance")
        # Nine GiB are charged to the scope, of which four are cache that the observation does not count as in use.
        self.uses(scope, 5 * GIB, current=9 * GIB)
        # Six GiB reserved and five in use leave one GiB to claim: 9 GiB fits into 10 beside it, 9.5 GiB does not.
        second, second_started, second_release = self.start("second", arguments=["--resource-memory", str(int(9.5 * GIB))])
        self.waiting("second", second)
        self.assertFalse(second_started.exists(), "the claim was worked out from something other than the reported working set")
        third, third_started, third_release = self.start("third", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(third_started.exists, third)
        third_release.touch()
        self.assertEqual(self.finish(third), 0)
        release.touch()
        self.assertEqual(self.finish(first), 0)
        self.wait_for(second_started.exists, second)
        second_release.touch()
        self.assertEqual(self.finish(second), 0)

    def test_i1_a_scope_the_observation_does_not_report_claims_its_whole_reservation(self):
        """What is not seen is assumed to be still ahead: a scope without a reported usage keeps its whole reservation claimed."""
        first, started, release = self.start("first", arguments=["--resource-memory", str(6 * GIB)])
        self.wait_for(started.exists, first)
        second, second_started, second_release = self.start("second", arguments=["--resource-memory", str(5 * GIB)])
        self.waiting("second", second)
        self.assertFalse(second_started.exists(), "a scope without a reported usage was left out of the reservation")
        third, third_started, third_release = self.start("third", arguments=["--resource-memory", str(3 * GIB)])
        self.wait_for(third_started.exists, third)
        third_release.touch()
        self.assertEqual(self.finish(third), 0)
        release.touch()
        self.assertEqual(self.finish(first), 0)
        self.wait_for(second_started.exists, second)
        second_release.touch()
        self.assertEqual(self.finish(second), 0)

    def test_a_malformed_scope_usage_in_the_observation_is_not_trusted(self):
        """An observation whose scope usage is not a list is no basis for an admission."""
        self.observe(memoryScopes="unknown")
        process, started, _ = self.start("blind", wait=2 * HANG_SECONDS)
        self.assertIn("usage of the scopes", self.waiting("blind", process))
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=HANG_SECONDS)
        self.assertFalse(started.exists())

    def test_a_scope_that_is_slow_to_start_does_not_outlive_the_wait_limit(self):
        """Creating the scope is part of the wait: a manager that answers after the limit leaves the command unstarted."""
        # The manager does not answer until the gate opens, which it never does within the limit.
        slow = self.write_policy("acceptance", name="slow.json", gate=self.root / "never-opens")
        process, started, _ = self.start("slow", wait=WAIT_LIMIT, policy=slow)
        # The supervisor has asked for the scope, so it is the request for the scope that the limit runs out in.
        self.wait_for(lambda: self.calls("run"), process)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 75, error)
        self.assertFalse(started.exists())
        self.assertFalse(json.loads((self.root / "slow.result").read_text())["spawned"])
        self.assertEqual(self.scopes("acceptance"), [])

    def test_i3_no_acceptance_can_start_waiting_while_a_deep_run_is_being_admitted(self):
        """Between finding that no acceptance waits and the deep run being admitted, none can begin to wait."""
        gate = self.root / "scope-gate"
        self.addCleanup(gate.touch)
        slow = self.write_policy("deep", name="slow-deep.json", gate=gate)
        deep, deep_started, deep_release = self.start("deep", klass="deep", policy=slow, arguments=["--resource-memory", str(100 * MIB)])
        # systemd-run has been asked, so the admission is under way but the command does not run yet.
        self.wait_for(lambda: self.calls("run"), deep)
        self.assertFalse(deep_started.exists())
        marker = os.open(self.root / "run" / "acceptance.waiting", os.O_RDWR | os.O_CLOEXEC)
        self.addCleanup(os.close, marker)
        with self.assertRaises(BlockingIOError, msg="an acceptance could register as waiting during the admission of a deep run"):
            fcntl.flock(marker, fcntl.LOCK_SH | fcntl.LOCK_NB)
        gate.touch()
        self.wait_for(deep_started.exists, deep)
        fcntl.flock(marker, fcntl.LOCK_SH | fcntl.LOCK_NB)
        deep_release.touch()
        self.assertEqual(self.finish(deep), 0)

    def test_i6_a_nested_run_in_a_cancelled_deep_scope_is_cancelled_too(self):
        """The nested call reports the cancellation of the scope it runs in, whatever its own command ends with, and records nothing."""
        marker, release = self.root / "inner-graceful", self.root / "inner-graceful.release"
        outer, status = self.start_nested("deep", "deep", "--resource-key", "inner key", outer=["--resource-memory", str(4 * GIB)],
                                          inner=graceful(marker, release))
        self.wait_for(marker.exists, outer)
        self.observe(hostMemoryHeadroomBytes=GIB, memoryHeadroomBytes=GIB)
        acceptance, started, acceptance_release = self.start("acceptance", arguments=["--resource-memory", str(2 * GIB)])
        self.wait_for(lambda: outer.poll() is not None, acceptance)
        self.observe(hostMemoryHeadroomBytes=10 * GIB, memoryHeadroomBytes=10 * GIB)
        self.wait_for(started.exists, acceptance)
        self.assertEqual(int(status.read_text()), 143)
        self.assertEqual(self.stored("inner key"), [])
        self.assertEqual(outer.returncode, 143)
        acceptance_release.touch()
        self.assertEqual(self.finish(acceptance), 0)

    def test_i7_a_scope_lasts_as_long_as_any_descendant_of_its_command(self):
        """When the supervisor is gone and the command has ended, a descendant that is left still holds the scope and its reservation."""
        ready, ends, held, exited = (self.root / f"descendant-{name}" for name in ("ready", "ends", "held", "exited"))
        self.addCleanup(held.touch)
        first, _, _ = self.start("holder", command=[*DESCENDANT, str(ready), str(ends), str(held), str(exited)],
                                 arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(ready.exists, first)
        (scope,) = self.scopes("acceptance")
        first.kill()
        first.wait()
        first.stdout.close()
        first.stderr.close()
        ends.touch()
        # The command has ended once it says so; the janitor then looks for a member of the scope more often than it needs
        # to remove a scope that has none, and removes this one only if it does not count the descendant.
        self.wait_for(exited.exists)
        seen = self.polls(scope)
        self.wait_for(lambda: not scope.exists() or self.polls(scope) >= seen + JANITOR_POLLS)
        self.assertEqual(len(self.scopes("acceptance")), 1, "the scope vanished while a descendant of its command was alive")
        large, large_started, large_release = self.start("large", arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("large", large)
        held.touch()
        self.wait_for(large_started.exists, large)
        large_release.touch()
        self.assertEqual(self.finish(large), 0)

    # What the scope is

    def test_each_run_gets_its_own_scope_with_its_demand_in_the_class_slice(self):
        """An acceptance reserves in memory.low and a deep run caps in memory.high, each in the slice of its class."""
        acceptance, started, release = self.start("acceptance", arguments=["--resource-memory", str(GIB)])
        self.wait_for(started.exists, acceptance)
        deep, deep_started, deep_release = self.start("deep", klass="deep", arguments=["--resource-memory", str(2 * GIB)])
        self.wait_for(deep_started.exists, deep)
        (acceptance_scope,) = self.scopes("acceptance")
        (deep_scope,) = self.scopes("deep")
        self.assertEqual((acceptance_scope / "memory.low").read_text().strip(), str(GIB))
        self.assertEqual((deep_scope / "memory.high").read_text().strip(), str(2 * GIB))
        runs = {call[[argument.startswith("--unit=") for argument in call].index(True)]: call for call in self.calls("run")}
        self.assertEqual(sorted(runs), sorted(f"--unit={scope.name}" for scope in (acceptance_scope, deep_scope)))
        self.assertIn("--slice=agents-acceptance.slice", runs[f"--unit={acceptance_scope.name}"])
        self.assertIn("--slice=agents-deep.slice", runs[f"--unit={deep_scope.name}"])
        self.assertIn(f"MemoryLow={GIB}", runs[f"--unit={acceptance_scope.name}"])
        self.assertIn(f"MemoryHigh={2 * GIB}", runs[f"--unit={deep_scope.name}"])
        release.touch()
        deep_release.touch()
        self.assertEqual(self.finish(acceptance), 0)
        self.assertEqual(self.finish(deep), 0)

    def test_only_a_deep_run_is_made_the_first_for_the_kernel_to_kill(self):
        """oom_score_adj is raised for a deep run and left alone for an acceptance."""
        for klass, expected in (("acceptance", "0"), ("deep", "1000")):
            seen = self.root / f"{klass}.score"
            process, _, _ = self.start(klass, klass=klass, command=[*OOM_SCORE, str(seen), str(self.root / f"{klass}.release")])
            self.wait_for(seen.exists, process)
            (self.root / f"{klass}.release").touch()
            self.assertEqual(self.finish(process), 0)
            self.assertEqual(seen.read_text().strip(), expected, klass)

    def test_a_scope_that_cannot_be_created_fails_with_70_and_runs_nothing(self):
        """When systemd-run cannot make the scope, the command is not started and the status says why."""
        broken = self.write_policy("acceptance", name="broken.json", fail=True)
        process, started, _ = self.start("broken", policy=broken)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 70)
        self.assertIn("cannot create the scope", error)
        self.assertFalse(started.exists())

    def test_a_command_that_cannot_be_executed_in_its_scope_reports_127(self):
        """A missing command surfaces as the shell's 127, as it does without a scope."""
        process, _, _ = self.start("missing", command=["/nonexistent/command"])
        process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 127)

    # The Windows physical reserve

    def test_an_acceptance_enters_while_the_windows_reserve_is_exhausted(self):
        """People wait for an acceptance, and low Windows physical memory costs paging only, which the commit headroom backs."""
        self.exhaust_windows_reserve()
        status, _, _ = self.run_command("windows-low", key=None)
        self.assertEqual(status, 0)
        (_, record), = self.measurements()
        self.assertNotIn("Windows physical reserve is exhausted", record["waitReasons"])

    def test_a_deep_run_waits_while_the_windows_reserve_is_exhausted_and_enters_when_it_is_back(self):
        """Nobody waits for a deep run, so it does not enter on a reserve that is not kept."""
        self.exhaust_windows_reserve()
        process, started, release = self.start("deep", klass="deep")
        self.waiting("deep", process)
        self.keeps_waiting(process)
        self.assertEqual(self.waiting("deep", process), "Windows physical reserve is exhausted")
        self.assertFalse(started.exists())
        self.restore_windows_reserve()
        self.wait_for(started.exists, process)
        release.touch()
        self.assertEqual(self.finish(process), 0)

    # Nested runs

    def start_nested(self, klass, inner_klass, *arguments, outer=(), inner=INSTANT, name=None):
        """Start a run of `klass` whose command makes a nested call of `inner_klass`; return it with the file that gets the inner status."""
        name = name or f"outer-{klass}-{inner_klass}"
        own = self.root / f"own-{name}.cgroup"
        status = self.root / f"{name}.inner-status"
        uid = os.getuid()
        inner_policy = self.write_policy(inner_klass, name=f"inner-{name}.json", procCgroup=str(own))
        slice_directory = self.cgroup / "user.slice" / f"user-{uid}.slice" / f"user@{uid}.service" / SLICES[klass]
        worker = [sys.executable, "-c", NESTED, str(slice_directory), str(own), str(status), str(SOURCE), str(inner_policy),
                  "--resource-wait-until", str(time.time() + 2 * HANG_SECONDS), "--resource-run-seconds", str(2 * HANG_SECONDS),
                  *arguments, "--", *inner]
        process, _, _ = self.start(name, klass=klass, command=worker, arguments=outer)
        return process, status

    def nested(self, klass, inner_klass, *arguments, outer=()):
        """Run a supervisor inside the scope of an outer run of `klass`, with the inner policy of `inner_klass`; return the inner status."""
        process, status = self.start_nested(klass, inner_klass, *arguments, outer=outer)
        process.communicate(timeout=HANG_SECONDS)
        return int(status.read_text())

    def test_a_nested_run_inside_a_scope_runs_in_it_without_a_scope_of_its_own(self):
        """The call a command makes inside its own scope is neither admitted again nor given a second scope."""
        for klass in ("acceptance", "deep"):
            with self.subTest(klass=klass):
                self.assertEqual(self.nested(klass, klass), 0)
                self.assertEqual(len([call for call in self.calls("run") if f"--slice=agents-{klass}.slice" in call]), 1)

    def test_a_nested_acceptance_inside_a_deep_run_stays_a_deep_run(self):
        """A nested call cannot raise its class: inside a deep run it makes no acceptance scope and takes no acceptance's place."""
        self.assertEqual(self.nested("deep", "acceptance"), 0)
        self.assertEqual([call for call in self.calls("run") if "--slice=agents-acceptance.slice" in call], [])

    def test_a_nested_run_may_not_ask_for_more_than_the_scope_it_is_in(self):
        """An explicit demand above the outer reservation fails with 70; a recorded or default one is cut to it."""
        self.assertEqual(self.nested("acceptance", "acceptance", "--resource-memory", str(2 * GIB),
                                     outer=["--resource-memory", str(GIB)]), 70)
        self.seed([self.row(3 * GIB)])
        self.assertEqual(self.nested("acceptance", "acceptance", "--resource-key", KEY,
                                     outer=["--resource-memory", str(GIB)]), 0)

    # Demand: explicit, recorded, default

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
        before = int(time.time())
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
        self.assertGreaterEqual(records[0]["at"], before)
        self.assertLessEqual(records[0]["at"], time.time())
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

    def test_a_key_without_records_reserves_the_median_of_the_newest_peak_of_each_other_key(self):
        """The measurements of this host stand in for a percentage nobody measured; each key counts once, by its newest record."""
        self.seed([self.row(2 * GIB), self.row(5 * GIB, age=DAY)], key="other a")
        self.seed([self.row(GIB)], key="other b")
        self.seed([self.row(3 * GIB)], key="other c")
        status, _, result = self.run_command("odd")
        self.assertEqual(status, 0)
        # The newest peaks are 1, 2 and 3 GiB; counting every record of a key or taking their largest would make it 3.
        self.assertEqual(result["memoryReservedBytes"], 2 * GIB)
        self.assertEqual(len(self.stored()), 1)

    def test_an_even_number_of_keys_reserves_the_larger_of_the_two_middle_peaks(self):
        """With four peaks of 1, 2, 3 and 4 GiB the demand is 3 GiB, not 2."""
        for index, peak in enumerate((GIB, 2 * GIB, 3 * GIB, 4 * GIB)):
            self.seed([self.row(peak)], key=f"other {index}")
        status, _, result = self.run_command("even")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 3 * GIB)

    def test_a_key_with_records_of_its_own_ignores_the_other_keys(self):
        """Only a key that has no record borrows: its own newest five peaks set the demand beside records of other keys."""
        self.seed([self.row(300_000_000)])
        self.seed([self.row(2 * GIB)], key="other a")
        self.seed([self.row(3 * GIB)], key="other b")
        status, _, result = self.run_command("own")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 300_000_000)

    def test_the_median_of_the_other_keys_is_cut_to_the_tightest_limit(self):
        """A demand borrowed from the host is cut like any other that is not explicit."""
        self.limit(4 * GIB, 2 * GIB)
        self.seed([self.row(3 * GIB)], key="other a")
        status, _, result = self.run_command("borrowed-over")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 2 * GIB)

    def test_a_run_without_a_key_or_with_an_explicit_demand_does_not_borrow_from_the_other_keys(self):
        """Only a keyed run without a demand of its own takes the median; the default and the declared demand stand as they were."""
        self.seed([self.row(GIB)], key="other a")
        status, _, result = self.run_command("unkeyed-beside-records", key=None)
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], percent_of(MEMORY_PERCENT, 16 * GIB))
        status, _, result = self.run_command("explicit-beside-records", arguments=["--resource-memory", str(2 * GIB)])
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 2 * GIB)

    def break_records(self):
        """Leave files in the record directory that no key's record can be read from."""
        directory = self.demand_file().parent
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        (directory / "garbage.json").write_text("{not json")
        (directory / "version.json").write_text('{"version": 2, "records": []}')
        (directory / "list.json").write_text("[]")
        (directory / "no-peak.json").write_text(json.dumps({"version": 1, "records": [{"at": 1}, "text", 7]}))
        (directory / "folder.json").mkdir()

    def test_files_of_other_keys_that_cannot_be_read_do_not_count(self):
        """A file that is unreadable or malformed is as good as no key: the run goes on, silently, on the keys that can be read."""
        self.seed([self.row(2 * GIB)], key="other a")
        self.break_records()
        status, error, result = self.run_command("beside-broken")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 2 * GIB)
        self.assertNotIn("cannot read the measured memory demand", error)

    def test_a_host_with_no_readable_record_reserves_the_percentage(self):
        """When no other key yields a peak the default stands, however many files lie in the directory."""
        self.break_records()
        status, error, result = self.run_command("only-broken")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], percent_of(MEMORY_PERCENT, 16 * GIB))
        self.assertNotIn("cannot read the measured memory demand", error)

    def test_explicit_demand_above_the_tightest_limit_fails_without_waiting_or_starting(self):
        """An explicit demand is never cut: above the smallest limitBytes it fails at once and nothing is started."""
        self.limit(4 * GIB, 2 * GIB)
        process, started, _ = self.start("explicit-over", arguments=["--resource-memory", str(3 * GIB)], cwd=self.repo)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 70)
        self.assertIn("exceeds the tightest limit", error)
        self.assertFalse(started.exists())
        self.assertEqual(self.scopes("acceptance"), [])
        status, _, result = self.run_command("explicit-at", key=None, arguments=["--resource-memory", str(2 * GIB)])
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], 2 * GIB)

    def test_a_failed_run_whose_peak_exceeded_the_reservation_is_recorded(self):
        """A peak above the reservation is a lower bound of the demand even when the run fails, so it is kept."""
        self.limit(TINY_LIMIT)
        status, error, _ = self.run_command("exceeding-failure", status=1)
        self.assertEqual(status, 1)
        self.assertIn("exceeded the reservation", error)
        records = self.stored()
        self.assertEqual(len(records), 1)
        self.assertIs(records[0]["exceeded"], True)
        self.assertGreater(records[0]["peakBytes"], records[0]["reservedBytes"])

    def test_peak_above_the_reservation_is_reported_once_and_recorded(self):
        """A measured peak above the settled demand prints one line and sets exceeded in the record."""
        self.limit(TINY_LIMIT)
        status, error, result = self.run_command("exceeding")
        self.assertEqual(status, 0)
        reserved = percent_of(MEMORY_PERCENT, TINY_LIMIT)
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
        for index, content in enumerate(("{not json", '{"version":2,"records":[]}', "[]")):
            with self.subTest(content=content):
                path = self.demand_file()
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                path.write_text(content)
                status, error, result = self.run_command(f"unreadable-{index}")
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
        status, error, result = self.run_command("unwritable")
        self.assertEqual(status, 0)
        self.assertEqual(result["memoryReservedBytes"], percent_of(MEMORY_PERCENT, 16 * GIB))
        self.assertEqual(len([line for line in error.splitlines() if "cannot read the measured memory demand" in line]), 1)
        self.assertEqual(len([line for line in error.splitlines() if "cannot record the measured memory peak" in line]), 1)

    # The measurement

    def test_a_finished_run_sends_one_measurement_line_to_the_journal(self):
        """One journal entry per run: class, key, wait, run seconds, status, peak and reservation, on a single line."""
        requested = time.monotonic()
        process, started, release = self.start("measured", arguments=["--resource-key", KEY], cwd=self.repo)
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
        self.outcome("fail")
        process, started, _ = self.start("never-started", wait=WAIT_LIMIT, arguments=["--resource-key", KEY], cwd=self.repo)
        # It is judged and found not to fit before the limit runs out, so at least one reason is on record.
        self.waiting("never-started", process)
        process.communicate(timeout=HANG_SECONDS)
        self.assertFalse(started.exists())
        (_, record), = self.measurements()
        self.assertEqual((record["status"], record["admitted"], record["runSeconds"]), (75, False, None))
        # The last observation before the limit runs out of time and its diagnosis is the final reason; the first is the cause.
        self.assertEqual(record["waitReasons"][0], "fixture")
        # The limit starts before the supervisor's interpreter does, so the wait it measures cannot be longer than the limit.
        self.assertGreater(record["waitSeconds"], 0)
        self.assertLessEqual(record["waitSeconds"], WAIT_LIMIT + WAIT_SLACK)

    def test_a_refused_run_reports_status_70(self):
        """A demand above the tightest limit is refused at once and the measurement still says so."""
        self.limit(4 * GIB, 2 * GIB)
        process, _, _ = self.start("refused", arguments=["--resource-memory", str(3 * GIB)], cwd=self.repo)
        process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 70)
        (_, record), = self.measurements()
        self.assertEqual((record["status"], record["admitted"]), (70, False))

    def test_a_nested_run_is_reported_as_nested_in_the_class_it_runs_as(self):
        """The inner supervisor reports its own line, marked nested, with no wait and the class of the scope it is in."""
        self.assertEqual(self.nested("deep", "acceptance"), 0)
        records = [record for _, record in self.measurements()]
        self.assertEqual(sorted((record["nested"], record["class"]) for record in records), [(False, "deep"), (True, "deep")])
        (nested_reasons,) = [record["waitReasons"] for record in records if record["nested"]]
        # A nested run is not admitted again, so it is never judged and has nothing to wait for.
        self.assertEqual(nested_reasons, [])

    def test_an_unreachable_journal_costs_one_stderr_line_and_not_the_exit_status(self):
        """The measurement is evidence for a later comparison and never decides the command's status."""
        self.policy = self.write_policy("acceptance", journalSocket=str(self.root / "no-such-journal.sock"))
        status, error, _ = self.run_command("unreachable")
        self.assertEqual(status, 0)
        self.assertEqual(len([line for line in error.splitlines()
                              if line.startswith("dotfiles-supervise: cannot record the measurement in the journal")]), 1)

    def test_a_run_without_a_reservation_sends_nothing(self):
        """Only runs that took part in admission are measured."""
        subprocess.run([sys.executable, str(SOURCE), "--", *INSTANT], check=True, env=self.environment())
        self.assertEqual(self.measurements(), [])


if __name__ == "__main__":
    unittest.main()
