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

# capped は CPU の割合を予約し、走行ごとの scope の CPUQuota に掛ける前景の走行。受入と同じく取り消されず、他の class の走行を取り消さない
CAPPED = "capped"
CLASSES = ("acceptance", "deep", CAPPED)
# memory の使い増しを空きから引く class。取り消されない走行で、増分は予約として他の入場の判定に数える
RESERVING = ("acceptance", CAPPED)
# 一走行の計測へ残す待機理由の最大の件数
MAXIMUM_REASONS = 8
# 入場を止めない観測の status。failure と未知の status は、見る outcome のどれにあっても止める
PASSING = ("pass", "warn")
# scope が持つ需要を書く file。受入と capped は予約の記録の memory.low、deep は上限の memory.high。どれも保護や hard limit にはしない
DEMAND_FILES = {"acceptance": "memory.low", "deep": "memory.high", CAPPED: "memory.low"}
DEMAND_PROPERTIES = {"acceptance": "MemoryLow", "deep": "MemoryHigh", CAPPED: "MemoryLow"}
# deep は kernel の OOM で最初に選ばれる。受入と capped と session は上げない
OOM_SCORES = {"acceptance": 0, "deep": 1000, CAPPED: 0}
# 取り消された scope の SIGTERM から SIGKILL までの猶予。supervisor の既定の猶予と同じ
STOP_TIMEOUT = "10s"
STOP_SECONDS = 5
# systemctl が unit を持たないと答える終了 status。止める scope が無いので診断に出さない
UNIT_NOT_LOADED = 5
# systemd-run が作った scope へ command が入るまでの既定の猶予秒数。policy の scopeEntrySeconds で代えられる
SCOPE_ENTRY_SECONDS = 10.0
REGISTRY_LOCK = "registry.lock"
# 受入が待つ間だけ共有 lock を持つ file。deep は排他で試して取れなければ受入が待つと判る
WAITING_LOCK = "acceptance.waiting"
# 受入が deep の scope を取り消すときに残す記録の名前の前置。scope 名を続ける。deep の supervisor が終了時に読んで消す
CANCEL_MARK = "cancel-"
# 読まれないまま scope が消えた取消の記録を片付ける経過秒数。supervisor が強制終了されたときだけ残る
STALE_MARK_SECONDS = 3600
ADMIT, WAIT, CANCEL_DEEP = "admit", "wait", "cancel-deep"
HEADROOM_REASON = "Linux memory headroom is reserved"
# capped の scope が CPU の上限を持つ cgroup の file。quota と period の二つの値を持つ
CPU_MAX = "cpu.max"
CPU_REASON = "the CPU budget of the capped class is reserved"


class AdmissionError(Exception):
    """実行を開始できない資源契約の不成立"""


def outcome_ids(value, name):
    """policy が運ぶ outcome の id の一覧の確認

    value: 確認対象の値
    name: 診断用の項目名
    戻り値: id の tuple
    失敗: 文字列の一覧でない値による AdmissionError
    """
    if not isinstance(value, list) or not all(type(item) is str for item in value):
        raise AdmissionError(f"{name} must be a list of outcome ids")
    return tuple(value)


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
    limit: 受入と capped では memory.low、deep では memory.high の bytes。読めなければ0
    working_set: 観測が報告した、回収できる cache を除いた使用量。報告が無い scope は0で、予約の全部がこれから使われると見る
    cpu: capped の scope が cpu.max で掛ける CPU の割合（CPU一つ分が100）。上限を読めない scope と上限の無い scope は budget の全部。他の class は0
    """

    klass: str
    unit: str
    limit: int
    working_set: int
    cpu: int = 0


@dataclass(frozen=True)
class Observation:
    """入場の判定に使う空きの観測

    host_headroom: host の空き
    limits: 祖先の cgroup ごとの（path、空き）
    usage: class の slice の下の scope ごとの、cgroup path から観測が求めた working set への対応
    """

    host_headroom: int
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
    """走行中の受入と capped の scope がこれから使い増せる量

    scope: 受入か capped の scope
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
    """要求が、走行中の受入と capped が使い増せる量を含めて空きに収まらない理由

    demand: 要求する物理memory
    scopes: 存在する scope
    observation: 空きの観測
    戻り値: 収まる場合は None、収まらない場合は理由。deep の scope の増分は数えない
    制約: 空きは host と祖先の cgroup の上限だけを数える。Windows の commit と物理の空きは入場を止める根拠にせず、診断にだけ使う
    """
    claim = sum(growth(scope) for scope in scopes if scope.klass in RESERVING)
    need = demand + claim
    if need > observation.host_headroom:
        return HEADROOM_REASON
    for path, headroom in observation.limits:
        if need > headroom:
            return f"memory headroom is reserved at {path}"
    return None


def cpu_shortfall(request, budget, scopes):
    """要求する CPU が、走行中の capped の予約を含めて budget に収まらない理由

    request: 要求する CPU の割合（CPU一つ分が100）
    budget: capped の走行が合わせて予約できる CPU の割合
    scopes: 存在する scope
    戻り値: 収まる場合は None、収まらない場合は理由。capped でない scope は数えない
    制約: 理由の文は予約の量を含めない。量が変わるたびに待機の理由が変わると、一走行の記録が理由で埋まるため
    """
    reserved = sum(scope.cpu for scope in scopes if scope.klass == CAPPED)
    return CPU_REASON if request + reserved > budget else None


def decide(klass, demand, scopes, observation, acceptance_waiting, cpu_request=0, cpu_budget=0):
    """入場の判定。観測と存在する scope だけで決まる

    klass: 要求する走行の class
    demand: 要求する物理memory
    scopes: 存在する scope
    observation: 空きの観測
    acceptance_waiting: 待っている受入があるか
    cpu_request: capped が要求する CPU の割合。他の class は使わない
    cpu_budget: capped の走行が合わせて予約できる CPU の割合。他の class は使わない
    戻り値: 入場、待機、deep の取消のいずれか
    不変条件:
      受入の入場は他の受入が待つことで止まらない。
      受入が待つ間は deep を入場させない。deep は同時に一走行だけ。
      入場した受入と capped の増分の合計は各空きを超えない。
      受入が memory で収まらず deep の scope があれば、deep だけを取り消す。
      入場した capped の CPU の予約の合計は budget を超えない。
      capped の入場は、待つ受入にも走行中の deep にも止められず、何も取り消さない。収まらなければ待つだけである。
    """
    if klass == CAPPED:
        reason = cpu_shortfall(cpu_request, cpu_budget, scopes) or shortfall(demand, scopes, observation)
        return Decision(ADMIT) if reason is None else Decision(WAIT, reason)
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


def cpu_percent(path):
    """cpu.max が掛ける上限の読取

    path: scope の cpu.max
    戻り値: CPU一つ分を100とする割合。切り上げる。quota が max の場合は None
    失敗: 読めない場合の OSError と、形式が不正な場合の ValueError
    """
    fields = path.read_text().split()
    if len(fields) != 2 or not fields[1].isdecimal() or int(fields[1]) <= 0:
        raise ValueError(f"{path} is not a cpu.max")
    if fields[0] == "max":
        return None
    if not fields[0].isdecimal() or int(fields[0]) <= 0:
        raise ValueError(f"{path} has no valid quota")
    return -(-int(fields[0]) * 100 // int(fields[1]))


def unpopulated(directory):
    """scope の cgroup が process を一つも持たないことの確認

    directory: scope の cgroup directory
    戻り値: cgroup.events の populated が 0 の場合だけTrue。読めない場合と populated の行が無い場合は、空と見なさずFalse
    制約: 空の scope はこれから memory を使わない。scope の起動は判定の排他の中で helper が入るまで終わらないので、
        排他の中で見える空の scope は、終わった直後の scope か、起動の途中で殺されて残った scope のどちらかである。
        読めないものを空と見なすと、使っている scope の予約を空きへ戻して入場を誤るため、読めない scope は数える
    """
    try:
        return "populated 0" in (directory / "cgroup.events").read_text().splitlines()
    except (OSError, ValueError):
        return False


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
        # 入場を止める outcome の id。guest の値は全 class の入場を、圧迫は deep の入場を止める。id は観測が持ち、policy が運ぶ
        self.guest_outcomes = outcome_ids(document["guestOutcomeIds"], "guestOutcomeIds")
        if not self.guest_outcomes:
            raise AdmissionError("guestOutcomeIds must name at least one outcome")
        self.pressure_outcomes = outcome_ids(document["pressureOutcomeIds"], "pressureOutcomeIds")
        self.maximum_age = document["maximumObservationAgeSeconds"]
        # systemd-run と systemctl は argv の前置として持ち、検査が代替を渡せる
        self.systemd_run = document["systemdRun"]
        self.systemctl = document["systemctl"]
        self.cgroup_root = Path(document["cgroupRoot"])
        self.slices = document["slices"]
        self.proc_cgroup = Path(document.get("procCgroup", "/proc/self/cgroup"))
        self.journal = document.get("journalSocket", JOURNAL_SOCKET)
        self.entry_seconds = document.get("scopeEntrySeconds", SCOPE_ENTRY_SECONDS)
        if type(self.entry_seconds) not in (int, float) or not 0 < self.entry_seconds < math.inf:
            raise AdmissionError("scopeEntrySeconds must be a positive number")
        missing = [klass for klass in CLASSES if klass not in self.slices]
        if missing:
            raise AdmissionError(f"slices must name the slice of every class, missing {', '.join(missing)}")
        # CPU の budget は capped の policy だけが持つ。他の class の policy が持つと、使われない宣言が残る
        self.cpu_budget = document.get("cpuBudgetPercent")
        if self.klass == CAPPED:
            self.cpu_budget = positive(self.cpu_budget, "cpuBudgetPercent")
        elif self.cpu_budget is not None:
            raise AdmissionError("cpuBudgetPercent belongs to the policy of the capped class")

    def slice_directory(self, klass):
        """class の slice の cgroup directory。利用者の systemd manager の下に置く"""
        uid = os.getuid()
        return self.cgroup_root / "user.slice" / f"user-{uid}.slice" / f"user@{uid}.service" / self.slices[klass]

    def slice_unit(self, klass):
        """class の slice の unit 名"""
        return Path(self.slices[klass]).name

    def holding_outcomes(self, klass):
        """class の入場を止める outcome の id。guest の値は全 class、圧迫は deep だけ"""
        return (*self.guest_outcomes, *(self.pressure_outcomes if klass == "deep" else ()))


class Admission:
    """一走行の入場。待機、判定、scope の起動までを持つ

    policy_path: class ごとの policy file
    memory_bytes: 明示された物理memory需要か導出に任せるNone
    recorded_bytes: 実測の記録から導いた物理memory需要か記録なしのNone
    host_median_bytes: 鍵の記録が無い走行が、この host の他の鍵の実測から導いた物理memory需要か導けないNone。入れ子は使わない
    cpu_percent: capped の走行が掛ける CPU の割合（CPU一つ分が100）か、CPU の指定の無いNone。capped は必須で、他の class は指定できない
    寿命: supervisor による子孫終了確認まで。持つ状態は scope の cgroup と、process が持つ flock だけ
    制約: 明示でない物理memory需要は最初の有効な観測か外側の scope で確定し、それまでは未確定のNone
    """

    def __init__(self, policy_path, memory_bytes=None, recorded_bytes=None, host_median_bytes=None, cpu_percent=None):
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
        self.cpu = positive(cpu_percent, "CPU request") if cpu_percent is not None else None
        self.inherited = False
        self.previous_reason = None
        # 起動した scope の unit 名。受入が取り消したかをこの名前の記録で知る
        self.unit = None
        # 入れ子の走行が居る外側の scope の unit 名。外側が取り消されたかをこの名前の記録で知る
        self.enclosing = None
        # 取り消しを要求済みの scope の unit 名
        self.stopping = set()
        # 空の scope の停止を一度求めた unit 名。同じ unit を一度の入場の間に繰り返し止めない
        self.reclaimed = set()
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
        制約: 見る outcome は policy が class ごとに決める（Policy.holding_outcomes）。status が PASSING にない outcome が一つでもあれば待つ。
            Windows の commit、物理の空き、wsl-cap は見ない。
            受入の待ちの間に memory.reclaim で file cache を返させる方式は cache が繰り返し捨てられて機械全体が thrash するため不可。
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
            reported = {row["id"]: row for row in envelope["outcomes"]}
            holding = [reported.get(identifier) for identifier in self.policy.holding_outcomes(self.klass)]
            if None in holding:
                return None, "resource observation is incomplete"
            blocking = [row for row in holding if row["status"] not in PASSING]
            if blocking:
                return None, "; ".join(row["message"] for row in blocking)
            value = next(row["value"] for row in envelope["resources"] if row["key"] == "workload")
            age = time.time() - value["observedAt"]
            if not math.isfinite(age) or age < -1 or age > self.policy.maximum_age:
                return None, "resource observation is stale"
            for field in ("memoryTotalBytes", "memoryAvailableBytes", "memoryHeadroomBytes", "hostMemoryHeadroomBytes"):
                if type(value[field]) is not int or value[field] < 0:
                    return None, f"resource observation has no valid {field}"
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
                limits=tuple((limit["path"], limit["headroomBytes"]) for limit in value["memoryLimits"]),
                usage={row["path"]: row["workingSetBytes"] for row in value["memoryScopes"]},
            ), None
        except (OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.TimeoutExpired) as error:
            return None, f"resource observation unavailable: {error}"

    def inherit(self):
        """今の process が class の scope の中にいる場合の、入れ子の入場の確認

        戻り値: 外側の scope の中で走る場合のTrue。外側の class で走り、入れ子で昇格しない
        失敗: 外側の需要を超える明示需要と、外側の scope が持たない CPU の上限を求める要求による AdmissionError
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
            if self.cpu is not None:
                self.nest_cpu(klass, directory / relative.parts[0])
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
        戻り値: 予約に数える scope の一覧と、process を持たない scope の cgroup directory の一覧。読む前に消えた scope は含まない。観測に使用量の無い scope は未使用と見る
        制約: process を持たない scope（unpopulated）は前者に含めず、予約にも deep の一走行にも数えない。持つかどうかを読めない scope は数える。
            呼び側は判定の排他の中で読む。排他の外では、他の supervisor が作っている途中の scope も空に見える
        """
        found = []
        empty = []
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
                if unpopulated(directory / name):
                    empty.append(directory / name)
                    continue
                used = observation.usage.get(f"{self.slice_path(klass)}/{name}", 0)
                # CPU の予約を使うのは capped の入場だけで、他の class の入場は cpu.max を読まない
                cpu = self.reserved_cpu(directory / name) if self.klass == CAPPED and klass == CAPPED else 0
                found.append(Scope(klass, name, limit or 0, used, cpu))
        return found, empty

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

    def stop_scope(self, directory):
        """scope の unit の停止の要求。終了は待たない

        directory: 止める scope の cgroup directory。unit 名は directory の名前
        副作用: 失敗は診断に一行出すだけで、入場も終了 status も変えない
        制約: 止める物が無い場合は黙る。manager が unit を持たない（systemctl の終了 status 5）場合と、失敗した時に scope の
            directory が既に無い場合である。process を持つ scope の取消は cancel が持ち、ここは process を持たない scope だけを止める
        """
        unit = directory.name
        try:
            stopped = subprocess.run([*self.policy.systemctl, "--user", "stop", "--no-block", unit],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                     text=True, errors="replace", timeout=STOP_SECONDS, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            detail = str(error)
        else:
            if stopped.returncode in (0, UNIT_NOT_LOADED):
                return
            detail = stopped.stderr.strip() or f"systemctl ended with status {stopped.returncode}"
        if directory.exists():
            print(f"dotfiles-supervise: cannot stop {unit}: {detail}", file=sys.stderr, flush=True)

    def reclaim(self, directories):
        """残った空の scope の停止の要求

        directories: process を持たない scope の cgroup directory
        副作用: unit ごとに、この supervisor が一度だけ停止を求める。失敗も数え、同じ unit の停止と診断を繰り返さない
        制約: 取消の記録を残さず、cancel も通さない。終わった直後の deep の scope も一瞬は空で、取消と見なすとその走行が 143 で返る。
            空かどうかは判定の排他の中で読み、停止はその後に求める。空の scope は存在する間に埋まらないので、排他を外した後でも
            止めてよい。停止は manager が非同期に行い、消えるまでの間に次の判定が同じ scope を見ても繰り返さない
        """
        for directory in directories:
            if directory.name not in self.reclaimed:
                self.reclaimed.add(directory.name)
                self.stop_scope(directory)

    def scope_command(self):
        """走行ごとの scope を作って command を起動する前置 argv。需要は scope の memory.low か memory.high へ入り、capped の CPU は CPUQuota へ入る"""
        unit = f"dotfiles-workload-{self.klass}-{os.getpid()}-{uuid.uuid4().hex[:8]}.scope"
        self.unit = unit
        properties = ["-p", f"{DEMAND_PROPERTIES[self.klass]}={self.memory}", "-p", f"TimeoutStopSec={STOP_TIMEOUT}"]
        if self.cpu is not None:
            properties += ["-p", f"CPUQuota={self.cpu}%"]
        return [*self.policy.systemd_run, "--user", "--scope", "--quiet", "--collect", "--expand-environment=no",
                f"--slice={self.policy.slice_unit(self.klass)}", f"--unit={unit}", *properties]

    def scope_directory(self):
        """この走行が作った scope の cgroup directory

        戻り値: classのsliceの下の scope の directory。scope を作らない入れ子の走行と、まだ作っていない走行はNone
        制約: scope は最後の process の終了で消えるため、存在は呼び側が読取の成否で確かめる
        """
        if self.unit is None:
            return None
        return self.policy.slice_directory(self.klass) / self.unit

    def check_cpu_request(self):
        """CPU の指定が class に合うことの確認。待つ前に断る

        失敗: capped で指定が無い場合と budget を超える場合、capped でない class で指定がある場合の AdmissionError
        制約: budget を超える要求は待っても入れないので、待たずに command を起動せず断る。入れ子でも同じ上限で断る
        """
        if self.klass != CAPPED:
            if self.cpu is not None:
                raise AdmissionError("a CPU request needs the policy of the capped class; command was not started")
            return
        if self.cpu is None:
            raise AdmissionError("the capped class needs a CPU request; command was not started")
        if self.cpu > self.policy.cpu_budget:
            raise AdmissionError(
                f"CPU request of {self.cpu} percent exceeds the capped budget of {self.policy.cpu_budget} percent; "
                "command was not started")

    def nest_cpu(self, klass, directory):
        """入れ子の CPU の要求が、外側の scope が既に持つ上限と等しいことの確認

        klass: 外側の scope の class
        directory: 外側の scope の cgroup directory
        失敗: 外側が capped でない場合と、外側の上限と違う場合と、外側の上限を読めない場合の AdmissionError
        制約: 入れ子は scope を作らず外側の scope で走るため、要求した上限をその scope が持つ時だけ満たされる。
            上限の無い scope では要求した上限が黙って外れ、要求より大きい上限の scope では要求より多い CPU を使えてしまうので、
            外側の上限と等しい要求だけを通す。小さい上限が要るなら、外側の入口で全体の上限として宣言する
        """
        unbounded = "the enclosing scope has no CPU cap to nest the request in; declare the CPU cap at the outer entry"
        if klass != CAPPED:
            raise AdmissionError(unbounded)
        try:
            outer = cpu_percent(directory / CPU_MAX)
        except (OSError, ValueError) as error:
            raise AdmissionError(f"cannot read the CPU cap of the enclosing scope: {error}") from None
        if outer is None:
            raise AdmissionError(unbounded)
        if outer != self.cpu:
            raise AdmissionError(
                f"nested CPU request of {self.cpu} percent differs from the cap of {outer} percent of its enclosing scope; "
                "declare the whole workload at its outer entry")

    def reserved_cpu(self, directory):
        """capped の scope が予約する CPU の割合の読取

        directory: capped の scope の cgroup directory
        戻り値: cpu.max の上限の割合。上限が無い scope と読めない scope は、budget の全部
        制約: 読めないものを小さく見ると、上限の無い走行が使う CPU を他の入場へ譲るため、予約の全部と見る。
            消えた scope を読めなかった場合も一度の判定の間だけ全部と見て、次の判定で外れる
        """
        try:
            percent = cpu_percent(directory / CPU_MAX)
        except (OSError, ValueError):
            percent = None
        return self.policy.cpu_budget if percent is None else percent

    def verify_cpu_cap(self):
        """起動した scope が、要求した CPU の上限を kernel に持つことの確認

        失敗: 上限を読めない場合と、要求と違う場合の AdmissionError
        制約: helper が scope へ入って止まっている間、command を再開する前に呼ぶ。上限の無い scope では command を一度も実行せず、
            呼び側が scope を畳む。CPU の指定の無い走行は何も確かめない
        """
        if self.cpu is None:
            return
        try:
            applied = cpu_percent(self.scope_directory() / CPU_MAX)
        except (OSError, ValueError) as error:
            raise AdmissionError(f"cannot read the CPU cap of the scope: {error}; command was not started") from None
        if applied != self.cpu:
            shown = "none" if applied is None else f"{applied} percent"
            raise AdmissionError(
                f"the scope has a CPU cap of {shown}, not the requested {self.cpu} percent; command was not started")

    def acquire(self, supervisor, wait_until, launch):
        """待機の上限内での入場と、入場した走行の scope での起動

        supervisor: signalと公開状態を所有する監督器
        wait_until: 待機の絶対期限。走行の秒数とは別に数える
        launch: scope の前置 argv、oom_score_adj、待機の絶対期限を受け、判定の排他の中で client を起動する関数。起動に至らなければFalse
        戻り値: 入場して起動した、または入れ子で外側の scope の中にいる場合のTrue。取消と期限切れはFalse
        失敗: scope を作れない場合、明示需要が上限を超える場合、CPU の要求が class や budget や外側の scope の上限に合わない場合の AdmissionError
        制約: 取消も期限も無いのに起動に至らなかったのは、command が猶予内に scope へ入れなかったためで、失敗にせず、
            その理由を待機の理由に残して、期限まで入場をやり直す
        """
        self.check_cpu_request()
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
                empty = []
                try:
                    if observation is not None:
                        scopes, empty = self.scopes(observation)
                        if self.klass == "deep":
                            guard = self.hold_no_acceptance_waiting()
                        decision = decide(self.klass, self.memory, scopes, observation, self.klass == "deep" and guard is None,
                                          self.cpu or 0, self.policy.cpu_budget or 0)
                        reason = decision.reason
                        if decision.kind == ADMIT and supervisor.cancel_signal is None and time.time() < wait_until:
                            if launch(self.scope_command(), OOM_SCORES[self.klass], wait_until):
                                return True
                            if supervisor.cancel_signal is None and time.time() < wait_until:
                                reason = f"the command did not enter its scope within {self.policy.entry_seconds:g}s"
                        if decision.kind == CANCEL_DEEP:
                            self.cancel(scopes)
                finally:
                    if guard is not None:
                        os.close(guard)
                    fcntl.flock(registry, fcntl.LOCK_UN)
                    # capped は他の走行の scope へ止めの要求を出さない。空の scope は予約に数えないだけで、止めるのは受入と deep の入場が持つ
                    if self.klass != CAPPED:
                        self.reclaim(empty)
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
