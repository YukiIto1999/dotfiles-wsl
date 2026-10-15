"""Deterministic transitions of --require-drained past the SIGKILL grace.

A process that survives SIGKILL needs the kernel (an uninterruptible sleep) and cannot be created on
demand in a sandbox.  Each case therefore makes the supervisor's own signalling or process-table reading
fail until the test releases it, with a real command and a real descendant underneath.  That shows what
the supervisor does in such a state and nothing about what the kernel does; supervise.sh covers real
processes without any injected failure.
"""

import contextlib
import errno
import importlib.util
import io
import json
import os
import shutil
import signal
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

SOURCE = Path(sys.argv.pop(1)).resolve()
SPEC = importlib.util.spec_from_file_location("dotfiles_supervise", SOURCE)
supervise = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(supervise)

REAL_SEND_SIGNAL = supervise.send_signal
REAL_OWNED_PROCESSES = supervise.owned_processes
TERM_GRACE = "0.2"
KILL_GRACE = "0.3"
WAIT_SECONDS = 20.0
# Several sweeps after the grace, so a supervisor that returns early shows before the release.
HOLD_SECONDS = 1.5
HANDLED_SIGNALS = (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP, signal.SIGCHLD)

# The client leaves one process behind and ends at once; the process ignores SIGTERM, so only SIGKILL ends it.
CLIENT = """\
import os, subprocess, sys, time
subprocess.Popen([sys.executable, "-c", sys.argv[2], sys.argv[1]])
while not (os.path.exists(sys.argv[1]) and os.path.getsize(sys.argv[1])):
    time.sleep(0.01)
"""
STUBBORN = """\
import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(str(os.getpid()))
time.sleep(600)
"""


def alive(pid):
    try:
        stat = Path(f"/proc/{pid}/stat").read_bytes()
    except OSError:
        return False
    return stat[stat.rindex(b")") + 2:].split()[0] != b"Z"


class DrainTransition(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.addCleanup(self.restore_signals, {number: signal.getsignal(number) for number in HANDLED_SIGNALS})
        self.addCleanup(self.end_stubborn)
        self.pid_file = self.directory / "stubborn.pid"
        self.result = self.directory / "result.json"
        (self.directory / "client.py").write_text(CLIENT, encoding="utf-8")
        self.released = threading.Event()
        self.returned = threading.Event()
        self.waiting = None
        self.problems = []

    @staticmethod
    def restore_signals(saved):
        signal.set_wakeup_fd(-1)
        for number, handler in saved.items():
            if handler is not None:
                signal.signal(number, handler)

    def end_stubborn(self):
        text = self.pid_file.read_text(encoding="utf-8").strip() if self.pid_file.exists() else ""
        if not text:
            return
        pid = int(text)
        if alive(pid):
            os.kill(pid, signal.SIGKILL)
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    def arguments(self, *flags):
        return [
            *flags, "--term-grace", TERM_GRACE, "--kill-grace", KILL_GRACE, "--result", str(self.result), "--",
            sys.executable, str(self.directory / "client.py"), str(self.pid_file), STUBBORN,
        ]

    def drop_sigkill(self, pid, number):
        if number != signal.SIGKILL or self.released.is_set():
            REAL_SEND_SIGNAL(pid, number)

    def refuse_sigkill(self, pid, number):
        if number == signal.SIGKILL and not self.released.is_set():
            raise PermissionError(errno.EPERM, os.strerror(errno.EPERM))
        REAL_SEND_SIGNAL(pid, number)

    def unreadable_table(self):
        if not self.released.is_set():
            raise OSError(errno.EMFILE, os.strerror(errno.EMFILE))
        return REAL_OWNED_PROCESSES()

    def report(self, phase):
        try:
            report = json.loads(self.result.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return report if report["phase"] == phase else None

    def watch(self):
        """Keep the failure in effect until the supervisor reports the overdue wait and then keeps waiting."""
        try:
            deadline = time.monotonic() + WAIT_SECONDS
            while self.waiting is None and not self.returned.is_set() and time.monotonic() < deadline:
                self.waiting = self.report("draining")
                time.sleep(0.02)
            if self.waiting is None:
                self.problems.append("the supervisor never reported the overdue wait")
                return
            time.sleep(HOLD_SECONDS)
            if self.returned.is_set():
                self.problems.append("the supervisor returned while a child still ran")
        finally:
            self.released.set()

    def supervise_until_released(self, failure):
        watcher = threading.Thread(target=self.watch)
        stderr = io.StringIO()
        with failure, contextlib.redirect_stderr(stderr):
            watcher.start()
            try:
                status = supervise.main(self.arguments("--require-drained"))
            finally:
                self.returned.set()
        watcher.join()
        return status, stderr.getvalue()

    def check_joined_after_overdue_wait(self, status):
        pid = int(self.pid_file.read_text(encoding="utf-8"))
        self.assertEqual(self.problems, [])
        self.assertEqual(status, 0)
        self.assertFalse(alive(pid))
        self.assertEqual(self.waiting["completion"], "require-drained")
        self.assertIs(self.waiting["drained"], False)
        self.assertTrue(self.waiting["spawned"])
        final = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(final["phase"], "finished")
        self.assertIs(final["drained"], True)
        self.assertIs(final["kill_grace_expired"], True)
        self.assertEqual(final["remaining"], [])
        self.assertEqual(final["client_status"], 0)
        self.assertEqual(final["status"], 0)
        return pid

    def test_sigkill_without_effect_keeps_ownership_until_the_kernel_confirms(self):
        status, stderr = self.supervise_until_released(mock.patch.object(supervise, "send_signal", self.drop_sigkill))
        pid = self.check_joined_after_overdue_wait(status)
        self.assertEqual(self.waiting["remaining"], [pid])
        self.assertEqual(self.waiting["unsignalable"], [])
        self.assertIsNone(self.waiting["observation_error"])
        self.assertIn("past the SIGKILL grace", stderr)
        self.assertIn(str(pid), stderr)

    def test_refused_signal_is_reported_and_the_wait_goes_on(self):
        status, stderr = self.supervise_until_released(mock.patch.object(supervise, "send_signal", self.refuse_sigkill))
        pid = self.check_joined_after_overdue_wait(status)
        self.assertEqual(self.waiting["remaining"], [pid])
        self.assertEqual(self.waiting["unsignalable"], [pid])
        self.assertIn(f"cannot signal: {pid}", stderr)

    def test_unreadable_process_table_is_reported_and_the_wait_goes_on(self):
        status, stderr = self.supervise_until_released(
            mock.patch.object(supervise, "owned_processes", self.unreadable_table)
        )
        self.check_joined_after_overdue_wait(status)
        self.assertIn("Too many open files", self.waiting["observation_error"])
        self.assertIn("cannot read the process table", stderr)

    def test_default_mode_still_returns_after_the_grace_with_the_child_alive(self):
        stderr = io.StringIO()
        with mock.patch.object(supervise, "send_signal", self.drop_sigkill), contextlib.redirect_stderr(stderr):
            status = supervise.main(self.arguments())
        pid = int(self.pid_file.read_text(encoding="utf-8"))
        final = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertEqual(status, supervise.FAILURE_STATUS)
        self.assertTrue(alive(pid))
        self.assertEqual(final["phase"], "finished")
        self.assertIs(final["drained"], False)
        self.assertEqual(final["remaining"], [pid])
        self.assertEqual(final["client_status"], 0)
        self.assertEqual(final["status"], supervise.FAILURE_STATUS)
        self.assertNotIn("completion", final)
        self.assertNotIn("kill_grace_expired", final)
        self.assertIn("processes still alive after SIGKILL", stderr.getvalue())

    def test_unobservable_process_table_refuses_to_start(self):
        stderr = io.StringIO()
        with mock.patch.object(supervise, "process_table", return_value={}), contextlib.redirect_stderr(stderr):
            status = supervise.main(self.arguments("--require-drained"))
        self.assertEqual(status, supervise.FAILURE_STATUS)
        self.assertFalse(self.pid_file.exists())
        self.assertIn("absent from /proc", stderr.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
