"""A stand-in for `systemd-run --user --scope` and `systemctl --user stop` that keeps its cgroup tree in a directory.

systemd-run in scope mode creates the scope, moves itself into it and then executes the command, so the command keeps the
process ID systemd-run had.  The fake does the same: it creates the scope's directory below the slice, writes the properties
the caller set into the files the kernel would show, marks its own environment as belonging to the scope and executes the
command in place.

A cgroup holds every process that was started inside it, however the process detaches itself afterwards, and disappears
when the last one has ended.  The environment is inherited the same way, so the fake takes a process to belong to a scope
when its environment carries the scope's mark.  A detached janitor removes the scope's directory when no such process is
left, and `stop` ends every such process, as a stop job does.  The janitor adds a byte to `janitor.polls` in the scope for
every poll, so a test can tell how often the scope has been looked at, which no length of time can say.

    fake_systemd.py --cgroup-root ROOT [--fail] [--gate FILE] run   SYSTEMD-RUN-ARGUMENTS...
    fake_systemd.py --cgroup-root ROOT                             ctl   SYSTEMCTL-ARGUMENTS...

`--fail` makes systemd-run refuse to create the scope; `--gate` makes it answer only once FILE exists.  Every call
is appended to `ROOT/calls.log` as one JSON line, so a test can read what the caller asked for.
"""

import json
import os
from pathlib import Path
import shutil
import signal
import sys
import time

# The properties a scope is given and the file that shows each of them, with the value it has before a property sets it.
# The supervisor reads nothing else of a scope: what it uses is reported by the observation.
PROPERTY_FILES = {"MemoryLow": "memory.low", "MemoryHigh": "memory.high"}
IDLE_FILES = {
    "memory.low": "0\n",
    "memory.high": "max\n",
}
# The environment variable that marks a process as a member of the scope named by its value.
MEMBER_MARK = "DOTFILES_FAKE_SCOPE"
POLL_SECONDS = 0.03
# How many polls in a row must find no member: a process that is being executed shows an empty environment for an instant.
EMPTY_POLLS = 3


def manager_cgroup(root):
    """The user manager's cgroup below the root, laid out as on a host."""
    uid = os.getuid()
    return Path(root, "user.slice", f"user-{uid}.slice", f"user@{uid}.service")


def slice_path(name):
    """The slice's path below the manager: `a-b.slice` sits in `a.slice`, as systemd derives the parent from the name."""
    parts = name.removesuffix(".slice").split("-")
    return Path(*(("-".join(parts[:index + 1]) + ".slice") for index in range(len(parts))))


def record(root, tool, arguments):
    """Append one call to the log."""
    Path(root).mkdir(parents=True, exist_ok=True)
    with open(Path(root, "calls.log"), "a") as stream:
        stream.write(json.dumps({"tool": tool, "pid": os.getpid(), "arguments": arguments}) + "\n")


def alive(pid):
    """Whether the process still runs; a zombie that nobody has collected yet is already gone as far as its cgroup goes."""
    try:
        data = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return False
    return data[data.rindex(")") + 2] != "Z"


def members(scope):
    """The live processes that belong to the scope: those whose environment carries its mark.

    The mark is set before the command is executed, so it is inherited by every descendant, however it detaches
    (setsid, double fork, reparenting), as a cgroup is.
    """
    mark = f"{MEMBER_MARK}={scope}".encode()
    found = []
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            if mark in Path(entry.path, "environ").read_bytes().split(b"\0") and alive(int(entry.name)):
                found.append(int(entry.name))
        except OSError:
            continue
    return found


def collect_when_gone(scope, pid):
    """Detach a janitor that removes the scope when its last member has ended, as `--collect` does.

    pid: the process that executes the command in the scope; it is a member before the mark is on its environment.
    The janitor is started before the mark is set, so it is not a member of what it watches.
    It leaves one byte in the scope's `janitor.polls` for every poll.
    """
    first = os.fork()
    if first:
        os.waitpid(first, 0)
        return
    os.setsid()
    if os.fork():
        os._exit(0)
    # The janitor must outlive a termination request of the supervisor, hold none of the caller's pipes and leave no trace
    # but its count of polls.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    null = os.open(os.devnull, os.O_RDWR)
    for descriptor in (0, 1, 2):
        os.dup2(null, descriptor)
    os.closerange(3, 1024)
    empty = 0
    with open(scope / "janitor.polls", "ab", buffering=0) as polls:
        while empty < EMPTY_POLLS:
            empty = 0 if alive(pid) or members(scope) else empty + 1
            polls.write(b".")
            time.sleep(POLL_SECONDS)
    shutil.rmtree(scope, ignore_errors=True)
    os._exit(0)


def run(root, fail, gate, arguments):
    """The `systemd-run --scope` half: create the scope and execute the command inside it."""
    record(root, "run", arguments)
    if fail:
        print("Failed to start transient scope unit: fixture refuses to create a scope", file=sys.stderr)
        return 1
    # A manager that is slow to answer: the scope exists, and the command runs, only once the gate is open.
    while gate is not None and not gate.exists():
        time.sleep(POLL_SECONDS)
    slice_name = unit = None
    properties = {}
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        index += 1
        if argument == "--":
            break
        if argument.startswith("--slice="):
            slice_name = argument.removeprefix("--slice=")
        elif argument.startswith("--unit="):
            unit = argument.removeprefix("--unit=")
        elif argument in ("-p", "--property"):
            name, _, value = arguments[index].partition("=")
            properties[name] = value
            index += 1
    command = arguments[index:]
    if slice_name is None or unit is None or not command:
        print("fake systemd-run: --slice, --unit and a command are required", file=sys.stderr)
        return 64
    scope = manager_cgroup(root) / slice_path(slice_name) / unit
    scope.mkdir(parents=True)
    for name, content in IDLE_FILES.items():
        (scope / name).write_text(content)
    for name, value in properties.items():
        if name in PROPERTY_FILES:
            (scope / PROPERTY_FILES[name]).write_text(value + "\n")
    (scope / "cgroup.procs").write_text(f"{os.getpid()}\n")
    collect_when_gone(scope, os.getpid())
    os.environ[MEMBER_MARK] = str(scope)
    os.execvp(command[0], command)


def control(root, arguments):
    """The `systemctl --user stop --no-block UNIT` half: terminate every process of the scope, as a stop job does."""
    record(root, "ctl", arguments)
    if "stop" not in arguments:
        print("fake systemctl: only stop is supported", file=sys.stderr)
        return 64
    units = [argument for argument in arguments if argument.endswith(".scope")]
    stopped = False
    for unit in units:
        for scope in manager_cgroup(root).rglob(unit):
            for pid in members(scope):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            stopped = True
    return 0 if stopped else 5


def main(arguments):
    root = None
    fail = False
    gate = None
    while arguments and arguments[0].startswith("--"):
        if arguments[0] == "--cgroup-root":
            root = arguments[1]
            arguments = arguments[2:]
        elif arguments[0] == "--fail":
            fail = True
            arguments = arguments[1:]
        elif arguments[0] == "--gate":
            gate = Path(arguments[1])
            arguments = arguments[2:]
        else:
            break
    if root is None or not arguments or arguments[0] not in ("run", "ctl"):
        print("usage: fake_systemd.py --cgroup-root ROOT [--fail] [--gate FILE] run|ctl ARGUMENTS...", file=sys.stderr)
        return 64
    if arguments[0] == "run":
        return run(root, fail, gate, arguments[1:])
    return control(root, arguments[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
