"""Exercise admission through the real supervisor, a fake systemd and a fake cgroup tree, without allocating the declared memory.

The invariants under test (the design's I1 to I9):

  I1  The future growth of the running acceptance scopes, together with a new request, never exceeds a free amount.
  I2  An acceptance is not held back because other acceptances wait.
  I3  A deep run does not enter while an acceptance waits.
  I4  An acceptance that lacks memory cancels the running deep run, and nothing else.
  I5  At most one deep run exists.
  I6  A run that did not run, was cancelled or ran past its limit is neither a success nor a record of demand.
  I7  Who owns a run is decided by its scope and by waitpid, never by a record file: a supervisor that is killed
      neither blocks the others nor releases what its command still holds.
  I8  The CPU that the capped scopes that exist have been capped to never exceeds the budget together; a capped run waits for room
      and neither cancels another run nor is cancelled, and a request above the budget is refused at once.
  I9  A command never runs in a scope whose CPU cap differs from the one the capped run asked for, whether the run is nested or not.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
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
SLICES = {"acceptance": "agents.slice/agents-acceptance.slice", "deep": "agents.slice/agents-deep.slice",
          "capped": "agents.slice/agents-capped.slice"}
# The classes of runs that ask for memory alone.  The capped class asks for CPU too, so its tests name it and pass the CPU.
CLASSES = ("acceptance", "deep")
CAPPED = "capped"
# What the policy of the capped class lets the capped runs reserve together, in percent of one CPU, and the reason a run gives
# while it waits for that.
CPU_BUDGET = 400
CPU_REASON = "the CPU budget of the capped class is reserved"
# The outcome ids the policy carries to admission, as the real observation reports them (workload-package.nix owns them).
# The guest ones hold a run of either class, the pressure ones only a deep run and only at a failure; the Windows ones hold none.
GUEST_OUTCOMES = ["resource/workload/linux-memory", "resource/workload/cgroup-budget", "resource/workload/cpu"]
PRESSURE_OUTCOMES = ["resource/workload/memory-pressure", "resource/workload/io-pressure"]
WINDOWS_OUTCOMES = ["resource/workload/windows-memory", "resource/workload/wsl-cap"]
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
# Repeated observations while a run is waiting for a change in measured resources.
ROUNDS = 10
# The janitor of the fake systemd polls and removes a scope once EMPTY_POLLS (3) polls in a row find no member of it; this many
# polls would have removed a scope that has none many times over.
JANITOR_POLLS = 20
# How long the supervisor of a run whose command does not enter the scope that systemd-run made waits for it, as the policy's
# scopeEntrySeconds; the default of 10 s would make a test wait as long.  It leaves the fake time to make the scope first.
ENTRY_GRACE = 3
# What cgroup.events says of a scope that holds a process and of one that holds none.
HOLDING = "populated 1\nfrozen 0\n"
EMPTY = "populated 0\nfrozen 0\n"
# The reason a run gives while it waits for what the running acceptances may still claim.
HEADROOM = "Linux memory headroom is reserved"
# The helper the supervisor starts in the scope, started here by a parent that stays, so that a test can kill the parent while
# the helper is stopped.
ENTER_SCOPE = SOURCE.parent / "enter_scope.py"
HELPER_PARENT = ("import os,subprocess,sys,time\n"
                 "helper = subprocess.Popen([sys.executable, '-I', '-S', sys.argv[1], str(os.getpid()), '0', sys.executable, 'python', '-c', 'pass'])\n"
                 "print(helper.pid, flush=True)\n"
                 "time.sleep(600)")
# The readings the supervisor takes of a scope's cgroup, as the result and the journal name them.
READINGS = ("cpuSeconds", "cpuStallSeconds", "ioStallSeconds", "memoryStallSeconds")
# The target the tests give a run, and how far beyond it a test lets the run go on before its command changes the scope's
# files.  The reading at the target is taken when the target is reached; only a supervisor that is late by the whole margin
# would take it after the change.
TARGET_SECONDS = 1
TARGET_MARGIN = 1.5
# The supervisor samples the scope about once a second so that it has the readings when the scope is gone by the time the
# command has ended; a test that needs a sample of its files lets the run go on for this long, and the margin, after writing them.
SAMPLING_SECONDS = 1
# Run inside a scope: write the scope's own oom_score_adj and wait until released.
OOM_SCORE = [sys.executable, "-c",
             "import pathlib,sys,time;"
             "pathlib.Path(sys.argv[1]).write_text(pathlib.Path('/proc/self/oom_score_adj').read_text());"
             "\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.01)"]
# Stands in for `dotfiles-observe-workload [CGROUP]`: the snapshot, with the limits of every ancestor of the cgroup the caller
# asked about added (`destinationLimits`), as the real observation walks up from the cgroup it is given.  It also appends the
# pid of its caller to `<snapshot>.observed`, so that a test can count full observations rather than admission attempts.
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
# Run inside a scope: write the files of the cgroup that the supervisor reads (the fake scope has only cgroup.events), tell the test, wait
# until released, write the files again and end, or, with a fifth argument, go on until it is cancelled.  A descendant that
# ends only when it is terminated keeps the scope alive after the command has ended, so the supervisor reads the scope as it
# is when the command ends, whatever the load.
SCOPE_FILES = [sys.executable, "-c",
               "import json,os,pathlib,subprocess,sys,time\n"
               "marker, release = map(pathlib.Path, sys.argv[1:3])\n"
               "before, after = map(json.loads, sys.argv[3:5])\n"
               "scope = pathlib.Path(os.environ['DOTFILES_FAKE_SCOPE'])\n"
               "def write(files):\n"
               "    for name, text in files.items(): (scope / name).write_text(text)\n"
               "write(before)\n"
               "subprocess.Popen([sys.executable, '-c', 'import time\\ntime.sleep(600)'], start_new_session=True,\n"
               "                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
               "marker.touch()\n"
               "while not release.exists(): time.sleep(0.01)\n"
               "write(after)\n"
               "while len(sys.argv) > 5: time.sleep(1)"]


def pressure(some, full):
    """A pressure file as the kernel writes it: the `some` and the `full` line, each with its running total in microseconds."""
    return f"some avg10=0.00 avg60=0.00 avg300=0.00 total={some}\nfull avg10=0.00 avg60=0.00 avg300=0.00 total={full}\n"


def scope_files(cpu, cpu_stall, io_stall, memory_stall):
    """The files of a scope that hold the given microseconds; the line of a pressure file that is not read carries 1."""
    return {"cpu.stat": f"usage_usec {cpu}\nuser_usec 1\nsystem_usec 1\n",
            "cpu.pressure": pressure(cpu_stall, 1),
            "io.pressure": pressure(1, io_stall),
            "memory.pressure": pressure(1, memory_stall)}


EARLY_FILES = scope_files(1_500_000, 250_000, 100_000, 50_000)
EARLY_READINGS = {"cpuSeconds": 1.5, "cpuStallSeconds": 0.25, "ioStallSeconds": 0.1, "memoryStallSeconds": 0.05}
LATE_FILES = scope_files(2_500_000, 1_234_567, 2_000_000, 500_000)
LATE_READINGS = {"cpuSeconds": 2.5, "cpuStallSeconds": 1.235, "ioStallSeconds": 2.0, "memoryStallSeconds": 0.5}
NO_READINGS = dict.fromkeys(READINGS)
# The counters the supervisor reads of a scope's memory.stat and memory.events, as the result and the journal name them.  The scope
# is made for the run, so what it counts since it was made is what the run counts.
COUNTERS = ("memoryHighEvents", "anonRefaultPages", "fileRefaultPages", "swapInPages", "swapOutPages")
NO_COUNTERS = dict.fromkeys(COUNTERS)
# What `get` gives for a field that a record does not carry, so that a missing field fails an assertion by its value.
ABSENT = "absent from the record"
# A memory.high that is a limit and not `max`: the boundary of a cgroup that has one.
LIMIT = "33844867072"


def events(high):
    """A memory.events, or a memory.events.local, of a cgroup that has gone over its memory.high the given number of times."""
    return f"low 0\nhigh {high}\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n"


def counter_files(high, anon_refault, file_refault, swap_in, swap_out):
    """The memory.stat and memory.events of a scope that hold the given counts; the lines that are not read carry other numbers,
    among them the zero-page and the activation lines whose names begin like the ones that are read."""
    return {"memory.stat": (f"anon 1\nfile 1\nworkingset_refault_anon {anon_refault}\nworkingset_refault_file {file_refault}\n"
                            f"workingset_activate_anon 77\npswpin {swap_in}\npswpout {swap_out}\nswpin_zero 88\nswpout_zero 99\n"
                            "pgscan_direct 123\n"),
            "memory.events": events(high)}


EARLY_COUNTER_FILES = counter_files(3, 10, 20, 30, 40)
EARLY_COUNTERS = {"memoryHighEvents": 3, "anonRefaultPages": 10, "fileRefaultPages": 20, "swapInPages": 30, "swapOutPages": 40}
LATE_COUNTER_FILES = counter_files(900, 7_989_617, 4_023_041, 7_982_586, 9_184_089)
LATE_COUNTERS = {"memoryHighEvents": 900, "anonRefaultPages": 7_989_617, "fileRefaultPages": 4_023_041, "swapInPages": 7_982_586,
                 "swapOutPages": 9_184_089}


def ancestor_paths(root, klass):
    """The cgroups above a scope of the class, nearest first and down to the one just below the root, by unit name."""
    uid = os.getuid()
    parts = (root / "user.slice" / f"user-{uid}.slice" / f"user@{uid}.service" / SLICES[klass]).relative_to(root).parts
    return {parts[index]: root.joinpath(*parts[:index + 1]) for index in reversed(range(len(parts)))}


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



def process_state(pid):
    """The state letter /proc gives the process, or None when it is gone; Z is a process that has ended and is not collected yet."""
    try:
        data = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    return data[data.rindex(")") + 2]


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
            # The message of an outcome is its id, so that the reason a run waits for names what held it back.
            "outcomes": [{"id": identifier, "status": "pass", "message": identifier}
                         for identifier in (*GUEST_OUTCOMES, *PRESSURE_OUTCOMES, *WINDOWS_OUTCOMES)],
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
        self.capped_policy = self.write_policy(CAPPED)
        # A directory to run in: the demand is keyed by the caller, not by what the working directory holds.
        self.repo = self.root / "repo"
        self.repo.mkdir()

    def write_policy(self, klass, name=None, fail=False, gate=None, strand=None, abort=False, refuse=False, cpu=None, **changes):
        """Write a policy file for a class: the real fields, with the fakes standing in for systemd and the cgroup tree.

        The fake systemd-run refuses to create the scope with `fail`, answers once `gate` exists, makes the scope and moves in
        once `strand` exists, and ends with status 1 after it made the scope with `abort`; the fake systemctl refuses to stop
        with `refuse`.  It leaves `CPUQuota` unapplied with `cpu="ignore"` and gives the scope no cpu.max with `cpu="absent"`.
        The policy of the capped class carries the budget CPU_BUDGET unless `changes` says otherwise.
        """
        slow = ["--gate", str(gate)] if gate else []
        stranded = ["--strand", str(strand)] if strand else []
        policy = {
            "class": klass,
            "journalSocket": str(self.root / "journal.sock"),
            "observation": [*OBSERVE, str(self.snapshot)],
            "runtimeDirectory": str(self.root / "run"),
            "memoryPercent": MEMORY_PERCENT,
            "maximumObservationAgeSeconds": OBSERVATION_AGE,
            "systemdRun": [sys.executable, str(FAKE), "--cgroup-root", str(self.cgroup), *(["--fail"] if fail else []), *slow,
                           *stranded, *(["--abort"] if abort else []), *(["--cpu", cpu] if cpu else []), "run"],
            "systemctl": [sys.executable, str(FAKE), "--cgroup-root", str(self.cgroup), *(["--refuse"] if refuse else []), "ctl"],
            "cgroupRoot": str(self.cgroup),
            "slices": SLICES,
            "guestOutcomeIds": GUEST_OUTCOMES,
            "pressureOutcomeIds": PRESSURE_OUTCOMES,
            **({"cpuBudgetPercent": CPU_BUDGET} if klass == CAPPED else {}),
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
            "--resource-policy", str(policy or {"acceptance": self.policy, "deep": self.deep_policy, CAPPED: self.capped_policy}[klass]),
            "--resource-wait-until", str(time.time() + wait),
            "--resource-run-seconds", str(run),
            *arguments,
            "--", *worker,
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.environment(), cwd=cwd)
        self.children.append(process)
        # Whatever the test did, a command that is still waiting for its release must be able to end.
        self.addCleanup(release.touch)
        return process, marker, release

    def cap(self, cpu, memory=100 * MIB):
        """The arguments of a capped run: its CPU cap and an explicit memory demand small enough that only the CPU is under test."""
        return ["--resource-cpu", str(cpu), "--resource-memory", str(memory)]

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

    def run_scope_files(self, name, before, after, hold=0.0, arguments=(), stay=False, **options):
        """Run a command that writes `before` into its scope, goes on for `hold` seconds, writes `after` and ends.

        With `stay` the command goes on after writing `after` until it is cancelled.
        Returns its status, its stderr and its result record.  Sleeping only ever makes the run longer.
        """
        marker, release = self.root / name, self.root / f"{name}.release"
        command = [*SCOPE_FILES, str(marker), str(release), json.dumps(before), json.dumps(after), *(["stay"] if stay else [])]
        process, _, _ = self.start(name, command=command, arguments=arguments, cwd=self.repo, **options)
        self.wait_for(marker.exists, process)
        time.sleep(hold)
        release.touch()
        _, error = process.communicate(timeout=HANG_SECONDS)
        return process.returncode, error, json.loads((self.root / f"{name}.result").read_text())

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

    def stops(self):
        """The units the supervisors asked the fake systemd to stop, in the order they asked."""
        return [call[-1] for call in self.calls("ctl") if "stop" in call]

    def units_asked_for(self):
        """The units of the scopes that supervisors asked the fake systemd to create, in the order they asked."""
        return [argument.removeprefix("--unit=") for call in self.calls("run") for argument in call if argument.startswith("--unit=")]

    def asked_for(self):
        """The unit of the one scope that a supervisor asked the fake systemd to create."""
        (unit,) = self.units_asked_for()
        return unit

    def leave_scope(self, klass, name, events, cpu=None):
        """Leave a scope below the class's slice as the manager can leave one: its reservation written, no janitor to remove it,
        `events` as its cgroup.events, or no such file when `events` is None, and `cpu` as its cpu.max, or no such file when None."""
        uid = os.getuid()
        scope = self.cgroup / "user.slice" / f"user-{uid}.slice" / f"user@{uid}.service" / SLICES[klass] / name
        scope.mkdir(parents=True)
        (scope / ("memory.high" if klass == "deep" else "memory.low")).write_text(f"{9 * GIB}\n")
        if events is not None:
            (scope / "cgroup.events").write_text(events)
        if cpu is not None:
            (scope / "cpu.max").write_text(cpu)
        return scope

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

    def outcome(self, identifier, status):
        """Observe the outcome of the given id with the given status."""
        envelope = json.loads(self.snapshot.read_text())
        (row,) = [row for row in envelope["outcomes"] if row["id"] == identifier]
        row["status"] = status
        self.snapshot.write_text(json.dumps(envelope))

    def without_outcomes(self, *identifiers):
        """Observe without the outcomes of the given ids."""
        envelope = json.loads(self.snapshot.read_text())
        envelope["outcomes"] = [row for row in envelope["outcomes"] if row["id"] not in identifiers]
        self.snapshot.write_text(json.dumps(envelope))

    def judged(self, process):
        """How many full observations this workload has requested."""
        log = Path(f"{self.snapshot}.observed")
        return log.read_text().split().count(str(process.pid)) if log.exists() else 0

    def keeps_waiting(self, process):
        """Wait for ROUNDS more observations of the resource the run is waiting for."""
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

    def windows_unreadable(self, state):
        """Observe the Windows snapshot as the observation reports it when it cannot use it, `unavailable` or `stale`."""
        for identifier in WINDOWS_OUTCOMES:
            self.outcome(identifier, "fail")
        self.observe(windowsCommitHeadroomBytes=None, windowsPhysicalAvailableBytes=None, windowsPhysicalHeadroomBytes=None,
                     windows={"state": state})

    def windows_commit_at_failure(self):
        """Observe the Windows commit at its failure level, so that no commit headroom is left."""
        self.outcome(WINDOWS_OUTCOMES[0], "fail")
        self.observe(windowsCommitHeadroomBytes=0)

    def windows_reserve_exhausted(self):
        """Observe the Windows physical memory below its reserve, so that no headroom is left."""
        self.observe(windowsPhysicalAvailableBytes=5 * GIB, windowsPhysicalHeadroomBytes=0)

    def assert_enters_at_once(self, label):
        """A run of either class is admitted at its first judgement, so that it has nothing to wait for."""
        for klass in CLASSES:
            with self.subTest(case=label, klass=klass):
                status, _, _ = self.run_command(f"{klass}-{label}", key=None, klass=klass)
                self.assertEqual(status, 0)
                (_, record), = self.measurements()
                self.assertEqual(record["waitReasons"], [])

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
        self.assertEqual(self.waiting("second", second), "Linux memory headroom is reserved")
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
        self.assertEqual(self.judged(deep), 1)  # The explicit demand must be checked even while the slot is occupied.
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

    def test_pressure_never_holds_an_acceptance(self):
        """People wait for an acceptance and holding it for pressure does not lessen what else runs, so it enters at a failure too."""
        for identifier in PRESSURE_OUTCOMES:
            for level in ("warn", "fail"):
                with self.subTest(outcome=identifier, level=level):
                    self.outcome(identifier, level)
                    status, _, _ = self.run_command(f"acceptance-{identifier.rsplit('/', 1)[1]}-{level}", key=None)
                    self.assertEqual(status, 0)
                    (_, record), = self.measurements()
                    self.assertEqual(record["waitReasons"], [])
            self.outcome(identifier, "pass")

    def test_i3_a_deep_run_is_held_by_pressure_only_at_a_failure(self):
        """A deep run enters at a pressure warning, waits for the pressure while it is at a failure and enters when it is back at a warning."""
        for identifier in PRESSURE_OUTCOMES:
            name = identifier.rsplit("/", 1)[1]
            self.outcome(identifier, "warn")
            status, _, _ = self.run_command(f"deep-{name}-warning", key=None, klass="deep")
            self.assertEqual(status, 0)
            self.outcome(identifier, "fail")
            process, started, release = self.start(f"deep-{name}-failure", klass="deep")
            self.assertEqual(self.waiting(f"deep-{name}-failure", process), identifier)
            self.keeps_waiting(process)
            self.assertFalse(started.exists())
            # The run that waited is the one that enters, so what held it back was the pressure and nothing else.
            self.outcome(identifier, "warn")
            self.wait_for(started.exists, process)
            release.touch()
            self.assertEqual(self.finish(process), 0)
            self.outcome(identifier, "pass")

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
        second, second_started, second_release = self.start("second", klass="deep")
        self.assertEqual(self.waiting("second", second), "another deep verification is running")
        self.assertEqual(self.judged(second), 0)
        self.assertFalse(second_started.exists())
        self.observe(hostMemoryHeadroomBytes=0)
        first_release.touch()
        self.assertEqual(self.finish(first), 0)
        self.wait_for(lambda: json.loads((self.root / "second.result").read_text()).get("reason") == HEADROOM, second)
        self.assertFalse(second_started.exists())
        self.observe(hostMemoryHeadroomBytes=10 * GIB)
        self.wait_for(second_started.exists, second)
        second_release.touch()
        self.assertEqual(self.finish(second), 0)

    # I6: what is not a success and not a record

    def test_i6_the_wait_limit_returns_75_and_nothing_is_started(self):
        """A run that could not enter within the wait limit is reported unstarted, with its wait, and records nothing."""
        self.outcome(GUEST_OUTCOMES[0], "fail")
        process, started, _ = self.start("never", wait=WAIT_LIMIT, arguments=["--resource-key", KEY], cwd=self.repo)
        # It is judged and found not to fit before the limit runs out; the limit then ends the wait.
        self.waiting("never", process)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 75)
        self.assertLessEqual(self.judged(process), 1 + 2 * WAIT_LIMIT, "the observer's exit triggered an immediate retry")
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

    def test_i6_a_guest_outcome_that_does_not_hold_defers_without_starting(self):
        """A run of either class waits, with nothing started, rather than failing when what the guest reports cannot be relied on."""
        for klass in CLASSES:
            for identifier in GUEST_OUTCOMES:
                name = f"{klass}-{identifier.rsplit('/', 1)[1]}"
                with self.subTest(klass=klass, outcome=identifier):
                    self.outcome(identifier, "fail")
                    reason, _ = self.held_back(name, klass=klass)
                    self.assertEqual(reason, identifier)
                    result = json.loads((self.root / f"{name}.result").read_text())
                    self.assertTrue(result["deferred"])
                    self.assertFalse(result["spawned"])
                    self.assertEqual(self.scopes(klass), [])
                    self.outcome(identifier, "pass")

    def test_an_observation_without_an_outcome_that_admission_looks_at_is_incomplete(self):
        """A missing guest outcome, or for a deep run a missing pressure outcome, is no basis for an admission; a Windows one is no concern of it."""
        self.without_outcomes(*WINDOWS_OUTCOMES, *PRESSURE_OUTCOMES)
        status, _, _ = self.run_command("acceptance-without-pressure", key=None)
        self.assertEqual(status, 0)
        reason, _ = self.held_back("deep-without-pressure", klass="deep")
        self.assertEqual(reason, "resource observation is incomplete")
        self.without_outcomes(GUEST_OUTCOMES[2])
        reason, _ = self.held_back("acceptance-without-cpu")
        self.assertEqual(reason, "resource observation is incomplete")

    def test_a_policy_that_names_no_guest_outcome_is_refused_with_70(self):
        """Without a guest outcome admission would be blind to the guest, so the policy is refused and nothing is started."""
        blind = self.write_policy("acceptance", name="blind.json", guestOutcomeIds=[])
        process, started, _ = self.start("blind-policy", policy=blind)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 70)
        self.assertIn("guestOutcomeIds", error)
        self.assertFalse(started.exists())

    def test_i6_a_stale_observation_never_authorizes_execution(self):
        """A stale successful envelope cannot admit a workload."""
        self.observe(observedAt=time.time() - OBSERVATION_AGE - 1)
        reason, _ = self.held_back("stale")
        self.assertEqual(reason, "resource observation is stale")

    def test_i6_an_observation_that_a_busy_machine_answers_slowly_still_admits(self):
        """An answer that takes seconds is used as long as it is no older than the policy lets an observation be."""
        slowly = [sys.executable, "-c",
                  "import subprocess,sys,time; time.sleep(2.5); raise SystemExit(subprocess.run(sys.argv[1:]).returncode)"]
        policy = self.write_policy("acceptance", name="policy-slow-observation.json",
                                   observation=[*slowly, *OBSERVE, str(self.snapshot)])
        status, error, _ = self.run_command("slowly-observed", policy=policy)
        self.assertEqual(status, 0, error)
        self.assertNotIn("resource observation unavailable", error)

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
        self.assertEqual(self.judged(second), 1)
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

    # A scope that holds no process: the run that made it stops it, and a decision neither counts it nor leaves it

    def stranded(self, name, wait=2 * HANG_SECONDS, gate=None, **changes):
        """Start a run whose manager makes the scope but moves systemd-run into it only once `gate` exists, which is never unless
        the test makes it, and return the run and its command's marker once the scope is there.

        The command does not enter the scope, so the run ends by its wait limit, by a cancellation or by the grace it allows.
        """
        policy = self.write_policy("acceptance", name=f"{name}.json", strand=gate or self.root / f"{name}.gate", **changes)
        process, started, _ = self.start(name, wait=wait, policy=policy)
        self.wait_for(lambda: self.scopes("acceptance"), process)
        return process, started

    def assert_stopped_and_gone(self, started):
        """The command never ran, the one scope that was asked for was stopped once, and nothing of it is left."""
        self.assertFalse(started.exists())
        self.assertEqual(self.stops(), [self.asked_for()])
        self.assertEqual(self.scopes("acceptance"), [])

    def test_a_run_that_reaches_its_wait_limit_before_it_enters_its_scope_stops_the_scope(self):
        """A scope that never held a process is not removed by the manager, so the run that gave up has to stop it."""
        process, started = self.stranded("limit", wait=WAIT_LIMIT)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 75, error)
        self.assertFalse(json.loads((self.root / "limit.result").read_text())["spawned"])
        self.assertNotIn("cannot stop", error)
        self.assert_stopped_and_gone(started)

    def test_a_run_that_is_cancelled_before_it_enters_its_scope_stops_the_scope(self):
        """A cancellation ends the wait for the scope as the limit does, and leaves the scope in the same way."""
        process, started = self.stranded("cancel")
        process.send_signal(signal.SIGTERM)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 143, error)
        self.assert_stopped_and_gone(started)

    def test_a_run_that_does_not_enter_its_scope_within_the_grace_stops_it_tries_again_and_ends_75(self):
        """The command never ran, so the delay that kept it out is no failure: each scope is stopped, the entry is tried again
        until the wait limit, and the run is reported as not executed, with the reason."""
        process, started = self.stranded("grace", wait=4 * ENTRY_GRACE, scopeEntrySeconds=ENTRY_GRACE)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 75, error)
        self.assertNotIn("cannot stop", error)
        self.assertFalse(started.exists())
        units = self.units_asked_for()
        self.assertGreaterEqual(len(units), 2)
        self.assertEqual(self.stops(), units)
        self.assertEqual(self.scopes("acceptance"), [])
        (_, record), = self.measurements()
        self.assertEqual((record["status"], record["admitted"]), (75, False))
        self.assertEqual(record["waitReasons"], [f"the command did not enter its scope within {ENTRY_GRACE}s"])

    def test_a_command_that_enters_its_scope_on_a_later_attempt_runs_once_and_the_first_scope_is_gone(self):
        """The grace costs a retry and not the run: the scope that was given up is stopped, and the next one is entered."""
        gate = self.root / "later.gate"
        process, started = self.stranded("later", gate=gate, scopeEntrySeconds=ENTRY_GRACE)
        # The first attempt is given up after the grace, and the gate is open for the next.
        self.wait_for(lambda: self.stops(), process)
        gate.touch()
        self.wait_for(started.exists, process)
        (self.root / "later.release").touch()
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 0, error)
        first, _ = self.units_asked_for()
        self.assertEqual(self.stops(), [first])
        self.assertTrue(json.loads((self.root / "later.result").read_text())["spawned"])
        (_, record), = self.measurements()
        self.assertEqual((record["status"], record["admitted"]), (0, True))
        self.assertEqual(record["waitReasons"], [f"the command did not enter its scope within {ENTRY_GRACE}s"])

    def test_a_run_whose_systemd_run_ends_after_making_the_scope_stops_the_scope(self):
        """The manager made the scope and systemd-run failed afterwards: the status is the failure to create, and the scope goes."""
        aborting = self.write_policy("acceptance", name="aborting.json", abort=True)
        process, started, _ = self.start("aborting", policy=aborting)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 70, error)
        self.assertIn("ended with status 1", error)
        self.assert_stopped_and_gone(started)

    def test_a_run_whose_systemd_run_made_no_scope_has_nothing_to_stop_and_says_nothing_of_it(self):
        """The manager has no such unit, which is not a failure to stop: the one line is the failure to create the scope."""
        broken = self.write_policy("acceptance", name="broken-stop.json", fail=True)
        process, started, _ = self.start("broken-stop", policy=broken)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 70, error)
        self.assertIn("cannot create the scope", error)
        self.assertNotIn("cannot stop", error)
        self.assert_stopped_and_gone(started)

    def test_a_scope_that_cannot_be_stopped_is_one_diagnosis_and_the_status_stays(self):
        """The run still ends as its wait limit makes it end, and its stderr names the scope it could not stop once."""
        process, _ = self.stranded("refused", wait=WAIT_LIMIT, refuse=True)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 75, error)
        unit = self.asked_for()
        self.assertEqual(self.stops(), [unit])
        self.assertEqual(error.count(f"cannot stop {unit}"), 1)

    def test_an_empty_scope_reserves_nothing_and_the_same_scope_with_a_process_does(self):
        """cgroup.events tells a scope that holds nothing from one whose reservation may still be used."""
        left = self.leave_scope("acceptance", "dotfiles-workload-acceptance-1-left.scope", HOLDING)
        arguments = ["--resource-memory", str(9 * GIB)]
        # Nine GiB beside the nine GiB the scope reserves does not fit into ten.
        reason, _ = self.held_back("populated", arguments=arguments)
        self.assertEqual(reason, HEADROOM)
        self.assertEqual(self.stops(), [])
        self.measurements()
        (left / "cgroup.events").write_text(EMPTY)
        status, _, _ = self.run_command("empty", key=None, arguments=arguments)
        self.assertEqual(status, 0)
        (_, record), = self.measurements()
        self.assertEqual(record["waitReasons"], [])
        self.assertEqual(self.stops(), [left.name])
        self.assertFalse(left.exists())

    def test_an_empty_deep_scope_does_not_occupy_the_deep_slot(self):
        """A deep run waits for the deep scope that holds a process and not for one that holds none."""
        left = self.leave_scope("deep", "dotfiles-workload-deep-1-left.scope", HOLDING)
        reason, _ = self.held_back("deep-populated", klass="deep")
        self.assertEqual(reason, "another deep verification is running")
        self.measurements()
        (left / "cgroup.events").write_text(EMPTY)
        status, _, _ = self.run_command("deep-empty", key=None, klass="deep")
        self.assertEqual(status, 0)
        # It was not held back even for one judgement: stopping the scope would have freed the slot for the next.
        (_, record), = self.measurements()
        self.assertEqual(record["waitReasons"], [])
        self.assertEqual(self.stops(), [left.name])

    def test_an_acceptance_without_room_neither_cancels_nor_marks_a_deep_scope_that_holds_nothing(self):
        """It is no run to cancel, and it may be one that has just ended: a cancellation record would report the run 143."""
        left = self.leave_scope("deep", "dotfiles-workload-deep-1-left.scope", EMPTY)
        self.observe(hostMemoryHeadroomBytes=GIB, memoryHeadroomBytes=GIB)
        acceptance, started, release = self.start("acceptance", arguments=["--resource-memory", str(2 * GIB)])
        self.waiting("acceptance", acceptance)
        self.keeps_waiting(acceptance)
        self.assertEqual(self.stops(), [left.name])
        self.assertEqual(sorted(path.name for path in (self.root / "run").iterdir()), ["acceptance.waiting", "registry.lock"])
        self.observe(hostMemoryHeadroomBytes=10 * GIB, memoryHeadroomBytes=10 * GIB)
        self.wait_for(started.exists, acceptance)
        release.touch()
        self.assertEqual(self.finish(acceptance), 0)

    def test_a_scope_that_does_not_say_whether_it_holds_a_process_is_counted(self):
        """What cannot be read is not taken for empty: the reservation stays held and nothing is stopped."""
        for case in ("no-file", "a-directory", "no-populated-line"):
            with self.subTest(case=case):
                left = self.leave_scope("acceptance", f"dotfiles-workload-acceptance-1-{case}.scope",
                                        "frozen 0\n" if case == "no-populated-line" else None)
                if case == "a-directory":
                    (left / "cgroup.events").mkdir()
                reason, _ = self.held_back(f"unreadable-{case}", arguments=["--resource-memory", str(9 * GIB)])
                self.assertEqual(reason, HEADROOM)
                self.assertEqual(self.stops(), [])
                shutil.rmtree(left)

    def test_a_decision_stops_the_scope_that_holds_nothing_and_no_scope_that_holds_a_process(self):
        """A run beside a running one and a scope that holds nothing stops that scope, and waits for the running one only."""
        holder, held, holder_release = self.start("holder", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(held.exists, holder)
        (holder_scope,) = self.scopes("acceptance")
        left = self.leave_scope("acceptance", "dotfiles-workload-acceptance-1-left.scope", EMPTY)
        large, large_started, large_release = self.start("large", arguments=["--resource-memory", str(9 * GIB)])
        self.assertEqual(self.waiting("large", large), HEADROOM)
        self.keeps_waiting(large)
        self.assertEqual(self.stops(), [left.name])
        self.assertFalse(left.exists())
        self.assertTrue(holder_scope.exists())
        holder_release.touch()
        self.assertEqual(self.finish(holder), 0)
        self.wait_for(large_started.exists, large)
        large_release.touch()
        self.assertEqual(self.finish(large), 0)

    def test_a_refused_stop_of_an_empty_scope_is_asked_once_and_costs_one_line_and_the_decision_goes_on(self):
        """However many judgements the run makes while it waits, it asks for the stop of the scope once, and it enters when it fits."""
        holder, held, holder_release = self.start("holder", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(held.exists, holder)
        left = self.leave_scope("acceptance", "dotfiles-workload-acceptance-1-left.scope", EMPTY)
        refusing = self.write_policy("acceptance", name="policy-refusing-stop.json", refuse=True)
        large, large_started, large_release = self.start("large", policy=refusing, arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("large", large)
        self.keeps_waiting(large)
        holder_release.touch()
        self.assertEqual(self.finish(holder), 0)
        self.wait_for(large_started.exists, large)
        large_release.touch()
        _, error = large.communicate(timeout=HANG_SECONDS)
        self.assertEqual(large.returncode, 0, error)
        self.assertEqual(self.stops(), [left.name])
        self.assertEqual(error.count(f"cannot stop {left.name}"), 1)

    def test_a_run_between_the_making_of_its_scope_and_its_entry_is_not_stopped_by_a_run_that_judges(self):
        """The scope exists and holds nothing yet, but the run that is making it holds the lock the judgement needs."""
        gate = self.root / "attach.gate"
        creating = self.write_policy("acceptance", name="creating.json", strand=gate)
        first, first_started, first_release = self.start("creating", policy=creating, arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(lambda: self.scopes("acceptance"), first)
        second, second_started, second_release = self.start("judging", arguments=["--resource-memory", str(9 * GIB)])
        # Both acceptances must have registered before the attaching one lets go of the registry.
        registry = str(self.root / "run" / "registry.lock")
        self.wait_for(lambda: any(os.path.realpath(fd) == registry for fd in Path(f"/proc/{second.pid}/fd").iterdir()), second)
        self.assertEqual(self.judged(second), 0)
        self.assertEqual(self.stops(), [])
        gate.touch()
        self.wait_for(first_started.exists, first)
        self.assertEqual(self.waiting("judging", second), HEADROOM)
        self.assertEqual(self.stops(), [])
        first_release.touch()
        self.assertEqual(self.finish(first), 0)
        self.wait_for(second_started.exists, second)
        second_release.touch()
        self.assertEqual(self.finish(second), 0)

    def end_scope_members(self):
        """End what a scope of the fake cgroup tree still holds, so that a helper that failed to end does not outlive its test."""
        for procs in (self.cgroup / "user.slice").rglob("cgroup.procs"):
            try:
                os.kill(int(procs.read_text()), signal.SIGKILL)
            except (OSError, ValueError):
                pass

    def test_a_supervisor_killed_before_its_command_entered_the_scope_leaves_no_scope_and_runs_nothing(self):
        """Nobody would resume the helper, so it must not wait for a supervisor that is gone: it would hold the scope for good."""
        gate = self.root / "orphaned.gate"
        first, started = self.stranded("orphaned", gate=gate)
        self.addCleanup(self.end_scope_members)
        first.kill()
        first.wait()
        first.stdout.close()
        first.stderr.close()
        gate.touch()
        # The helper finds that its supervisor is gone and ends; with nothing left in it the scope is removed.
        self.wait_for(lambda: not self.scopes("acceptance"))
        self.assertFalse(started.exists())

    def test_a_helper_that_waits_to_be_resumed_ends_with_its_supervisor(self):
        """The helper stops itself in the scope; the supervisor that is killed there cannot resume it, and the death signal ends it."""
        parent = subprocess.Popen([sys.executable, "-c", HELPER_PARENT, str(ENTER_SCOPE)], stdout=subprocess.PIPE, text=True)
        self.addCleanup(parent.stdout.close)
        self.addCleanup(parent.kill)
        helper = int(parent.stdout.readline())
        self.addCleanup(lambda: os.kill(helper, signal.SIGKILL) if process_state(helper) not in (None, "Z") else None)
        self.wait_for(lambda: process_state(helper) == "T")
        parent.kill()
        parent.wait()
        self.wait_for(lambda: process_state(helper) in (None, "Z"))

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

    # The Windows side of the observation is a diagnosis: no value of it holds a run of either class back

    def test_a_run_of_either_class_enters_while_the_windows_snapshot_is_missing_or_stale(self):
        """Without a usable snapshot the observation fails its Windows outcomes and has no value of them, and admission looks at the guest only."""
        for state in ("unavailable", "stale"):
            self.windows_unreadable(state)
            self.assert_enters_at_once(f"snapshot-{state}")

    def test_a_run_of_either_class_enters_while_the_windows_commit_is_at_failure(self):
        """The commit headroom is none and its outcome fails, and the guest has the room."""
        self.windows_commit_at_failure()
        self.assert_enters_at_once("commit-failure")

    def test_a_run_of_either_class_enters_while_the_windows_reserve_is_exhausted(self):
        """A deep run no longer waits for the Windows physical memory either."""
        self.windows_reserve_exhausted()
        self.assert_enters_at_once("reserve-exhausted")

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

    def assert_reported(self, result, readings, at_target, target):
        """The result and the journal line of the one run say the same: its readings, its target and its reading at the target."""
        (_, record), = self.measurements()
        for report in (result, record):
            self.assertEqual({field: report[field] for field in READINGS}, readings)
            self.assertEqual((report["targetSeconds"], report["atTarget"]), (target, at_target))
        self.assertEqual(record["runSeconds"], result["runSeconds"])

    def test_a_run_that_ends_before_its_target_reports_the_scope_at_its_end_and_nothing_at_the_target(self):
        """The scope's CPU time and stalls are those it has when the command ends; the target was not reached, so there is no reading of it."""
        status, _, result = self.run_scope_files("before-target", EARLY_FILES, LATE_FILES, arguments=["--resource-target-seconds", "600"])
        self.assertEqual(status, 0)
        self.assert_reported(result, LATE_READINGS, None, 600)

    def test_a_run_still_running_at_its_target_reports_the_scope_as_it_was_then_and_is_not_cancelled(self):
        """The reading at the target is the scope's files at that moment, before the command changed them; the run goes on to its own end."""
        status, _, result = self.run_scope_files("past-target", EARLY_FILES, LATE_FILES, hold=TARGET_SECONDS + TARGET_MARGIN,
                                                 arguments=["--resource-target-seconds", str(TARGET_SECONDS)])
        self.assertEqual(status, 0)
        self.assert_reported(result, LATE_READINGS, EARLY_READINGS, TARGET_SECONDS)
        self.assertGreaterEqual(result["runSeconds"], TARGET_SECONDS + TARGET_MARGIN)

    def test_a_run_cancelled_at_its_limit_reports_the_scope_at_the_target_and_at_the_end_and_keeps_124(self):
        """The limit ends the run as before; the scope was read when the target was reached and again when the limit stopped the command."""
        # The limit lies beyond the moment the command changes the files, by the margin again.
        status, _, result = self.run_scope_files("past-limit", EARLY_FILES, LATE_FILES, hold=TARGET_SECONDS + TARGET_MARGIN, stay=True,
                                                 run=TARGET_SECONDS + 2 * TARGET_MARGIN,
                                                 arguments=["--resource-target-seconds", str(TARGET_SECONDS)])
        self.assertEqual(status, 124)
        self.assertTrue(result["cancelled"])
        self.assert_reported(result, LATE_READINGS, EARLY_READINGS, TARGET_SECONDS)
        self.assertGreaterEqual(result["runSeconds"], TARGET_SECONDS + 2 * TARGET_MARGIN)

    def test_a_run_cancelled_from_outside_reports_the_scope_it_had_and_keeps_143(self):
        """The acceptance that needs the memory stops the deep run; the deep run still reports the scope's readings."""
        marker, release = self.root / "deep", self.root / "deep.release"
        deep, deep_started, _ = self.start("deep", klass="deep", cwd=self.repo,
                                           command=[*SCOPE_FILES, str(marker), str(release), json.dumps(EARLY_FILES), "{}", "stay"],
                                           arguments=["--resource-memory", str(4 * GIB)])
        self.wait_for(deep_started.exists, deep)
        # The sample of the scope's files is taken before the scope goes: the stop ends every process of the scope at once.
        time.sleep(SAMPLING_SECONDS + TARGET_MARGIN)
        self.observe(hostMemoryHeadroomBytes=GIB, memoryHeadroomBytes=GIB)
        acceptance, started, acceptance_release = self.start("acceptance", arguments=["--resource-memory", str(2 * GIB)])
        self.wait_for(lambda: deep.poll() is not None, acceptance)
        self.observe(hostMemoryHeadroomBytes=10 * GIB, memoryHeadroomBytes=10 * GIB)
        self.wait_for(started.exists, acceptance)
        result = json.loads((self.root / "deep.result").read_text())
        self.assertEqual((deep.returncode, result["status"], result["cancelled"]), (143, 143, True))
        (_, record), = [entry for entry in self.measurements() if entry[1]["class"] == "deep"]
        for report in (result, record):
            self.assertEqual({field: report[field] for field in READINGS}, EARLY_READINGS)
        acceptance_release.touch()
        self.assertEqual(self.finish(acceptance), 0)

    def test_a_run_without_a_target_reports_its_end_readings_and_no_target(self):
        """Every scoped run reports the scope; a target is only recorded when one was given."""
        status, _, result = self.run_scope_files("no-target", EARLY_FILES, LATE_FILES)
        self.assertEqual(status, 0)
        self.assert_reported(result, LATE_READINGS, None, None)

    def test_scope_files_that_cannot_be_read_give_null_and_keep_the_exit_status(self):
        """A scope without the files, or with files the supervisor cannot parse, costs the fields concerned and not the command's status."""
        status, _, result = self.run_command("no-files", status=3)
        self.assertEqual(status, 3)
        self.assert_reported(result, NO_READINGS, None, None)
        broken = {"cpu.stat": "usage_usec 4000000\n", "cpu.pressure": "some avg10=0.00\n", "io.pressure": "full avg10=0.00 total=x\n",
                  "memory.pressure": "no totals at all\n"}
        status, _, result = self.run_scope_files("broken-files", broken, broken, arguments=["--resource-target-seconds", "600"])
        self.assertEqual(status, 0)
        self.assert_reported(result, {**NO_READINGS, "cpuSeconds": 4.0}, None, 600)

    def test_a_run_still_running_at_its_target_with_unreadable_scope_files_has_a_reading_of_nulls(self):
        """The target was reached, so there is a reading of it; none of its fields could be read."""
        status, _, result = self.run_scope_files("unreadable-at-target", {}, {}, hold=TARGET_SECONDS + TARGET_MARGIN,
                                                 arguments=["--resource-target-seconds", str(TARGET_SECONDS)])
        self.assertEqual(status, 0)
        self.assert_reported(result, NO_READINGS, NO_READINGS, TARGET_SECONDS)

    def test_a_nested_run_has_no_scope_to_read_and_so_reads_nothing(self):
        """The inner supervisor runs in the outer run's scope without one of its own, so every reading of its line is null."""
        self.assertEqual(self.nested("deep", "acceptance", "--resource-target-seconds", "600"), 0)
        (nested,) = [record for _, record in self.measurements() if record["nested"]]
        self.assertEqual({field: nested[field] for field in READINGS}, NO_READINGS)
        self.assertEqual((nested["targetSeconds"], nested["atTarget"]), (600, None))

    # The reclaim counters of the scope and the boundaries above it

    def reports(self, result):
        """The result and the journal line of the one run, which say the same."""
        (_, record), = self.measurements()
        return result, record

    def lay_boundaries(self, klass, boundaries):
        """Lay the cgroups above the class's scopes before a run: for each named unit its memory.high text and the count in its
        memory.events.local, no file for a value that is None.  Returns the path of every cgroup above a scope, by unit name."""
        paths = ancestor_paths(self.cgroup, klass)
        for name, (limit, count) in boundaries.items():
            paths[name].mkdir(parents=True, exist_ok=True)
            if limit is not None:
                (paths[name] / "memory.high").write_text(limit + "\n")
            if count is not None:
                (paths[name] / "memory.events.local").write_text(events(count))
        return paths

    def test_a_run_reports_the_reclaim_counters_its_scope_has_when_the_command_ends(self):
        """The scope's own counts when the command ends are the run's; the cgroups above it carry other, larger counts that are no part of them."""
        for path in ancestor_paths(self.cgroup, "acceptance").values():
            path.mkdir(parents=True, exist_ok=True)
            (path / "memory.stat").write_text(counter_files(7, 7_000_000, 7_000_000, 7_000_000, 7_000_000)["memory.stat"])
            (path / "memory.events").write_text(events(777))
        status, _, result = self.run_scope_files("counters", EARLY_COUNTER_FILES, LATE_COUNTER_FILES)
        self.assertEqual(status, 0)
        for report in self.reports(result):
            self.assertEqual({field: report.get(field, ABSENT) for field in COUNTERS}, LATE_COUNTERS)

    def test_a_run_cancelled_from_outside_reports_the_reclaim_counters_the_scope_had(self):
        """The acceptance that needs the memory stops the deep run, and its scope is gone at once; the counters are those of the last sample."""
        marker, release = self.root / "deep", self.root / "deep.release"
        deep, deep_started, _ = self.start("deep", klass="deep", cwd=self.repo,
                                           command=[*SCOPE_FILES, str(marker), str(release), json.dumps(EARLY_COUNTER_FILES), "{}", "stay"],
                                           arguments=["--resource-memory", str(4 * GIB)])
        self.wait_for(deep_started.exists, deep)
        time.sleep(SAMPLING_SECONDS + TARGET_MARGIN)
        self.observe(hostMemoryHeadroomBytes=GIB, memoryHeadroomBytes=GIB)
        acceptance, started, acceptance_release = self.start("acceptance", arguments=["--resource-memory", str(2 * GIB)])
        self.wait_for(lambda: deep.poll() is not None, acceptance)
        self.observe(hostMemoryHeadroomBytes=10 * GIB, memoryHeadroomBytes=10 * GIB)
        self.wait_for(started.exists, acceptance)
        result = json.loads((self.root / "deep.result").read_text())
        self.assertEqual((deep.returncode, result["status"], result["cancelled"]), (143, 143, True))
        (_, record), = [entry for entry in self.measurements() if entry[1]["class"] == "deep"]
        for report in (result, record):
            self.assertEqual({field: report.get(field, ABSENT) for field in COUNTERS}, EARLY_COUNTERS)
        acceptance_release.touch()
        self.assertEqual(self.finish(acceptance), 0)

    def test_reclaim_counters_that_cannot_be_read_are_null_and_never_zero(self):
        """A scope without the files, a line that is missing and a value that is no number each cost the counter concerned and not the exit status."""
        status, _, result = self.run_command("no-counter-files", status=3)
        self.assertEqual(status, 3)
        for report in self.reports(result):
            self.assertEqual({field: report.get(field, ABSENT) for field in COUNTERS}, NO_COUNTERS)
        partial = {"memory.stat": "anon 1\nworkingset_refault_anon x\nworkingset_refault_file 5\npswpout 4\n", "memory.events": "low 0\nmax 0\n"}
        status, _, result = self.run_scope_files("partial-counter-files", partial, partial)
        self.assertEqual(status, 0)
        for report in self.reports(result):
            self.assertEqual({field: report.get(field, ABSENT) for field in COUNTERS},
                             {**NO_COUNTERS, "fileRefaultPages": 5, "swapOutPages": 4})
        only_events = {"memory.events": events(2)}
        status, _, result = self.run_scope_files("events-only", only_events, only_events)
        self.assertEqual(status, 0)
        for report in self.reports(result):
            self.assertEqual({field: report.get(field, ABSENT) for field in COUNTERS}, {**NO_COUNTERS, "memoryHighEvents": 2})

    def test_the_boundaries_above_a_scope_report_how_often_each_was_exceeded_during_the_run(self):
        """Each cgroup above the scope with a memory.high reports how far its count rose from before the command started to when it ended.

        The count is the cgroup's own (memory.events.local) and is shared by everything below it.  A cgroup with no memory.high is no boundary and is left out."""
        uid = os.getuid()
        manager, user = f"user@{uid}.service", "user.slice"
        paths = self.lay_boundaries("acceptance", {
            "agents-acceptance.slice": ("max", 9), "agents.slice": (LIMIT, 100), manager: (LIMIT, 40),
            f"user-{uid}.slice": ("max", 0), user: (LIMIT, 1000)})

        def counted(name):
            return str(paths[name] / "memory.events.local")

        # The command raises a count as soon as it runs, which is after the supervisor read the count that it subtracts.
        started = {counted("agents.slice"): events(103)}
        ended = {counted("agents.slice"): events(107), counted(user): events(1250), counted("agents-acceptance.slice"): events(50)}
        status, _, result = self.run_scope_files("boundaries", started, ended)
        self.assertEqual(status, 0)
        for report in self.reports(result):
            self.assertEqual(report.get("ancestorHighEvents", ABSENT), {"agents.slice": 7, manager: 0, user: 250})
            self.assertEqual({field: report.get(field, ABSENT) for field in COUNTERS}, NO_COUNTERS)

    def test_boundaries_that_cannot_be_read_are_null_and_hide_no_other_boundary(self):
        """A memory.high that is missing or no number, a count that is missing and a count that went back each give null for that cgroup alone."""
        uid = os.getuid()
        manager, user = f"user@{uid}.service", "user.slice"
        paths = self.lay_boundaries("acceptance", {
            "agents.slice": (LIMIT, 100), manager: (LIMIT, None), f"user-{uid}.slice": ("not a number", 5), user: (LIMIT, 500)})
        ended = {str(paths["agents.slice"] / "memory.events.local"): events(103),
                 str(paths[user] / "memory.events.local"): events(3)}
        status, _, result = self.run_scope_files("unreadable-boundaries", {}, ended)
        self.assertEqual(status, 0)
        for report in self.reports(result):
            self.assertEqual(report.get("ancestorHighEvents", ABSENT),
                             {"agents-acceptance.slice": None, "agents.slice": 3, manager: None, f"user-{uid}.slice": None, user: None})

    def test_a_nested_run_has_no_reclaim_counters_and_no_boundaries(self):
        """The inner supervisor has no scope of its own, so it counts nothing and subtracts nothing: its fields are null, not zero."""
        self.assertEqual(self.nested("deep", "acceptance"), 0)
        (nested,) = [record for _, record in self.measurements() if record["nested"]]
        self.assertEqual({field: nested.get(field, ABSENT) for field in COUNTERS}, NO_COUNTERS)
        self.assertIsNone(nested.get("ancestorHighEvents", ABSENT))

    def test_a_target_and_a_slot_wait_need_a_policy_and_a_number_of_seconds(self):
        """Both are part of the resource options: alone they are a usage error, and so is a value that is no number of seconds."""
        policy = ["--resource-policy", str(self.policy), "--resource-wait-until", "9999999999", "--resource-run-seconds", "60"]
        for arguments, expected in ((["--resource-target-seconds", "5"], "require --resource-policy"),
                                    ([*policy, "--resource-target-seconds", "0"], "must be a positive number"),
                                    ([*policy, "--resource-target-seconds", "soon"], "needs a number"),
                                    (["--resource-slot-wait", "5"], "require --resource-policy"),
                                    ([*policy, "--resource-slot-wait", "-1"], "must be zero or a positive number"),
                                    ([*policy, "--resource-slot-wait", "nan"], "must be zero or a positive number"),
                                    ([*policy, "--resource-slot-wait", "long"], "needs a number")):
            with self.subTest(arguments=arguments):
                run = subprocess.run([sys.executable, str(SOURCE), *arguments, "--", *INSTANT], capture_output=True, text=True,
                                     env=self.environment())
                self.assertEqual(run.returncode, 2)
                self.assertIn(expected, run.stderr)

    def test_the_wait_for_the_callers_slot_reaches_the_result_and_the_journal(self):
        """The slot is the caller's, so the supervisor only carries the seconds the caller waited into the record of the run."""
        status, _, result = self.run_command("slot-waited", arguments=["--resource-slot-wait", "1.25"])
        self.assertEqual(status, 0)
        (_, record), = self.measurements()
        self.assertEqual((result["slotWaitSeconds"], record["slotWaitSeconds"]), (1.25, 1.25))

    def test_a_run_that_did_not_wait_for_its_slot_reports_0_and_one_without_a_slot_reports_null(self):
        """No wait is 0, a number the caller measured; a caller that has no slot passes nothing, and nothing is null, not 0."""
        status, _, result = self.run_command("slot-free", arguments=["--resource-slot-wait", "0"])
        self.assertEqual(status, 0)
        (_, record), = self.measurements()
        self.assertEqual((result["slotWaitSeconds"], record["slotWaitSeconds"]), (0, 0))
        status, _, result = self.run_command("no-slot")
        self.assertEqual(status, 0)
        (_, record), = self.measurements()
        self.assertEqual((result["slotWaitSeconds"], record["slotWaitSeconds"]), (None, None))

    def test_a_run_that_never_started_reports_its_wait_and_reason(self):
        """A run that gave up while waiting says so: not admitted, no run seconds, the guest outcome that held it as the reason."""
        self.outcome(GUEST_OUTCOMES[0], "fail")
        process, started, _ = self.start("never-started", wait=WAIT_LIMIT, arguments=["--resource-key", KEY, "--resource-slot-wait", "2"],
                                         cwd=self.repo)
        # It is judged and found not to fit before the limit runs out, so at least one reason is on record.
        self.waiting("never-started", process)
        process.communicate(timeout=HANG_SECONDS)
        self.assertFalse(started.exists())
        (_, record), = self.measurements()
        self.assertEqual((record["status"], record["admitted"], record["runSeconds"]), (75, False, None))
        # The last observation before the limit runs out of time and its diagnosis is the final reason; the first is the cause.
        self.assertEqual(record["waitReasons"][0], GUEST_OUTCOMES[0])
        # The limit starts before the supervisor's interpreter does, so the wait it measures cannot be longer than the limit.
        self.assertGreater(record["waitSeconds"], 0)
        self.assertLessEqual(record["waitSeconds"], WAIT_LIMIT + WAIT_SLACK)
        # The slot the caller waited for before it asked for resources is on the record of a run that never started too.
        self.assertEqual(record["slotWaitSeconds"], 2)
        self.assertEqual(json.loads((self.root / "never-started.result").read_text())["slotWaitSeconds"], 2)

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

    # The capped class: a CPU cap on the run's own scope, and a budget of CPU that all capped runs share

    def test_i8_a_capped_run_gets_its_own_scope_with_the_cap_in_the_capped_slice(self):
        """The cap is the scope's CPUQuota, the memory is reserved as for an acceptance, and both reports carry the cap."""
        process, started, release = self.start("capped", klass=CAPPED, arguments=self.cap(150, GIB))
        self.wait_for(started.exists, process)
        (scope,) = self.scopes(CAPPED)
        self.assertEqual((scope / "cpu.max").read_text().strip(), "150000 100000")
        self.assertEqual((scope / "memory.low").read_text().strip(), str(GIB))
        (call,) = self.calls("run")
        self.assertIn("--slice=agents-capped.slice", call)
        self.assertEqual([argument for argument in call if argument.startswith("CPUQuota=")], ["CPUQuota=150%"])
        self.assertIn(f"MemoryLow={GIB}", call)
        self.assertEqual([self.scopes(klass) for klass in CLASSES], [[], []])
        release.touch()
        self.assertEqual(self.finish(process), 0)
        result = json.loads((self.root / "capped.result").read_text())
        (_, record), = self.measurements()
        self.assertEqual((result["cpuCapPercent"], record["cpuCapPercent"]), (150, 150))
        self.assertEqual((record["class"], record["nested"], record["admitted"], record["status"]), (CAPPED, False, True, 0))

    def test_a_run_that_asks_for_no_cap_reports_none(self):
        """The field is null, not 0, for a run of another class, so that no cap is not read as a cap of nothing."""
        status, _, result = self.run_command("uncapped", key=None)
        self.assertEqual(status, 0)
        (_, record), = self.measurements()
        self.assertEqual((result["cpuCapPercent"], record["cpuCapPercent"]), (None, None))

    def test_i8_capped_runs_share_the_budget_and_the_one_that_does_not_fit_enters_when_room_is_free(self):
        """Two runs of half the budget fill it; a third waits for the budget, not for memory, and enters once one ends."""
        half = CPU_BUDGET // 2
        first, first_started, first_release = self.start("first", klass=CAPPED, arguments=self.cap(half))
        self.wait_for(first_started.exists, first)
        second, second_started, second_release = self.start("second", klass=CAPPED, arguments=self.cap(half))
        self.wait_for(second_started.exists, second)
        third, third_started, third_release = self.start("third", klass=CAPPED, arguments=self.cap(100))
        self.assertEqual(self.waiting("third", third), CPU_REASON)
        self.assertEqual(self.judged(third), 1)
        self.assertFalse(third_started.exists())
        caps = [(scope / "cpu.max").read_text().strip() for scope in self.scopes(CAPPED)]
        self.assertEqual(caps, [f"{half * 1000} 100000"] * 2)
        first_release.touch()
        self.assertEqual(self.finish(first), 0)
        self.wait_for(third_started.exists, third)
        for release, process in ((second_release, second), (third_release, third)):
            release.touch()
            self.assertEqual(self.finish(process), 0)

    def test_i8_four_runs_that_each_ask_for_the_whole_budget_run_one_after_the_other(self):
        """Four runs cannot each take the whole CPU budget: they take it in turn, and only one scope holds it at a time."""
        pending = {f"whole-{index}": self.start(f"whole-{index}", klass=CAPPED, arguments=self.cap(CPU_BUDGET))
                   for index in range(4)}
        while pending:
            self.wait_for(lambda: any(marker.exists() for _, marker, _ in pending.values()))
            running = [name for name, (_, marker, _) in pending.items() if marker.exists()]
            self.assertEqual(len(running), 1, running)
            caps = [(scope / "cpu.max").read_text().strip() for scope in self.scopes(CAPPED)]
            self.assertEqual(caps, [f"{CPU_BUDGET * 1000} 100000"])
            process, _, release = pending.pop(running[0])
            release.touch()
            self.assertEqual(self.finish(process), 0)

    def test_i8_a_request_above_the_budget_is_refused_at_once_and_one_at_the_budget_is_admitted(self):
        """A request that no amount of waiting could admit fails with 70 without a wait, a scope or a command."""
        process, started, _ = self.start("above", klass=CAPPED, arguments=self.cap(CPU_BUDGET + 1))
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 70)
        self.assertIn("exceeds the capped budget", error)
        self.assertNotIn("waiting for resources", error)
        self.assertFalse(started.exists())
        self.assertEqual((self.calls("run"), self.scopes(CAPPED)), ([], []))
        (_, record), = self.measurements()
        self.assertEqual((record["status"], record["admitted"], record["cpuCapPercent"]), (70, False, CPU_BUDGET + 1))
        status, _, result = self.run_command("at-budget", key=None, klass=CAPPED, arguments=self.cap(CPU_BUDGET))
        self.assertEqual(status, 0)
        self.assertEqual(result["cpuCapPercent"], CPU_BUDGET)

    def test_the_cpu_request_belongs_to_the_capped_class_and_the_capped_class_needs_one(self):
        """No request is a refusal for the capped class and a request is one for the others, before anything starts."""
        cases = ((CAPPED, [], "needs a CPU request"),
                 ("acceptance", ["--resource-cpu", "100"], "needs the policy of the capped class"),
                 ("deep", ["--resource-cpu", "100"], "needs the policy of the capped class"))
        for klass, arguments, expected in cases:
            with self.subTest(klass=klass):
                process, started, _ = self.start(f"refused-{klass}", klass=klass, arguments=arguments)
                _, error = process.communicate(timeout=HANG_SECONDS)
                self.assertEqual(process.returncode, 70)
                self.assertIn(expected, error)
                self.assertFalse(started.exists())
        self.assertEqual(self.calls("run"), [])

    def test_a_cpu_request_needs_a_policy_and_a_positive_whole_number(self):
        """Without a policy the request would be dropped silently, so it is a usage error, and so is a value that is no percentage."""
        policy = ["--resource-policy", str(self.capped_policy), "--resource-wait-until", "9999999999", "--resource-run-seconds", "60"]
        for arguments, expected in ((["--resource-cpu", "100"], "require --resource-policy"),
                                    ([*policy, "--resource-cpu", "0"], "needs a positive integer"),
                                    ([*policy, "--resource-cpu", "-1"], "needs a positive integer"),
                                    ([*policy, "--resource-cpu", "1.5"], "needs a positive integer"),
                                    ([*policy, "--resource-cpu", "many"], "needs a positive integer")):
            with self.subTest(arguments=arguments):
                run = subprocess.run([sys.executable, str(SOURCE), *arguments, "--", *INSTANT], capture_output=True, text=True,
                                     env=self.environment())
                self.assertEqual(run.returncode, 2)
                self.assertIn(expected, run.stderr)

    def test_i8_a_capped_run_and_a_deep_run_neither_cancel_nor_count_as_each_other(self):
        """A capped scope is not the deep run a deep one waits for, and a deep scope is not cancelled for a capped run to enter."""
        capped, capped_started, capped_release = self.start("capped-one", klass=CAPPED, arguments=self.cap(100))
        self.wait_for(capped_started.exists, capped)
        deep, deep_started, deep_release = self.start("deep", klass="deep", arguments=["--resource-memory", str(100 * MIB)])
        self.wait_for(deep_started.exists, deep)
        again, again_started, again_release = self.start("capped-two", klass=CAPPED, arguments=self.cap(100))
        self.wait_for(again_started.exists, again)
        self.assertEqual(self.stops(), [])
        self.assertEqual((len(self.scopes("deep")), len(self.scopes(CAPPED))), (1, 2))
        for release, process in ((capped_release, capped), (deep_release, deep), (again_release, again)):
            release.touch()
            self.assertEqual(self.finish(process), 0)
        self.assertEqual(json.loads((self.root / "deep.result").read_text())["status"], 0)

    def test_i8_a_capped_run_that_lacks_memory_waits_and_never_cancels_the_deep_run(self):
        """An acceptance in its place would stop the deep run; a capped run only waits, and the deep run ends as itself."""
        deep, deep_started, deep_release = self.start("deep", klass="deep", arguments=["--resource-memory", str(4 * GIB)])
        self.wait_for(deep_started.exists, deep)
        self.observe(hostMemoryHeadroomBytes=GIB, memoryHeadroomBytes=GIB)
        capped, capped_started, capped_release = self.start("capped", klass=CAPPED, arguments=self.cap(100, 2 * GIB))
        self.assertEqual(self.waiting("capped", capped), HEADROOM)
        self.keeps_waiting(capped)
        self.assertFalse(capped_started.exists())
        self.assertIsNone(deep.poll())
        self.assertEqual(self.stops(), [])
        self.assertEqual(list((self.root / "run").glob("cancel-*")), [])
        deep_release.touch()
        self.assertEqual(self.finish(deep), 0)
        self.assertEqual(json.loads((self.root / "deep.result").read_text())["status"], 0)
        self.observe(hostMemoryHeadroomBytes=10 * GIB, memoryHeadroomBytes=10 * GIB)
        self.wait_for(capped_started.exists, capped)
        capped_release.touch()
        self.assertEqual(self.finish(capped), 0)

    def test_i8_a_capped_run_reserves_its_memory_growth_against_an_acceptance_and_is_never_cancelled_for_one(self):
        """The acceptance that does not fit beside the capped run waits for it, and the capped run is neither stopped nor marked."""
        capped, capped_started, capped_release = self.start("capped", klass=CAPPED, arguments=self.cap(100, 6 * GIB))
        self.wait_for(capped_started.exists, capped)
        acceptance, started, release = self.start("acceptance", arguments=["--resource-memory", str(6 * GIB)])
        self.assertEqual(self.waiting("acceptance", acceptance), HEADROOM)
        self.keeps_waiting(acceptance)
        self.assertFalse(started.exists())
        self.assertIsNone(capped.poll())
        self.assertEqual(self.stops(), [])
        capped_release.touch()
        self.assertEqual(self.finish(capped), 0)
        self.wait_for(started.exists, acceptance)
        release.touch()
        self.assertEqual(self.finish(acceptance), 0)

    def test_i8_a_waiting_acceptance_does_not_hold_a_capped_run_as_it_holds_a_deep_run(self):
        """The capped run is judged by its own room alone, so it enters where a deep run of the same size waits."""
        holder, held, holder_release = self.start("holder", arguments=["--resource-memory", str(9 * GIB)])
        self.wait_for(held.exists, holder)
        large, large_started, large_release = self.start("large", arguments=["--resource-memory", str(9 * GIB)])
        self.waiting("large", large)
        capped, capped_started, capped_release = self.start("capped", klass=CAPPED, arguments=self.cap(100))
        self.wait_for(capped_started.exists, capped)
        self.assertFalse(large_started.exists())
        capped_release.touch()
        self.assertEqual(self.finish(capped), 0)
        holder_release.touch()
        self.assertEqual(self.finish(holder), 0)
        self.wait_for(large_started.exists, large)
        large_release.touch()
        self.assertEqual(self.finish(large), 0)

    def test_i8_a_capped_scope_whose_cap_cannot_be_read_reserves_the_whole_budget(self):
        """A scope with no cpu.max, and one that says max, hold the budget; the cap it really has is what it reserves."""
        stray = self.leave_scope(CAPPED, "stray.scope", HOLDING)
        reason, _ = self.held_back("missing-cap", klass=CAPPED, arguments=self.cap(100))
        self.assertEqual(reason, CPU_REASON)
        (stray / "cpu.max").write_text("max 100000\n")
        process, started, release = self.start("capped", klass=CAPPED, arguments=self.cap(100))
        self.assertEqual(self.waiting("capped", process), CPU_REASON)
        self.assertFalse(started.exists())
        (stray / "cpu.max").write_text(f"{(CPU_BUDGET - 100) * 1000} 100000\n")
        self.wait_for(started.exists, process)
        release.touch()
        self.assertEqual(self.finish(process), 0)

    def test_i8_an_empty_scope_reserves_nothing_and_a_capped_run_never_asks_to_stop_it(self):
        """A scope that holds no process runs nothing, so the whole budget is free beside it; it is left to the classes that reclaim it."""
        empty = [self.leave_scope(klass, f"gone-{klass}.scope", EMPTY) for klass in (*CLASSES, CAPPED)]
        status, _, _ = self.run_command("after-empty", key=None, klass=CAPPED, arguments=self.cap(CPU_BUDGET))
        self.assertEqual(status, 0)
        (_, record), = self.measurements()
        self.assertEqual(record["waitReasons"], [])
        # A capped run asks the manager to stop no scope at all: its own is stopped only when its command could not enter it.
        self.assertEqual(self.stops(), [])
        self.assertTrue(all(scope.exists() for scope in empty))

    def test_i9_a_scope_without_the_requested_cap_runs_nothing_and_is_stopped(self):
        """Whether the manager leaves the quota unapplied or the scope has no cpu.max, the command never runs and the scope goes."""
        for index, mode in enumerate(("ignore", "absent")):
            with self.subTest(mode=mode):
                policy = self.write_policy(CAPPED, name=f"cap-{mode}.json", cpu=mode)
                process, started, _ = self.start(f"uncapped-{mode}", klass=CAPPED, policy=policy, arguments=self.cap(150))
                _, error = process.communicate(timeout=HANG_SECONDS)
                self.assertEqual(process.returncode, 70)
                self.assertIn("CPU cap", error)
                self.assertIn("command was not started", error)
                self.assertFalse(started.exists())
                self.assertEqual(self.stops(), self.units_asked_for())
                self.assertEqual(len(self.stops()), index + 1)
                self.assertEqual(self.scopes(CAPPED), [])
                (_, record), = self.measurements()
                self.assertEqual((record["status"], record["admitted"], record["cpuCapPercent"]), (70, False, 150))

    def test_a_capped_run_that_cannot_enter_reports_its_wait_and_no_run(self):
        """Waiting for the budget is a wait: it ends with 75, names what held it back, has no run seconds and never starts."""
        holder, held, holder_release = self.start("holder", klass=CAPPED, arguments=self.cap(CPU_BUDGET))
        self.wait_for(held.exists, holder)
        process, started, _ = self.start("starved", klass=CAPPED, wait=WAIT_LIMIT, arguments=self.cap(100))
        self.assertEqual(self.waiting("starved", process), CPU_REASON)
        _, error = process.communicate(timeout=HANG_SECONDS)
        self.assertEqual(process.returncode, 75)
        self.assertEqual(self.judged(process), 1, "CPU-only waiting kept launching the full observer")
        self.assertFalse(started.exists())
        self.assertIn("gave up waiting for resources", error)
        result = json.loads((self.root / "starved.result").read_text())
        self.assertEqual((result["phase"], result["spawned"], result["status"], result["cpuCapPercent"]), ("finished", False, 75, 100))
        (_, record), = self.measurements()
        self.assertEqual((record["class"], record["status"], record["admitted"], record["runSeconds"], record["cpuCapPercent"]),
                         (CAPPED, 75, False, None, 100))
        self.assertEqual(record["waitReasons"][0], CPU_REASON)
        self.assertGreater(record["waitSeconds"], 0)
        self.assertLessEqual(record["waitSeconds"], WAIT_LIMIT + WAIT_SLACK)
        self.assertIsNone(holder.poll())
        holder_release.touch()
        self.assertEqual(self.finish(holder), 0)

    def test_a_capped_run_past_its_run_limit_ends_with_124_and_reports_a_run_apart_from_its_wait(self):
        """The run limit counts from admission: a run that did not wait is cancelled at it with 124 and has run seconds."""
        status, _, result = self.run_command("overrun", key=None, klass=CAPPED, run=0.6, arguments=self.cap(100),
                                             command=[sys.executable, "-c", "import time; time.sleep(30)"])
        self.assertEqual(status, 124)
        self.assertTrue(result["spawned"])
        (_, record), = self.measurements()
        self.assertEqual((record["status"], record["admitted"], record["waitReasons"], record["cpuCapPercent"]),
                         (124, True, [], 100))
        self.assertIsNotNone(record["runSeconds"])

    def test_i9_a_nested_capped_request_must_equal_the_cap_of_the_capped_scope_it_is_in(self):
        """It runs in that scope without one of its own, so only the cap that scope has is the cap it can honour: a smaller or a larger request fails with 70."""
        for cpu, expected in (("100", 70), ("200", 0), ("300", 70)):
            with self.subTest(cpu=cpu):
                self.assertEqual(self.nested(CAPPED, CAPPED, "--resource-cpu", cpu, outer=self.cap(200)), expected)
        # One scope for each of the three outer runs and none for the inner ones.
        self.assertEqual(len([call for call in self.calls("run") if "--slice=agents-capped.slice" in call]), 3)

    def test_i9_a_capped_request_nested_in_a_scope_without_a_cap_is_refused_and_makes_no_scope(self):
        """Running it there would drop the cap it asks for, and a scope of its own would leave the reservation of the scope it is in."""
        for outer in ("acceptance", "deep"):
            with self.subTest(outer=outer):
                self.assertEqual(self.nested(outer, CAPPED, "--resource-cpu", "100"), 70)
        self.assertEqual([call for call in self.calls("run") if "--slice=agents-capped.slice" in call], [])
        self.assertEqual(self.scopes(CAPPED), [])

    def test_i9_a_nested_request_of_another_class_runs_under_the_cap_of_the_capped_scope(self):
        """A call inside a capped run that asks for no cap stays in that scope, so it keeps the cap, and reports the class it runs as."""
        self.assertEqual(self.nested(CAPPED, "acceptance", outer=self.cap(200)), 0)
        records = [record for _, record in self.measurements()]
        self.assertEqual(sorted((record["nested"], record["class"]) for record in records), [(False, CAPPED), (True, CAPPED)])
        self.assertEqual([call for call in self.calls("run") if "--slice=agents-acceptance.slice" in call], [])

    def test_a_policy_carries_a_cpu_budget_for_the_capped_class_only_and_a_slice_for_every_class(self):
        """A budget that is missing or no positive whole number, a budget on another class and a missing slice all fail with 70."""
        without_capped = {name: path for name, path in SLICES.items() if name != CAPPED}
        cases = ((CAPPED, {"cpuBudgetPercent": None}, "cpuBudgetPercent must be a positive integer"),
                 (CAPPED, {"cpuBudgetPercent": 0}, "cpuBudgetPercent must be a positive integer"),
                 (CAPPED, {"cpuBudgetPercent": 2.5}, "cpuBudgetPercent must be a positive integer"),
                 ("acceptance", {"cpuBudgetPercent": 300}, "belongs to the policy of the capped class"),
                 ("deep", {"cpuBudgetPercent": 300}, "belongs to the policy of the capped class"),
                 ("acceptance", {"slices": without_capped}, "slices must name the slice of every class"))
        for index, (klass, changes, expected) in enumerate(cases):
            with self.subTest(klass=klass, changes=changes):
                policy = self.write_policy(klass, name=f"invalid-{index}.json", **changes)
                process, started, _ = self.start(f"invalid-{index}", klass=klass, policy=policy,
                                                 arguments=self.cap(100) if klass == CAPPED else [])
                _, error = process.communicate(timeout=HANG_SECONDS)
                self.assertEqual(process.returncode, 70)
                self.assertIn(expected, error)
                self.assertFalse(started.exists())

    def test_a_capped_run_is_not_made_the_first_for_the_kernel_to_kill(self):
        """oom_score_adj is left alone for a capped run, as for an acceptance."""
        seen = self.root / "capped.score"
        process, _, _ = self.start("capped", klass=CAPPED, arguments=self.cap(100),
                                   command=[*OOM_SCORE, str(seen), str(self.root / "capped.release")])
        self.wait_for(seen.exists, process)
        (self.root / "capped.release").touch()
        self.assertEqual(self.finish(process), 0)
        self.assertEqual(seen.read_text().strip(), "0")


if __name__ == "__main__":
    unittest.main()
