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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from admission import AdmissionError, Admission
from demand import DemandHistory
from measure import emit

PR_SET_PDEATHSIG = 1
PR_SET_CHILD_SUBREAPER = 36
FAILURE_STATUS = 70
SWEEP_SECONDS = 0.05
HOLDER_POLL_SECONDS = 0.5
DEFAULT_TERM_GRACE_SECONDS = 10.0
DEFAULT_KILL_GRACE_SECONDS = 5.0
OVERDUE_SWEEP_SECONDS = 0.5
OVERDUE_REPORT_SECONDS = 30.0
MEASURE_SECONDS = 1.0
# 走行の scope の cgroup から読む CPU時間と滞留の合計の項目。滞留は pressure file の total=（microseconds）で、
# CPU は some、IO と memory は full の行を読む。--result と計測の一行はこの名前で秒（ミリ秒精度）を持つ
SCOPE_READINGS = ("cpuSeconds", "cpuStallSeconds", "ioStallSeconds", "memoryStallSeconds")
# 入場できないまま待機の上限に達した走行の終了status。commandは起動していない
WAIT_EXPIRED_STATUS = 75
# systemd-run が作った scope へ入るまでの猶予秒数
SCOPE_ENTRY_SECONDS = 10.0
ENTER_SCOPE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "enter_scope.py")
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
        resource_policy: hostの資源観測と予約既定値のpathか無効のNone
        resource_wait_until: 入場を待つ絶対期限か無効のNone。走行の秒数とは別に数える
        resource_run_seconds: 入場してから数える走行の秒数か無効のNone
        resource_target_seconds: 入場してから数える走行の秒数がこの値へ達した時点の読取を残す秒数か無効のNone。取消にも期限にも使わない
        resource_slot_wait_seconds: 呼び出し側が実行枠の取得に待った秒数か枠を使わなかった走行のNone。supervisor は枠を持たず、値を記録へ運ぶだけで、待機にも期限にも使わない
        resource_memory: 物理memory予約の明示値か既定値を選ぶNone
        resource_key: 実測した需要の記録を読み書きする鍵か記録しないNone
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
        self.resource_policy = None
        self.resource_wait_until = None
        self.resource_run_seconds = None
        self.resource_target_seconds = None
        self.resource_slot_wait_seconds = None
        self.resource_memory = None
        self.resource_key = None


def parse_seconds(option, value, allow_zero=False):
    try:
        seconds = float(value)
    except ValueError:
        raise UsageError(f"{option} needs a number: {value}") from None
    if not math.isfinite(seconds) or seconds < 0 or (seconds == 0 and not allow_zero):
        raise UsageError(f"{option} must be {'zero or ' if allow_zero else ''}a positive number: {value}")
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
            if options.resource_policy is not None:
                if options.resource_wait_until is None or options.resource_run_seconds is None:
                    raise UsageError("--resource-policy requires --resource-wait-until and --resource-run-seconds")
                options.require_drained = True
            elif (options.resource_wait_until is not None or options.resource_run_seconds is not None
                  or options.resource_target_seconds is not None or options.resource_slot_wait_seconds is not None):
                raise UsageError(
                    "--resource-wait-until, --resource-run-seconds, --resource-target-seconds and --resource-slot-wait "
                    "require --resource-policy")
            return options
        if argument == "--require-drained":
            options.require_drained = True
            index += 1
            continue
        if argument == "--interrupt-cancels":
            options.interrupt_cancels = True
            index += 1
            continue
        if argument not in ("--term-grace", "--kill-grace", "--result", "--hold-fd", "--argv0", "--parent-death-cancels",
                            "--resource-policy", "--resource-wait-until", "--resource-run-seconds", "--resource-memory",
                            "--resource-key", "--resource-target-seconds", "--resource-slot-wait"):
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
        elif argument == "--resource-policy":
            options.resource_policy = value
        elif argument == "--resource-key":
            if not value:
                raise UsageError(f"{argument} needs a non-empty value")
            options.resource_key = value
        elif argument == "--resource-wait-until":
            options.resource_wait_until = parse_seconds(argument, value)
        elif argument == "--resource-run-seconds":
            options.resource_run_seconds = parse_seconds(argument, value)
        elif argument == "--resource-target-seconds":
            options.resource_target_seconds = parse_seconds(argument, value)
        elif argument == "--resource-slot-wait":
            options.resource_slot_wait_seconds = parse_seconds(argument, value, allow_zero=True)
        elif argument == "--resource-memory":
            if not value.isdecimal() or int(value) <= 0:
                raise UsageError(f"{argument} needs a positive integer")
            options.resource_memory = int(value)
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


def pss_bytes(pid):
    """processのPSS取得

    pid: 読取対象のPID
    戻り値: /proc/<pid>/smaps_rollup の Pss のbyte数。値が無ければ0
    失敗: 消失または読取不能なprocessによるOSErrorかValueError
    """
    with open(f"/proc/{pid}/smaps_rollup") as stream:
        for line in stream:
            if line.startswith("Pss:"):
                return int(line.split()[1]) * 1024
    return 0


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


class PeakMeter:
    """所有する子孫のPSS合計の最大値の保持

    Attributes:
        peak: これまでに測った合計のbyte数。一度も測れなければ0
        due: 次に測る単調時計の時刻
    """

    def __init__(self):
        """測定前の状態の生成

        Args:
            self: 測定を始める前の保持者
        Returns:
            None: 初期状態の格納後の復帰値
        """
        self.peak = 0
        self.due = 0.0

    def sample(self):
        """間隔が過ぎている場合だけの所有子孫のPSS合計の測定

        Args:
            self: 測定を保持する測定器
        Returns:
            float: 次の測定までの秒数
        """
        now = time.monotonic()
        if now >= self.due:
            self.due = now + MEASURE_SECONDS
            total = 0
            # 測定の失敗で所有の監督を終えないため、読めないprocessは飛ばす
            try:
                for pid in owned_processes():
                    try:
                        total += pss_bytes(pid)
                    except (OSError, ValueError):
                        continue
            except (OSError, ValueError, IndexError):
                return MEASURE_SECONDS
            self.peak = max(self.peak, total)
        return max(0.0, self.due - time.monotonic())


def usage_microseconds(path):
    """cpu.stat の usage_usec の読取

    path: scope の cpu.stat
    戻り値: 子孫の終了した分を含む CPU時間の microseconds
    失敗: 読めない場合の OSError と、usage_usec の行が無い、または数でない場合の ValueError
    """
    for line in path.read_text().splitlines():
        name, _, value = line.partition(" ")
        if name == "usage_usec":
            return int(value)
    raise ValueError(f"{path} has no usage_usec")


def stall_microseconds(path, kind):
    """pressure file の滞留の合計の読取

    path: scope の cpu.pressure、io.pressure、memory.pressure
    kind: 読む行。some か full
    戻り値: 作成からの滞留の microseconds
    失敗: 読めない場合の OSError と、行か total= が無い、または数でない場合の ValueError か KeyError
    """
    for line in path.read_text().splitlines():
        fields = line.split()
        if fields[:1] == [kind]:
            return int(dict(field.split("=", 1) for field in fields[1:])["total"])
    raise ValueError(f"{path} has no {kind} line")


def scope_readings(directory):
    """走行の scope の cgroup が持つ CPU時間と滞留の合計の読取

    directory: scope の cgroup directory。scope を作らない走行はNone
    戻り値: SCOPE_READINGS の各項目を秒（ミリ秒精度）で持つ辞書。読めない項目と scope の無い走行はNone
    制約: 項目ごとに読み、一つの失敗で他の項目を捨てない。失敗は走行の終了statusを変えない
    """
    readings = dict.fromkeys(SCOPE_READINGS)
    if directory is None:
        return readings
    for field, read in (
        ("cpuSeconds", lambda: usage_microseconds(directory / "cpu.stat")),
        ("cpuStallSeconds", lambda: stall_microseconds(directory / "cpu.pressure", "some")),
        ("ioStallSeconds", lambda: stall_microseconds(directory / "io.pressure", "full")),
        ("memoryStallSeconds", lambda: stall_microseconds(directory / "memory.pressure", "full")),
    ):
        try:
            readings[field] = round(read() / 1_000_000, 3)
        except (OSError, ValueError, KeyError):
            pass
    return readings


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
        self.reservation = None
        self.drained = True
        self.deadline_expired = False
        # 受入が memory のために取り消した走行か。command の終了 status からは推し量らず、取り消した側の記録で知る
        self.cancelled_externally = False
        # 走行の枠を超えたと判定する時刻。入場して起動した時から数え、待機の秒数は含まない
        self.run_deadline = None
        self.spawned_at = None
        self.meter = PeakMeter() if options.resource_policy is not None else None
        self.history = None
        # 計測の一行へ渡す入場の成否と、待機と走行の時間。単調時計で測り、待たなかった走行の待機は0
        self.admitted = False
        self.wait_seconds = 0.0
        self.run_seconds = None
        # scope から読んだ直近の値。scope は最後の process の終了で消えるため、終了時の読取に失敗しても前の値を残す
        self.readings = dict.fromkeys(SCOPE_READINGS)
        self.reading_due = 0.0
        # 走行の枠が目標へ達する単調時計の時刻と、その時点の読取。目標を持たない走行はNone、読取は目標の前に終えた走行でもNone
        self.target_at = None
        self.at_target = None

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
        # scope は最後の process の終了で消えるため、signal を送る前に終了時の値を読む
        self.read_scope()
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
            sampling = self.meter.sample() if self.meter is not None and not self.terminating else None
            reading = self.sample_scope() if not self.terminating else None
            self.record_at_target()
            children_exist = self.reap()
            if self.run_deadline is not None and time.time() >= self.run_deadline:
                self.deadline_expired = True
                self.request_cancel(signal.SIGTERM, None)
            if not self.terminating and (
                self.cancel_signal is not None or self.client_status is not None
            ):
                self.begin_termination()
            if not self.terminating:
                wait = max(0, self.run_deadline - time.time()) if self.run_deadline is not None else None
                for due in (sampling, reading, self.until_target()):
                    if due is not None:
                        wait = due if wait is None else min(wait, due)
                self.wait_for_event(wait)
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
        if self.deadline_expired:
            return 124
        if self.cancelled_externally:
            return 128 + signal.SIGTERM
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

    def recorded_demand(self):
        """鍵が示す実測の記録の準備と、記録からの物理memory需要の取得

        Args:
            self: 解析済みの設定を持つsupervisor
        Returns:
            int | None: 明示需要が無く、記録が使える場合の需要。それ以外はNone
        副作用: 記録の読取に失敗した場合のstderrへの一行。走行は鍵の記録が無い場合と同じ予約で続く
        """
        if self.options.resource_key is None:
            return None
        try:
            self.history = DemandHistory(self.options.resource_key)
            if self.options.resource_memory is None:
                return self.history.recorded_demand()
        except (OSError, ValueError) as error:
            diagnose(f"cannot read the measured memory demand: {error}")
        return None

    def host_demand(self):
        """鍵の記録が無い走行が、この host の他の鍵の実測から導く物理memory需要の取得

        Args:
            self: recorded_demand を呼んだ後のsupervisor
        Returns:
            int | None: 鍵を渡した、明示需要の無い走行で、他の鍵に使える記録がある場合の需要。それ以外はNone
        """
        if self.history is None or self.options.resource_memory is not None:
            return None
        return self.history.host_demand()

    def records_peak(self, drained, exceeded):
        """測ったピークを記録してよい走行の判定

        Args:
            drained: 子孫の終了をkernelが確認した選択
            exceeded: 測ったピークが予約を超えた選択
        Returns:
            bool: 子孫の回収を確認でき、commandが自分で0で終了した走行か、ピークが予約を超えた走行のTrue
        制約: 失敗、予算切れ、取消の走行は入口の途中で止まり、ピークが需要を下回るため、記録すると次の予約を下げる。
            予約を超えたピークは途中で止まった走行でも需要の下限であり、記録は次の予約を上げる向きにしか働かない
        """
        if not drained:
            return False
        if self.cancelled_externally:
            return False
        if exceeded:
            return True
        return self.cancel_signal is None and not self.deadline_expired and self.client_status == 0

    def observe_memory(self, drained):
        """測ったピークの予約との照合と記録

        Args:
            drained: 子孫の終了をkernelが確認した選択
        Returns:
            dict: --resultへ足す測定の項目。資源予約のない走行は空
        副作用: 予約の超過のstderrへの一行と、記録できる走行の実測の追記。追記の失敗はstderrへ一行を出し、終了statusを変えない
        """
        if self.reservation is None:
            return {}
        peak = self.meter.peak
        reserved = self.reservation.memory
        exceeded = peak > reserved
        if exceeded:
            diagnose(f"measured memory peak {peak} bytes exceeded the reservation {reserved} bytes")
        if self.history is not None and peak > 0 and self.records_peak(drained, exceeded):
            try:
                self.history.append({"at": int(time.time()), "peakBytes": peak, "reservedBytes": reserved,
                                     "exceeded": exceeded})
            except (OSError, ValueError) as error:
                diagnose(f"cannot record the measured memory peak: {error}")
        return {"memoryPeakBytes": peak, "memoryReservedBytes": reserved, "waitSeconds": round(self.wait_seconds, 3),
                "slotWaitSeconds": self.slot_wait()}

    def slot_wait(self):
        """呼び出し側が実行枠の取得に待った秒数。--result と計測の一行が同じ値を持つ。枠を使わなかった走行はNone"""
        seconds = self.options.resource_slot_wait_seconds
        return None if seconds is None else round(seconds, 3)

    def scope_directory(self):
        """この走行の scope の cgroup directory。資源予約を持たない走行と、scope を作らない入れ子の走行はNone"""
        return None if self.reservation is None else self.reservation.scope_directory()

    def read_scope(self):
        """scope の読取の保持値への重ね書き。読めなかった項目は前の値を残す"""
        for field, value in scope_readings(self.scope_directory()).items():
            if value is not None:
                self.readings[field] = value

    def sample_scope(self):
        """間隔が過ぎている場合だけの scope の読取。終了時に scope が残っていない場合の備え

        戻り値: 次の読取までの秒数。scope を持たない走行はNone
        """
        if self.scope_directory() is None:
            return None
        now = time.monotonic()
        if now >= self.reading_due:
            self.reading_due = now + MEASURE_SECONDS
            self.read_scope()
        return max(0.0, self.reading_due - time.monotonic())

    def until_target(self):
        """走行の枠が目標へ達するまでの秒数。目標を持たない走行と、目標の時点の読取を終えた走行はNone"""
        if self.target_at is None or self.at_target is not None:
            return None
        return max(0.0, self.target_at - time.monotonic())

    def record_at_target(self):
        """走行の枠が目標へ達した時点の scope の読取。一度だけ読み、取消にも期限の変更にも使わない"""
        if self.target_at is not None and self.at_target is None and time.monotonic() >= self.target_at:
            self.at_target = scope_readings(self.scope_directory())

    def scope_report(self):
        """終了時の読取と、目標と、目標の時点の読取。--result と計測の一行が同じ値を持つ"""
        target = self.options.resource_target_seconds
        if target is not None and target.is_integer():
            target = int(target)
        return {**self.readings, "targetSeconds": target, "atTarget": self.at_target}

    def observe_scope(self):
        """走行の秒数と scope の読取の --result への項目。資源予約のない走行は空"""
        if self.reservation is None:
            return {}
        return {"runSeconds": round(self.run_seconds, 3), **self.scope_report()}

    def start_run_clock(self):
        """走行の枠を、client を起動した時点から数え始める。待機の秒数は枠に数えない"""
        self.spawned_at = time.monotonic()
        if self.options.resource_run_seconds is not None:
            self.run_deadline = time.time() + self.options.resource_run_seconds
        if self.options.resource_target_seconds is not None:
            self.target_at = self.spawned_at + self.options.resource_target_seconds

    def abandon_entry(self):
        """scope へ入る前に止まっている client を殺して回収する"""
        os.kill(self.client_pid, signal.SIGKILL)
        os.waitpid(self.client_pid, 0)
        self.client_pid = None
        self.drained = True

    def launch_in_scope(self, prefix, oom_score, wait_until):
        """判定の排他の中で、走行ごとの scope を作り、その中で client を起動する

        prefix: systemd-run で scope を作る argv。この後ろに -- と helper が続く
        oom_score: scope の中の process へ設定する oom_score_adj
        wait_until: 待機の絶対期限。scope を作る待ちも待機に数え、期限が来れば入場しない
        戻り値: scope に入って起動した場合のTrue。scope へ入る前に取消された場合と待機の期限が来た場合のFalse
        失敗: scope を作れない、または猶予内に入れない場合の AdmissionError
        制約: helper は scope に入った後に自分を止め、ここで scope の存在を確かめてから再開する。
            再開前の client は command を実行していないので、取消や失敗や期限切れでは何も実行されていない
        """
        command = self.options.command
        argv0 = self.options.argv0 if self.options.argv0 is not None else command[0]
        helper = [sys.executable, "-I", "-S", ENTER_SCOPE, str(oom_score), command[0], argv0, *command[1:]]
        argv = [*prefix, "--", *helper]
        try:
            self.client_pid = os.posix_spawn(argv[0], argv, dict(os.environ), setsigmask=(), setsigdef=RESET_TO_DEFAULT)
        except OSError as error:
            raise AdmissionError(f"cannot create the scope: cannot execute {argv[0]}: {error.strerror}") from None
        self.drained = False
        until = time.monotonic() + SCOPE_ENTRY_SECONDS
        while True:
            pid, status = os.waitpid(self.client_pid, os.WNOHANG | os.WUNTRACED)
            if pid:
                if os.WIFSTOPPED(status):
                    break
                self.client_pid = None
                self.drained = True
                raise AdmissionError(
                    f"cannot create the scope: {argv[0]} ended with status {os.waitstatus_to_exitcode(status)}")
            if self.cancel_signal is not None or time.time() >= wait_until:
                self.abandon_entry()
                return False
            if time.monotonic() >= until:
                self.abandon_entry()
                raise AdmissionError(f"cannot create the scope: {argv[0]} did not enter it within {SCOPE_ENTRY_SECONDS:.0f}s")
            self.wait_for_event(0.01)
        os.kill(self.client_pid, signal.SIGCONT)
        self.start_run_clock()
        return True

    def spawn_plain(self):
        """scope を作らずに client を起動する。入れ子の走行と、資源予約を持たない走行

        戻り値: 起動した場合のNone、起動できなかった場合の終了status
        """
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
                dict(os.environ),
                setsigmask=(),
                setsigdef=RESET_TO_DEFAULT,
            )
            self.drained = False
        except OSError as error:
            status = 127 if error.errno == errno.ENOENT else 126
            print(f"dotfiles-supervise: cannot execute {command[0]}: {error.strerror}",
                  file=sys.stderr)
            self.record("finished", spawned=False, cancelled=False, drained=True,
                        client_status=None, remaining=[], status=status)
            return status
        self.start_run_clock()
        return None

    def finish_unstarted(self):
        """入場できないまま取消か待機の上限に達した走行の終了。command は起動していない

        戻り値: 取消なら 128 に signal 番号を加えた値、待機の上限なら 75
        """
        if self.cancel_signal is not None:
            status = 128 + self.cancel_signal
        else:
            status = WAIT_EXPIRED_STATUS
            diagnose(f"gave up waiting for resources after {self.wait_seconds:.0f}s; the command was not started")
        self.record("finished", spawned=False, deferred=True, drained=True, client_status=None, remaining=[],
                    status=status, waitSeconds=round(self.wait_seconds, 3), slotWaitSeconds=self.slot_wait())
        return status

    def run(self):
        self.prepare()
        if self.options.resource_policy is not None and self.cancel_signal is None:
            recorded = self.recorded_demand()
            self.reservation = Admission(
                self.options.resource_policy, self.options.resource_memory, recorded,
                self.host_demand() if recorded is None else None,
            )
            waiting_since = time.monotonic()
            try:
                self.admitted = self.reservation.acquire(self, self.options.resource_wait_until, self.launch_in_scope)
            finally:
                self.wait_seconds = time.monotonic() - waiting_since
            if not self.admitted:
                return self.finish_unstarted()
        # 入れ子と資源予約の無い走行は scope を作らないので、ここで起動する。scope へ起動した走行は起動済み
        if self.client_pid is None:
            if self.cancel_signal is not None:
                status = 128 + self.cancel_signal
                self.record("finished", spawned=False, cancelled=True, drained=True,
                            client_status=None, remaining=[], status=status)
                return status
            status = self.spawn_plain()
            if status is not None:
                return status
        drained = self.supervise()
        self.cancelled_externally = self.reservation is not None and self.reservation.cancelled()
        self.run_seconds = time.monotonic() - self.spawned_at
        self.drained = drained
        survivors = owned_processes() if not drained else {}
        if not drained:
            print("dotfiles-supervise: processes still alive after SIGKILL: "
                  + " ".join(map(str, sorted(survivors))), file=sys.stderr)
        status = self.exit_status(drained)
        expiry = {"kill_grace_expired": self.kill_grace_expired} if self.options.require_drained else {}
        memory = self.observe_memory(drained)
        self.record(
            "finished",
            spawned=True,
            cancelled=self.cancel_signal is not None or self.cancelled_externally,
            drained=drained,
            client_status=self.client_status,
            remaining=sorted(survivors),
            status=status,
            **expiry,
            **memory,
            **self.observe_scope(),
        )
        if survivors and self.options.hold_fd is not None:
            hold_until_gone(survivors)
        return status

    def report(self, status):
        """資源予約を持つ走行一回の計測の journald への送出

        status: この走行が返す終了status
        戻り値: なし
        副作用: 資源予約を持つ走行だけが一行を送る。送れない場合はstderrへ一行を出し、終了statusを変えない
        """
        reservation = self.reservation
        if reservation is None:
            return
        record = {
            "event": "workload",
            "class": reservation.ran_as,
            "key": self.options.resource_key,
            "nested": reservation.inherited,
            "admitted": self.admitted,
            "waitSeconds": round(self.wait_seconds, 3),
            "slotWaitSeconds": self.slot_wait(),
            "waitReasons": reservation.reasons,
            "runSeconds": None if self.run_seconds is None else round(self.run_seconds, 3),
            "status": status,
            "peakBytes": self.meter.peak,
            "reservedBytes": reservation.memory,
            **self.scope_report(),
        }
        try:
            emit(reservation.policy.journal, record)
        except OSError as error:
            diagnose(f"cannot record the measurement in the journal: {error}")


def main(arguments):
    try:
        options = parse_arguments(arguments)
    except UsageError as error:
        print(f"dotfiles-supervise: {error}", file=sys.stderr)
        return 2
    supervisor = Supervisor(options)
    status = FAILURE_STATUS
    try:
        status = supervisor.run()
        return status
    except (OSError, AdmissionError, ValueError, KeyError, TypeError) as error:
        print(f"dotfiles-supervise: {error}", file=sys.stderr)
        return FAILURE_STATUS
    finally:
        supervisor.report(status)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
