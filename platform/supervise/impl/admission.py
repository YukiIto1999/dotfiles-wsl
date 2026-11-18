"""資源観測に基づく class ごとの入場と、走行ごとの scope が持つ将来消費の読取

受入（待つ者のいる検証）は他の受入に待たされず、deep（待つ者のいない検証）は受入が待つ間は入場せず、受入が
memory で収まらないときは取り消される。走行の所有と生死は走行ごとの scope の cgroup が持ち、この module は
記録 file を持たない。
"""

import fcntl
import json
import math
import os
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tempfile
import time
import sys
import uuid

from measure import JOURNAL_SOCKET

CLASSES = ("acceptance", "deep")
# 一走行の計測へ残す待機理由の最大の件数
MAXIMUM_REASONS = 8
# 入場を止めない観測の status。受入は警告まで通して failure だけで止め、deep は警告でも止める。未知の status はどちらも止める
PASSING = {"acceptance": ("pass", "warn"), "deep": ("pass",)}
# scope が持つ需要を書く file。受入は予約の記録の memory.low、deep は上限の memory.high。どちらも保護や hard limit にはしない
DEMAND_FILES = {"acceptance": "memory.low", "deep": "memory.high"}
DEMAND_PROPERTIES = {"acceptance": "MemoryLow", "deep": "MemoryHigh"}
# deep は kernel の OOM で最初に選ばれる。受入と session は上げない
OOM_SCORES = {"acceptance": 0, "deep": 1000}
# 取り消された scope の SIGTERM から SIGKILL までの猶予。supervisor の既定の猶予と同じ
STOP_TIMEOUT = "10s"
STOP_SECONDS = 5
REGISTRY_LOCK = "registry.lock"
# 受入が待つ間だけ共有 lock を持つ file。deep は排他で試して取れなければ受入が待つと判る
WAITING_LOCK = "acceptance.waiting"
# 受入が deep の scope を取り消すときに残す記録の名前の前置。scope 名を続ける。deep の supervisor が終了時に読んで消す
CANCEL_MARK = "cancel-"
# 読まれないまま scope が消えた取消の記録を片付ける経過秒数。supervisor が強制終了されたときだけ残る
STALE_MARK_SECONDS = 3600
ADMIT, WAIT, CANCEL_DEEP = "admit", "wait", "cancel-deep"
HEADROOM_REASON = "Linux memory or Windows commit headroom is reserved"


class AdmissionError(Exception):
    """実行を開始できない資源契約の不成立"""


def positive(value, name):
    """有限の正整数である予約値の確認

    value: 確認対象の値
    name: 診断用の項目名
    戻り値: 確認済みの整数
    失敗: 不正な値による AdmissionError
    """
    if type(value) is not int or value <= 0:
        raise AdmissionError(f"{name} must be a positive integer")
    return value


@dataclass(frozen=True)
class Scope:
    """class の slice の下で動く走行一つの scope

    klass: 走行の class
    unit: scope の unit 名
    limit: 受入では memory.low、deep では memory.high の bytes。読めなければ0
    working_set: 観測が報告した、回収できる cache を除いた使用量。報告が無い scope は0で、予約の全部がこれから使われると見る
    """

    klass: str
    unit: str
    limit: int
    working_set: int


@dataclass(frozen=True)
class Observation:
    """入場の判定に使う空きの観測

    host_headroom: host の空き
    commit_headroom: Windows の commit の、警告の割合までの余裕
    commit_growth: VM がこれから Windows の commit を増やせる量の上限。観測が求められないときは None
    limits: 祖先の cgroup ごとの（path、空き）
    usage: class の slice の下の scope ごとの、cgroup path から観測が求めた working set への対応
    """

    host_headroom: int
    commit_headroom: int
    commit_growth: int | None
    limits: tuple
    usage: dict


@dataclass(frozen=True)
class Decision:
    """入場の判定の結果

    kind: ADMIT、WAIT、CANCEL_DEEP のいずれか
    reason: ADMIT 以外で待つ理由
    """

    kind: str
    reason: str = None


def growth(scope):
    """走行中の受入の scope がこれから使い増せる量

    scope: 受入の scope
    戻り値: 予約と現在の使用量の差。すでに予約を超えている scope はこれ以上を要求しない
    """
    return max(scope.limit - scope.working_set, 0)


def cancellable(scopes):
    """受入が memory を要るときに取り消してよい scope

    scopes: 存在する scope
    戻り値: deep の scope だけ。受入と session は含まない
    """
    return [scope for scope in scopes if scope.klass == "deep"]


def shortfall(demand, scopes, observation):
    """要求が、走行中の受入が使い増せる量を含めて空きに収まらない理由

    demand: 要求する物理memory
    scopes: 存在する scope
    observation: 空きの観測
    戻り値: 収まる場合は None、収まらない場合は理由。deep の scope の増分は数えない
    制約: Windows の commit の余裕には、必要量と VM が commit を増やせる量の小さい方を数える。
        VM へ commit 済みの page は再利用されて新たな commit を要さず、VM が増やせる commit は稼働中の memory の残りまでに限られるため。
        増やせる量が不明なら必要量の全量を数える
    """
    claim = sum(growth(scope) for scope in scopes if scope.klass == "acceptance")
    need = demand + claim
    if need > observation.host_headroom:
        return HEADROOM_REASON
    commit_charge = need if observation.commit_growth is None else min(need, observation.commit_growth)
    if commit_charge > observation.commit_headroom:
        return HEADROOM_REASON
    for path, headroom in observation.limits:
        if need > headroom:
            return f"memory headroom is reserved at {path}"
    return None


def decide(klass, demand, scopes, observation, acceptance_waiting):
    """入場の判定。観測と存在する scope だけで決まる

    klass: 要求する走行の class
    demand: 要求する物理memory
    scopes: 存在する scope
    observation: 空きの観測
    acceptance_waiting: 待っている受入があるか
    戻り値: 入場、待機、deep の取消のいずれか
    不変条件:
      受入の入場は他の受入が待つことで止まらない。
      受入が待つ間は deep を入場させない。deep は同時に一走行だけ。
      入場した受入の増分の合計は各空きを超えない。
      受入が memory で収まらず deep の scope があれば、deep だけを取り消す。
    """
    if klass == "deep":
        if acceptance_waiting:
            return Decision(WAIT, "an acceptance verification is waiting")
        if cancellable(scopes):
            return Decision(WAIT, "another deep verification is running")
    reason = shortfall(demand, scopes, observation)
    if reason is None:
        return Decision(ADMIT)
    if klass == "acceptance" and cancellable(scopes):
        return Decision(CANCEL_DEEP, reason)
    return Decision(WAIT, reason)


def cgroup_integer(path):
    """memory controller の file が持つ bytes の読取

    path: memory.low や memory.high などの file
    戻り値: bytes。max は None
    失敗: 読めない場合の OSError と、数でない内容の ValueError
    """
    text = path.read_text().strip()
    return None if text == "max" else int(text)


class Policy:
    """class ごとの policy file の検証済みの値

    寿命: 一呼出し
    失敗: 欠落や不正な項目による AdmissionError か KeyError
    """

    def __init__(self, path):
        with open(path) as stream:
            document = json.load(stream)
        self.klass = document["class"]
        if self.klass not in CLASSES:
            raise AdmissionError(f"class must be one of {', '.join(CLASSES)}")
        self.runtime = Path(document["runtimeDirectory"])
        if not self.runtime.is_absolute():
            raise AdmissionError("reservation directory must be absolute")
        self.percent = document["memoryPercent"]
        if type(self.percent) is not int or not 1 <= self.percent <= 100:
            raise AdmissionError("memoryPercent must be an integer from 1 to 100")
        self.observation = document["observation"]
        self.maximum_age = document["maximumObservationAgeSeconds"]
        # systemd-run と systemctl は argv の前置として持ち、検査が代替を渡せる
        self.systemd_run = document["systemdRun"]
        self.systemctl = document["systemctl"]
        self.cgroup_root = Path(document["cgroupRoot"])
        self.slices = document["slices"]
        self.proc_cgroup = Path(document.get("procCgroup", "/proc/self/cgroup"))
        self.journal = document.get("journalSocket", JOURNAL_SOCKET)

    def slice_directory(self, klass):
        """class の slice の cgroup directory。利用者の systemd manager の下に置く"""
        uid = os.getuid()
        return self.cgroup_root / "user.slice" / f"user-{uid}.slice" / f"user@{uid}.service" / self.slices[klass]

    def slice_unit(self, klass):
        """class の slice の unit 名"""
        return Path(self.slices[klass]).name


class Admission:
    """一走行の入場。待機、判定、scope の起動までを持つ

    policy_path: class ごとの policy file
    memory_bytes: 明示された物理memory需要か導出に任せるNone
    recorded_bytes: 実測の記録から導いた物理memory需要か記録なしのNone
    host_median_bytes: 鍵の記録が無い走行が、この host の他の鍵の実測から導いた物理memory需要か導けないNone。入れ子は使わない
    寿命: supervisor による子孫終了確認まで。持つ状態は scope の cgroup と、process が持つ flock だけ
    制約: 明示でない物理memory需要は最初の有効な観測か外側の scope で確定し、それまでは未確定のNone
    """

    def __init__(self, policy_path, memory_bytes=None, recorded_bytes=None, host_median_bytes=None):
        self.policy = Policy(policy_path)
        self.klass = self.policy.klass
        # 入れ子の走行は外側の class で走る
        self.ran_as = self.klass
        self.policy.runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.policy.runtime.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise AdmissionError("reservation directory must be private and owned by this user")
        self.explicit = positive(memory_bytes, "memory request") if memory_bytes is not None else None
        self.recorded = recorded_bytes
        self.host_median = host_median_bytes
        self.memory = self.explicit
        self.inherited = False
        self.previous_reason = None
        # 起動した scope の unit 名。受入が取り消したかをこの名前の記録で知る
        self.unit = None
        # 入れ子の走行が居る外側の scope の unit 名。外側が取り消されたかをこの名前の記録で知る
        self.enclosing = None
        # 取り消しを要求済みの scope の unit 名
        self.stopping = set()
        # 待機した理由を最初に現れた順に重複なく残す。計測の一行へ渡す
        self.reasons = []

    def settle_memory(self, value):
        """観測した上限での物理memory需要の確定

        value: 検証済みのworkload resource
        戻り値: なし
        制約: 上限は物理memory総量と全cgroupのlimitBytesの最小値。記録由来、他の鍵の中央値由来、既定値由来の需要は上限へ切り詰める
        失敗: 上限を超える明示需要によるAdmissionError
        """
        ceiling = min([value["memoryTotalBytes"], *(limit["limitBytes"] for limit in value["memoryLimits"])])
        if self.explicit is not None:
            if self.explicit > ceiling:
                raise AdmissionError(
                    f"memory request of {self.explicit} bytes exceeds the tightest limit of {ceiling} bytes; "
                    "command was not started")
        elif self.memory is None:
            if self.recorded is not None:
                demand = self.recorded
            elif self.host_median is not None:
                demand = self.host_median
            else:
                demand = -(-self.policy.percent * ceiling // 100)
            self.memory = positive(min(demand, ceiling), "memory demand")

    def slice_path(self, klass):
        """class の slice の cgroup path

        戻り値: cgroup root からの path
        """
        return str(PurePosixPath("/") / self.policy.slice_directory(klass).relative_to(self.policy.cgroup_root))

    def snapshot(self, deadline):
        """待機期限内で取得する有限量の正規化資源観測

        deadline: 待機の絶対期限
        戻り値: 空きの観測と入場保留理由
        副作用: 最初の有効な観測での物理memory需要の確定
        制約: class が通す status は PASSING。受入は警告で止まらず、deep は警告で止まる。
            Windows の物理空きが reserve を割った観測は、deep だけが待ち、受入は通常の判定へ進む。
            上限は呼んだ process の居る cgroup ではなく、scope を置く class の slice から辿る。
            scope ごとの working set は観測が求める。回収できる cache の式は観測だけが持つ
        """
        remaining = deadline - time.time()
        if remaining <= 0:
            return None, "deadline reached before observation"
        try:
            with tempfile.TemporaryFile() as output:
                command = [*self.policy.observation, self.slice_path(self.klass), *(self.slice_path(klass) for klass in CLASSES)]
                # 混んだ機械では観測が数秒かかり、待ちの上限まで観測不能が続くため固定の短い打切りは不可。使える観測の古さの上限で打ち切る
                result = subprocess.run(command, stdout=output, stderr=subprocess.DEVNULL,
                                        timeout=min(self.policy.maximum_age, remaining), check=False)
                output.seek(0)
                raw = output.read(65537)
            if result.returncode or len(raw) > 65536:
                return None, "resource observation failed"
            envelope = json.loads(raw)
            if envelope.get("schemaVersion") != 1:
                return None, "unknown resource observation version"
            outcomes = [row for row in envelope["outcomes"]
                        if row["id"] != "resource/workload/wsl-cap" or row["status"] == "fail"]
            if not outcomes:
                return None, "resource observation is incomplete"
            blocking = [row for row in outcomes if row["status"] not in PASSING[self.klass]]
            if blocking:
                return None, "; ".join(row["message"] for row in blocking)
            value = next(row["value"] for row in envelope["resources"] if row["key"] == "workload")
            age = time.time() - value["observedAt"]
            if not math.isfinite(age) or age < -1 or age > self.policy.maximum_age:
                return None, "resource observation is stale"
            for field in ("memoryTotalBytes", "memoryAvailableBytes", "memoryHeadroomBytes", "hostMemoryHeadroomBytes",
                          "windowsCommitHeadroomBytes", "windowsPhysicalAvailableBytes",
                          "windowsPhysicalHeadroomBytes"):
                if type(value[field]) is not int or value[field] < 0:
                    return None, f"resource observation has no valid {field}"
            # 増分の上限は観測が求められない間は null で、その間は需要の全量を commit の余裕に数える
            commit_growth = value["windowsCommitGrowthBytes"]
            if commit_growth is not None and (type(commit_growth) is not int or commit_growth < 0):
                return None, "resource observation has no valid windowsCommitGrowthBytes"
            # 物理空きの不足は Windows 側の paging の問題で枯渇の失敗は commit の余裕が守るため受入の待機は不可
            # 受入の待ちの間に memory.reclaim で file cache を返させる方式は cache が繰り返し捨てられて機械全体が thrash するため不可
            if value["windowsPhysicalHeadroomBytes"] == 0 and self.klass == "deep":
                return None, "Windows physical reserve is exhausted"
            if not isinstance(value["memoryLimits"], list):
                return None, "cgroup memory limits are unknown"
            if any(type(limit["limitBytes"]) is not int or limit["limitBytes"] <= 0 for limit in value["memoryLimits"]):
                return None, "resource observation has no valid limitBytes"
            self.settle_memory(value)
            for limit in value["memoryLimits"]:
                if type(limit["headroomBytes"]) is not int or limit["headroomBytes"] < 0:
                    raise AdmissionError("invalid cgroup memory headroom")
            if not isinstance(value["memoryScopes"], list):
                return None, "cgroup memory usage of the scopes is unknown"
            if any(type(row["workingSetBytes"]) is not int or row["workingSetBytes"] < 0 for row in value["memoryScopes"]):
                return None, "resource observation has no valid workingSetBytes"
            return Observation(
                host_headroom=value["hostMemoryHeadroomBytes"],
                commit_headroom=value["windowsCommitHeadroomBytes"],
                commit_growth=commit_growth,
                limits=tuple((limit["path"], limit["headroomBytes"]) for limit in value["memoryLimits"]),
                usage={row["path"]: row["workingSetBytes"] for row in value["memoryScopes"]},
            ), None
        except (OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.TimeoutExpired) as error:
            return None, f"resource observation unavailable: {error}"

    def inherit(self):
        """今の process が class の scope の中にいる場合の、入れ子の入場の確認

        戻り値: 外側の scope の中で走る場合のTrue。外側の class で走り、入れ子で昇格しない
        失敗: 外側の需要を超える明示需要による AdmissionError
        """
        own = None
        for line in self.policy.proc_cgroup.read_text().splitlines():
            if line.startswith("0::"):
                own = PurePosixPath(line[3:])
        if own is None:
            return False
        for klass in CLASSES:
            directory = self.policy.slice_directory(klass)
            base = PurePosixPath("/") / directory.relative_to(self.policy.cgroup_root)
            try:
                relative = own.relative_to(base)
            except ValueError:
                continue
            if not relative.parts or not relative.parts[0].endswith(".scope"):
                continue
            outer = cgroup_integer(directory / relative.parts[0] / DEMAND_FILES[klass])
            if outer is None:
                raise AdmissionError("the enclosing scope has no reservation to nest in")
            if self.explicit is not None and self.explicit > outer:
                raise AdmissionError("nested request exceeds its ancestor reservation; declare the whole workload at its outer entry")
            if self.explicit is None:
                # 入れ子は観測を取らず上限は外側の予約だけのため、既定値由来の需要は外側の予約と同じになる
                self.memory = outer if self.recorded is None else min(self.recorded, outer)
            self.inherited = True
            self.enclosing = relative.parts[0]
            self.ran_as = klass
            return True
        return False

    def scopes(self, observation):
        """class の slice の下にいる scope の、需要と使用量の読取

        observation: 同じ判定の観測。scope ごとの使用量はここから読む
        戻り値: 読めた scope。読む前に消えた scope は含まない。観測に使用量の無い scope は未使用と見る
        """
        found = []
        for klass in CLASSES:
            directory = self.policy.slice_directory(klass)
            try:
                names = sorted(entry.name for entry in os.scandir(directory) if entry.name.endswith(".scope") and entry.is_dir())
            except FileNotFoundError:
                continue
            for name in names:
                try:
                    limit = cgroup_integer(directory / name / DEMAND_FILES[klass])
                except (OSError, ValueError):
                    continue
                used = observation.usage.get(f"{self.slice_path(klass)}/{name}", 0)
                found.append(Scope(klass, name, limit or 0, used))
        return found

    def hold_no_acceptance_waiting(self):
        """待っている受入が無いことの確認と、その状態の保持。排他 lock が取れれば誰も待っていない

        戻り値: 取れた lock を持つ descriptor。受入が待つ場合のNone
        制約: 呼び側が閉じるまで、受入は待ちの印を付けられない。確認から入場の完了までを不可分にするため、
            deep は判定から scope の起動が済むまで持つ
        """
        descriptor = os.open(self.policy.runtime / WAITING_LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(descriptor)
            return None
        return descriptor

    def mark_waiting(self, supervisor, wait_until):
        """受入が待つ印の共有 lock の取得。process が死ねば kernel が外す

        戻り値: lock を持つ descriptor。取消か期限で取れなければ None
        """
        descriptor = os.open(self.policy.runtime / WAITING_LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
                return descriptor
            except BlockingIOError:
                if supervisor.cancel_signal is not None or time.time() >= wait_until:
                    os.close(descriptor)
                    return None
                supervisor.wait_for_event(min(0.02, max(0, wait_until - time.time())))

    def mark_cancelled(self, scope):
        """scope を取り消すと、その走行の supervisor が終了時に読める記録を残す

        scope: 取り消す deep の scope
        戻り値: 記録を残せた場合のTrue。残せなければ取り消さない
        制約: 記録は状態 directory の scope 名を持つ空の file。走行を表す記録ではなく、command の status から取消を推し量らないための印
        """
        try:
            descriptor = os.open(self.policy.runtime / f"{CANCEL_MARK}{scope.unit}",
                                 os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        except OSError as error:
            print(f"dotfiles-supervise: cannot record the cancellation of {scope.unit}: {error}", file=sys.stderr, flush=True)
            return False
        os.close(descriptor)
        return True

    def unmark_cancelled(self, scope):
        """取り消しの要求が届かなかった scope の記録の撤回

        scope: stop を manager が受けなかった deep の scope
        """
        (self.policy.runtime / f"{CANCEL_MARK}{scope.unit}").unlink(missing_ok=True)

    def prune_marks(self, scopes):
        """読まれないまま残った取消の記録の片付け。scope が無く一定の時間を過ぎた記録だけを消す

        scopes: 存在する scope
        """
        live = {scope.unit for scope in scopes}
        for mark in self.policy.runtime.glob(f"{CANCEL_MARK}*"):
            try:
                if mark.name[len(CANCEL_MARK):] not in live and time.time() - mark.stat().st_mtime > STALE_MARK_SECONDS:
                    mark.unlink()
            except OSError:
                continue

    def cancelled(self):
        """この走行が受入に取り消されたかの確認

        戻り値: 取り消された場合のTrue。command の終了 status にはよらない
        制約: 自分の scope の記録は読んで消す。入れ子の走行は外側の scope の記録を読むだけで消さない。
            消すのは、その scope を作った外側の supervisor
        """
        if self.inherited:
            return self.enclosing is not None and (self.policy.runtime / f"{CANCEL_MARK}{self.enclosing}").exists()
        if self.unit is None:
            return False
        try:
            (self.policy.runtime / f"{CANCEL_MARK}{self.unit}").unlink()
        except OSError:
            return False
        return True

    def cancel(self, scopes):
        """deep の scope を取り消す。native の stop が scope の全 process へ SIGTERM を送る

        scopes: 存在する scope
        副作用: 取消の記録を残してから取り消しの要求を出し、終了は待たない。次の観測で空きとして現れる
        制約: 記録は stop より前に残す。command が TERM を受けて 0 で終わっても、deep の supervisor は取消と判る。
            manager が要求を受けなかった場合は記録を消す。届いていない取消で、自分で終わった走行を取消にしないため。
            応答が期限内に無い場合は要求が届いたか分からないので、記録を残す。
            要求は scope ごとに一度。終わるまでの間は、manager が TimeoutStopSec で止めを刺す
        """
        self.prune_marks(scopes)
        for scope in cancellable(scopes):
            if scope.unit in self.stopping or not self.mark_cancelled(scope):
                continue
            try:
                stopped = subprocess.run([*self.policy.systemctl, "--user", "stop", "--no-block", scope.unit],
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         timeout=STOP_SECONDS, check=False)
            except subprocess.TimeoutExpired as error:
                print(f"dotfiles-supervise: cannot stop {scope.unit}: {error}", file=sys.stderr, flush=True)
                continue
            except OSError as error:
                print(f"dotfiles-supervise: cannot stop {scope.unit}: {error}", file=sys.stderr, flush=True)
                self.unmark_cancelled(scope)
                continue
            if stopped.returncode == 0:
                self.stopping.add(scope.unit)
            else:
                self.unmark_cancelled(scope)

    def scope_command(self):
        """走行ごとの scope を作って command を起動する前置 argv。需要は scope の memory.low か memory.high へ入る"""
        unit = f"dotfiles-workload-{self.klass}-{os.getpid()}-{uuid.uuid4().hex[:8]}.scope"
        self.unit = unit
        return [*self.policy.systemd_run, "--user", "--scope", "--quiet", "--collect", "--expand-environment=no",
                f"--slice={self.policy.slice_unit(self.klass)}", f"--unit={unit}",
                "-p", f"{DEMAND_PROPERTIES[self.klass]}={self.memory}", "-p", f"TimeoutStopSec={STOP_TIMEOUT}"]

    def acquire(self, supervisor, wait_until, launch):
        """待機の上限内での入場と、入場した走行の scope での起動

        supervisor: signalと公開状態を所有する監督器
        wait_until: 待機の絶対期限。走行の秒数とは別に数える
        launch: scope の前置 argv、oom_score_adj、待機の絶対期限を受け、判定の排他の中で client を起動する関数
        戻り値: 入場して起動した、または入れ子で外側の scope の中にいる場合のTrue。取消と期限切れはFalse
        失敗: scope を作れない場合や明示需要が上限を超える場合の AdmissionError
        """
        if self.inherit():
            return True
        waiting = None
        if self.klass == "acceptance":
            waiting = self.mark_waiting(supervisor, wait_until)
            if waiting is None:
                return False
        registry = os.open(self.policy.runtime / REGISTRY_LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            while supervisor.cancel_signal is None and time.time() < wait_until:
                observation, reason = self.snapshot(wait_until)
                try:
                    fcntl.flock(registry, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    supervisor.wait_for_event(min(0.05, max(0, wait_until - time.time())))
                    continue
                guard = None
                try:
                    if observation is not None:
                        scopes = self.scopes(observation)
                        if self.klass == "deep":
                            guard = self.hold_no_acceptance_waiting()
                        decision = decide(self.klass, self.memory, scopes, observation,
                                          self.klass == "deep" and guard is None)
                        reason = decision.reason
                        if decision.kind == ADMIT and supervisor.cancel_signal is None and time.time() < wait_until:
                            if launch(self.scope_command(), OOM_SCORES[self.klass], wait_until):
                                return True
                        if decision.kind == CANCEL_DEEP:
                            self.cancel(scopes)
                finally:
                    if guard is not None:
                        os.close(guard)
                    fcntl.flock(registry, fcntl.LOCK_UN)
                if reason != self.previous_reason:
                    supervisor.record("waiting", spawned=False, reason=reason, deadline=wait_until)
                    print(f"dotfiles-supervise: waiting for resources: {reason}", file=sys.stderr, flush=True)
                    self.previous_reason = reason
                    if reason is not None and reason not in self.reasons and len(self.reasons) < MAXIMUM_REASONS:
                        self.reasons.append(reason)
                supervisor.wait_for_event(min(0.5, max(0, wait_until - time.time())))
            return False
        finally:
            os.close(registry)
            if waiting is not None:
                os.close(waiting)
