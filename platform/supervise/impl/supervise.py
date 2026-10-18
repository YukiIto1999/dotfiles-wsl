"""Run one command and own every process it leaves behind.

The supervisor becomes a child subreaper, starts the command once, and counts only
the kernel's report that it has no child left (``waitpid(-1)`` fails with ECHILD)
as completion.  A process the command orphans is reparented to the supervisor,
so a delayed grandchild is observed instead of assumed gone.

Session-wide cancellation (SIGTERM, SIGHUP) and the end of the command both
start termination: SIGTERM to every owned process, a grace period, then
SIGKILL.  SIGINT and SIGQUIT only cancel one operation inside the command, so
the supervisor ignores them by default.  Reaching a deadline is not completion;
the supervisor reports failure when processes are still alive afterwards.  By
default it returns once the SIGKILL grace has passed, with ``drained`` false.

``--interrupt-cancels`` makes SIGINT cancel the session like SIGTERM, for a caller whose
only handle on the session is this process and that already treats INT as cancellation.
Termination and the exit status follow the same rules as for SIGTERM.  SIGQUIT stays an
operation-level signal and is still ignored.

``--hold-fd N`` names a descriptor (typically a flock the caller holds) that the
supervisor keeps open until every owned process is confirmed gone.  The command
and its descendants never inherit it.  When the caller dies, the supervisor still
holds the same open file description, so the lock outlives the caller.  If
processes survive SIGKILL, a detached holder keeps the descriptor until they end.

``--parent-death-cancels PID`` cancels when the caller with that PID dies.
The caller supplies its own PID so a death before supervisor startup also cancels.
Without it, the session outlives the caller.

``--require-drained`` keeps that ownership past the SIGKILL grace.  The supervisor goes on
killing and waiting, reports periodically that the grace has passed (stderr and the
``draining`` result phase), and returns only when ``waitpid(-1)`` fails with ECHILD, so
``drained`` becomes true only on the kernel's confirmation.  A process that refuses a signal
and a process table that cannot be read are reported the same way and never counted as gone.
The supervisor itself then keeps ``--hold-fd``, so no detached holder exists.
Forcibly terminating the supervisor abandons ownership without confirming completion.
"""

import ctypes
import errno
import json
import math
import os
import select
import signal
import sys
import time

PR_SET_PDEATHSIG = 1
PR_SET_CHILD_SUBREAPER = 36
FAILURE_STATUS = 70
SWEEP_SECONDS = 0.05
HOLDER_POLL_SECONDS = 0.5
DEFAULT_TERM_GRACE_SECONDS = 10.0
DEFAULT_KILL_GRACE_SECONDS = 5.0
OVERDUE_SWEEP_SECONDS = 0.5
OVERDUE_REPORT_SECONDS = 30.0
# Dispositions Python or a non-interactive parent shell may have changed and the
# command must not inherit.
RESET_TO_DEFAULT = (
    signal.SIGPIPE,
    signal.SIGXFSZ,
    signal.SIGINT,
    signal.SIGQUIT,
    signal.SIGTERM,
    signal.SIGHUP,
    signal.SIGCHLD,
)


class UsageError(Exception):
    pass


class Options:
    """native command一呼出し分の起動設定

    Attributes:
        term_grace: TERM送信からKILL送信までの猶予秒数
        kill_grace: KILL送信後の終了確認猶予秒数
        result_path: 完了記録の出力pathか記録無効のNone
        hold_fd: 走行中に保持する継承済みlock descriptorか未指定のNone
        argv0: commandに渡す先頭引数か実行file名を使うNone
        parent_pid: 消失時に取消を開始する親PIDか監視無効のNone
        require_drained: 子孫の回収完了まで返却を禁止する選択
        interrupt_cancels: SIGINTを走行全体の取消へ渡す明示選択
        command: 絶対実行pathを先頭に持つcommand引数列
    """

    def __init__(self):
        """session向け既定値による引数解釈前の設定生成

        Args:
            self: 解析中の一呼出し分の設定
        Returns:
            None: 初期設定の格納後の復帰値
        """
        self.term_grace = DEFAULT_TERM_GRACE_SECONDS
        self.kill_grace = DEFAULT_KILL_GRACE_SECONDS
        self.result_path = None
        self.hold_fd = None
        self.argv0 = None
        self.parent_pid = None
        self.require_drained = False
        self.interrupt_cancels = False
        self.command = []


def parse_seconds(option, value):
    try:
        seconds = float(value)
    except ValueError:
        raise UsageError(f"{option} needs a number: {value}") from None
    if not math.isfinite(seconds) or seconds <= 0:
        raise UsageError(f"{option} must be a positive number: {value}")
    return seconds


def parse_descriptor(option, value):
    if not value.isdigit() or int(value) < 3:
        raise UsageError(f"{option} needs a descriptor number of 3 or more: {value}")
    return int(value)


def parse_arguments(arguments):
    """取消方針を含むnative command起動引数の解釈

    Args:
        arguments: 実行file名を除くsupervisorの引数列
    Returns:
        Options: commandの絶対pathと取消方針を持つ設定
    Raises:
        UsageError: 未知のoptionか値の不成立かcommandの欠落
    """
    options = Options()
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            options.command = arguments[index + 1:]
            if not options.command or not os.path.isabs(options.command[0]):
                raise UsageError("the command must be an absolute executable")
            return options
        if argument == "--require-drained":
            options.require_drained = True
            index += 1
            continue
        if argument == "--interrupt-cancels":
            options.interrupt_cancels = True
            index += 1
            continue
        if argument not in ("--term-grace", "--kill-grace", "--result", "--hold-fd", "--argv0", "--parent-death-cancels"):
            raise UsageError(f"unknown option: {argument}")
        if index + 1 >= len(arguments):
            raise UsageError(f"{argument} needs a value")
        value = arguments[index + 1]
        if argument == "--term-grace":
            options.term_grace = parse_seconds(argument, value)
        elif argument == "--kill-grace":
            options.kill_grace = parse_seconds(argument, value)
        elif argument == "--hold-fd":
            options.hold_fd = parse_descriptor(argument, value)
        elif argument == "--parent-death-cancels":
            if not value.isdecimal() or int(value) < 1:
                raise UsageError(f"{argument} needs a positive caller PID: {value}")
            options.parent_pid = int(value)
        elif argument == "--argv0":
            options.argv0 = value
        else:
            options.result_path = value
        index += 2
    raise UsageError("missing -- before the command")


def prctl(option, argument):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(option, argument, 0, 0, 0) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def process_table():
    """Return {pid: (parent pid, state, start time)} for every visible process."""
    table = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat", "rb") as stream:
                data = stream.read()
        except OSError:
            continue
        # The command name may contain spaces and parentheses; the fields
        # after the last closing parenthesis are fixed.
        fields = data[data.rindex(b")") + 2:].split()
        table[int(name)] = (int(fields[1]), fields[0], fields[19])
    return table


def owned_processes():
    """Return {pid: start time} for every live descendant of this process."""
    table = process_table()
    children = {}
    for pid, (parent, state, _started) in table.items():
        if state != b"Z":
            children.setdefault(parent, []).append(pid)
    owned = {}
    pending = [os.getpid()]
    while pending:
        for pid in children.get(pending.pop(), ()):
            if pid not in owned:
                owned[pid] = table[pid][2]
                pending.append(pid)
    return owned


def send_signal(pid, number):
    try:
        os.kill(pid, number)
    except ProcessLookupError:
        pass


def diagnose(message):
    """Write one diagnostic line; a closed stderr must not end a drain that is still owed."""
    try:
        print(f"dotfiles-supervise: {message}", file=sys.stderr)
    except OSError:
        pass


def noop_handler(_number, _frame):
    pass


def hold_until_gone(survivors):
    """Detach a holder that keeps this process's descriptors until the survivors end."""
    if os.fork() != 0:
        return
    os.setsid()
    null = os.open(os.devnull, os.O_RDWR)
    for descriptor in (0, 1, 2):
        os.dup2(null, descriptor)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    while True:
        table = process_table()
        alive = [
            pid for pid, started in survivors.items()
            if pid in table and table[pid][2] == started and table[pid][1] != b"Z"
        ]
        if not alive:
            os._exit(0)
        time.sleep(HOLDER_POLL_SECONDS)


class Supervisor:
    def __init__(self, options):
        self.options = options
        self.client_pid = None
        self.client_status = None
        self.cancel_signal = None
        self.terminating = False
        self.killing = False
        self.term_deadline = None
        self.kill_deadline = None
        self.kill_grace_expired = False
        self.next_report = 0.0
        self.last_owned = set()
        self.unsignalable = set()
        self.observation_error = None
        self.wakeup_read, self.wakeup_write = os.pipe()
        os.set_blocking(self.wakeup_read, False)
        os.set_blocking(self.wakeup_write, False)

    def record(self, phase, **fields):
        path = self.options.result_path
        if path is None:
            return
        completion = {"completion": "require-drained"} if self.options.require_drained else {}
        temporary = f"{path}.{os.getpid()}.tmp"
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
        )
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump({"version": 1, "phase": phase, **completion, **fields}, stream)
                stream.write("\n")
            os.rename(temporary, path)
        except BaseException:
            try:
                os.unlink(temporary)
            except OSError:
                pass
            raise

    def install_signals(self):
        """呼出し元の取消方針に従うprocess単位のsignal登録

        Args:
            self: wakeup pipeを準備済みのsupervisor
        Returns:
            None: signal handler登録後の復帰値
        """
        signal.set_wakeup_fd(self.wakeup_write, warn_on_full_buffer=False)
        signal.signal(signal.SIGCHLD, noop_handler)
        signal.signal(signal.SIGTERM, self.request_cancel)
        signal.signal(signal.SIGHUP, self.request_cancel)
        # Operation-level cancellation belongs to the command, which receives
        # these from the terminal in the same foreground process group.
        signal.signal(signal.SIGINT, self.request_cancel if self.options.interrupt_cancels else noop_handler)
        signal.signal(signal.SIGQUIT, noop_handler)

    def request_cancel(self, number, _frame):
        if self.cancel_signal is None:
            self.cancel_signal = number

    def wait_for_event(self, timeout):
        readable, _, _ = select.select([self.wakeup_read], [], [], timeout)
        if readable:
            try:
                os.read(self.wakeup_read, 4096)
            except BlockingIOError:
                pass

    def reap(self):
        """Collect exited children; return whether any child remains."""
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return False
            if pid == 0:
                return True
            if pid == self.client_pid:
                self.client_status = os.waitstatus_to_exitcode(status)

    def begin_termination(self):
        self.terminating = True
        self.term_deadline = time.monotonic() + self.options.term_grace
        # 後始末の子まで中断するため猶予中の SIGTERM 再走査は不採用
        self.signal_owned_processes(signal.SIGTERM)

    def signal_owned_processes(self, number):
        try:
            owned = owned_processes()
        except OSError as error:
            # 例外の伝播は ECHILD の前に所有を手放すため --require-drained では不可
            if not self.options.require_drained:
                raise
            self.observation_error = str(error)
            return
        self.observation_error = None
        self.last_owned = set(owned)
        for pid in owned:
            self.send_to_owned(pid, number)
            if number == signal.SIGTERM:
                self.send_to_owned(pid, signal.SIGCONT)

    def send_to_owned(self, pid, number):
        """Send a signal; under --require-drained remember a pid that refuses it."""
        try:
            send_signal(pid, number)
        except PermissionError:
            if not self.options.require_drained:
                raise
            self.unsignalable.add(pid)
        else:
            self.unsignalable.discard(pid)

    def report_overdue(self, now):
        """Report that children outlived the SIGKILL grace and that the wait goes on."""
        if now < self.next_report:
            return
        self.next_report = now + OVERDUE_REPORT_SECONDS
        late = now - self.kill_deadline
        remaining = sorted(self.last_owned)
        unsignalable = sorted(self.unsignalable & self.last_owned)
        diagnose(
            f"children remain {late:.0f}s past the SIGKILL grace; waiting for the kernel to confirm exit of: "
            + (" ".join(map(str, remaining)) or "none visible")
        )
        if unsignalable:
            diagnose("cannot signal: " + " ".join(map(str, unsignalable)))
        if self.observation_error is not None:
            diagnose(f"cannot read the process table: {self.observation_error}")
        try:
            self.record(
                "draining",
                spawned=True,
                cancelled=self.cancel_signal is not None,
                drained=False,
                client_status=self.client_status,
                remaining=remaining,
                unsignalable=unsignalable,
                observation_error=self.observation_error,
                seconds_past_kill_grace=round(late, 1),
            )
        except OSError as error:
            diagnose(f"cannot record the draining state: {error}")

    def supervise(self):
        """Return True when the kernel confirmed that no owned process is left.

        Return False only without --require-drained, once SIGKILL had its grace period.
        """
        while True:
            children_exist = self.reap()
            if not self.terminating and (
                self.cancel_signal is not None or self.client_status is not None
            ):
                self.begin_termination()
            if not self.terminating:
                self.wait_for_event(None)
                continue
            if not children_exist:
                return True
            now = time.monotonic()
            overdue = self.killing and now >= self.kill_deadline
            if overdue and not self.options.require_drained:
                return False
            if overdue:
                self.kill_grace_expired = True
                self.report_overdue(now)
            if not self.killing and now >= self.term_deadline:
                self.killing = True
                self.kill_deadline = now + self.options.kill_grace
            if self.killing:
                self.signal_owned_processes(signal.SIGKILL)
            # 猶予後の待ちには上限がなく SWEEP_SECONDS 間隔の全 process 走査は CPU を使い続けるため同間隔は不可
            self.wait_for_event(OVERDUE_SWEEP_SECONDS if overdue else SWEEP_SECONDS)

    def exit_status(self, drained):
        status = self.client_status
        if status is None:
            return FAILURE_STATUS
        if status < 0:
            status = 128 - status
        if not drained and status == 0:
            return FAILURE_STATUS
        return status

    def prepare(self):
        """Take everything the session depends on before the command may start."""
        if self.options.require_drained and os.getpid() not in process_table():
            raise OSError(errno.ESRCH, "this process is absent from /proc, so owned children cannot be observed")
        prctl(PR_SET_CHILD_SUBREAPER, 1)
        if self.options.hold_fd is not None:
            os.fstat(self.options.hold_fd)
            # The held descriptor must not reach the command or anything it starts.
            os.set_inheritable(self.options.hold_fd, False)
        if self.options.parent_pid is not None:
            prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
        self.install_signals()
        self.record("started", spawned=False)
        # PDEATHSIG 設定前の親の終了は通知されないため起動後の getppid だけによる親の確定は不可
        if self.options.parent_pid is not None and os.getppid() != self.options.parent_pid:
            self.request_cancel(signal.SIGTERM, None)

    def run(self):
        self.prepare()
        if self.cancel_signal is not None:
            status = 128 + self.cancel_signal
            self.record("finished", spawned=False, cancelled=True, drained=True,
                        client_status=None, remaining=[], status=status)
            return status
        command = self.options.command
        argv = list(command)
        if self.options.argv0 is not None:
            # The executed file and the name it is told it has are separate: a multi-call binary reached through
            # a symlink chooses its behavior from that name.
            argv[0] = self.options.argv0
        try:
            self.client_pid = os.posix_spawn(
                command[0],
                argv,
                os.environ,
                setsigmask=(),
                setsigdef=RESET_TO_DEFAULT,
            )
        except OSError as error:
            status = 127 if error.errno == errno.ENOENT else 126
            print(f"dotfiles-supervise: cannot execute {command[0]}: {error.strerror}",
                  file=sys.stderr)
            self.record("finished", spawned=False, cancelled=False, drained=True,
                        client_status=None, remaining=[], status=status)
            return status
        drained = self.supervise()
        survivors = owned_processes() if not drained else {}
        if not drained:
            print("dotfiles-supervise: processes still alive after SIGKILL: "
                  + " ".join(map(str, sorted(survivors))), file=sys.stderr)
        status = self.exit_status(drained)
        expiry = {"kill_grace_expired": self.kill_grace_expired} if self.options.require_drained else {}
        self.record(
            "finished",
            spawned=True,
            cancelled=self.cancel_signal is not None,
            drained=drained,
            client_status=self.client_status,
            remaining=sorted(survivors),
            status=status,
            **expiry,
        )
        if survivors and self.options.hold_fd is not None:
            hold_until_gone(survivors)
        return status


def main(arguments):
    try:
        options = parse_arguments(arguments)
    except UsageError as error:
        print(f"dotfiles-supervise: {error}", file=sys.stderr)
        return 2
    try:
        return Supervisor(options).run()
    except OSError as error:
        print(f"dotfiles-supervise: {error}", file=sys.stderr)
        return FAILURE_STATUS


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
