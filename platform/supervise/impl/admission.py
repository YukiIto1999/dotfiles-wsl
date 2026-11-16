"""資源観測に基づく期限付き入場と所有子孫の終了までの予約"""

import fcntl
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import sys
import uuid

LEASE_ENV = "DOTFILES_WORKLOAD_LEASE"
# 計測と規則が区別する走行の種類。受入は待つ者のいる検証、deepは待つ者のいない検証
CLASSES = ("acceptance", "deep")
# 一走行の計測へ残す待機理由の最大の件数
MAXIMUM_REASONS = 8


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


def process_table():
    """現在の生存 process の親と開始時刻の取得

    戻り値: PID から親PIDと開始時刻への辞書
    """
    table = {}
    for entry in os.scandir("/proc"):
        if not entry.name.isdecimal():
            continue
        try:
            data = Path(entry.path, "stat").read_text()
            fields = data[data.rindex(")") + 2:].split()
            if fields[0] != "Z":
                table[int(entry.name)] = (int(fields[1]), fields[19])
        except (FileNotFoundError, ProcessLookupError):
            continue
    return table


def descendants(pid, table):
    """指定processを起点とする生存子孫の列挙

    pid: 所有者のPID
    table: 親と開始時刻の観測
    戻り値: 起点を含むPID集合
    """
    held = {pid}
    while True:
        extra = {child for child, (parent, _) in table.items() if parent in held} - held
        if not extra:
            return held
        held.update(extra)


def pss_bytes(pid):
    """processのPSS取得

    pid: 読取対象のPID
    戻り値: /proc/<pid>/smaps_rollup の Pss のbyte数。値が無ければ0
    失敗: 消失または読取不能なprocessによるOSErrorかValueError
    """
    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
        if line.startswith("Pss:"):
            return int(line.split()[1]) * 1024
    return 0


def resident_credit(entry, table, boundary=None):
    """観測済みの使用量を予約残量から控除するPSSの取得

    entry: 稼働予約の記録
    table: processの現在の所属
    boundary: 控除を許すcgroup pathか物理全体のNone
    戻り値: 読取確認できた子孫のPSS合計
    制約: 消失または読取不能なprocessへの控除なし
    """
    if table.get(entry["pid"], (None, None))[1] != entry["start"]:
        return 0
    used = 0
    for pid in descendants(entry["pid"], table):
        try:
            if boundary is not None:
                memberships = Path(f"/proc/{pid}/cgroup").read_text().splitlines()
                membership = next(line[3:] for line in memberships if line.startswith("0::"))
                actual = Path(membership)
                if actual != Path(boundary) and Path(boundary) not in actual.parents:
                    continue
            used += pss_bytes(pid)
        except (OSError, ValueError, StopIteration):
            continue
    return min(used, entry["memoryBytes"])


class Reservation:
    """単一hostの待機順と実行中の将来消費の所有

    policy_path: 不変な観測commandと予約既定値のJSON
    memory_bytes: 明示された物理memory需要か導出に任せるNone
    cpu_count: 明示されたCPU需要か既定値を選ぶNone
    recorded_bytes: 実測の記録から導いた物理memory需要か記録なしのNone
    寿命: supervisorによる子孫終了確認まで
    制約: 明示でない物理memory需要は最初の有効な観測か祖先の予約で確定し、それまでは未確定のNone
    """

    def __init__(self, policy_path, memory_bytes=None, cpu_count=None, recorded_bytes=None):
        with open(policy_path) as stream:
            self.policy = json.load(stream)
        self.root = Path(self.policy["runtimeDirectory"])
        if not self.root.is_absolute():
            raise AdmissionError("reservation directory must be absolute")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise AdmissionError("reservation directory must be private and owned by this user")
        self.percent = self.policy["memoryPercent"]
        if type(self.percent) is not int or not 1 <= self.percent <= 100:
            raise AdmissionError("memoryPercent must be an integer from 1 to 100")
        self.klass = self.policy["class"]
        if self.klass not in CLASSES:
            raise AdmissionError(f"class must be one of {', '.join(CLASSES)}")
        self.explicit = positive(memory_bytes, "memory request") if memory_bytes is not None else None
        self.recorded = recorded_bytes
        self.memory = self.explicit
        self.cpus = positive(cpu_count if cpu_count is not None else self.policy["cpuCount"], "cpuCount")
        self.boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        self.path = None
        self.fd = None
        self.inherited = False
        self.entry = None
        self.previous_reason = None
        # 待機した理由を最初に現れた順に重複なく残す。計測の一行へ渡す
        self.reasons = []

    def settle_memory(self, value):
        """観測した上限での物理memory需要の確定

        value: 検証済みのworkload resource
        戻り値: なし
        制約: 上限は物理memory総量と全cgroupのlimitBytesの最小値。記録由来と既定値由来の需要は上限へ切り詰める
        失敗: 上限を超える明示需要によるAdmissionError
        """
        ceiling = min([value["memoryTotalBytes"], *(limit["limitBytes"] for limit in value["memoryLimits"])])
        if self.explicit is not None:
            if self.explicit > ceiling:
                raise AdmissionError(
                    f"memory request of {self.explicit} bytes exceeds the tightest limit of {ceiling} bytes; "
                    "command was not started")
        elif self.memory is None:
            demand = self.recorded if self.recorded is not None else -(-self.percent * ceiling // 100)
            self.memory = positive(min(demand, ceiling), "memory demand")

    def snapshot(self, deadline):
        """待機期限内で取得する有限量の正規化資源観測

        deadline: 呼出し全体の絶対期限
        戻り値: workload resourceと入場保留理由
        副作用: 最初の有効な観測での物理memory需要の確定
        """
        remaining = deadline - time.time()
        if remaining <= 0:
            return None, "deadline reached before observation"
        try:
            with tempfile.TemporaryFile() as output:
                result = subprocess.run(self.policy["observation"], stdout=output, stderr=subprocess.DEVNULL,
                                        timeout=min(2.0, remaining), check=False)
                output.seek(0)
                raw = output.read(65537)
            if result.returncode or len(raw) > 65536:
                return None, "resource observation failed"
            envelope = json.loads(raw)
            if envelope.get("schemaVersion") != 1:
                return None, "unknown resource observation version"
            outcomes = [row for row in envelope["outcomes"]
                        if row["id"] != "resource/workload/wsl-cap" or row["status"] == "fail"]
            if not outcomes or any(row["status"] != "pass" for row in outcomes):
                failed = "; ".join(row["message"] for row in outcomes if row["status"] != "pass")
                return None, failed or "resource observation is incomplete"
            value = next(row["value"] for row in envelope["resources"] if row["key"] == "workload")
            age = time.time() - value["observedAt"]
            if not math.isfinite(age) or age < -1 or age > self.policy["maximumObservationAgeSeconds"]:
                return None, "resource observation is stale"
            for field in ("memoryTotalBytes", "memoryAvailableBytes", "memoryHeadroomBytes", "hostMemoryHeadroomBytes",
                          "cpuCount", "windowsCommitHeadroomBytes", "windowsPhysicalAvailableBytes",
                          "windowsPhysicalHeadroomBytes"):
                if type(value[field]) is not int or value[field] < 0:
                    return None, f"resource observation has no valid {field}"
            if value["windowsPhysicalHeadroomBytes"] == 0:
                return None, "Windows physical reserve is exhausted"
            if not isinstance(value["memoryLimits"], list):
                return None, "cgroup memory limits are unknown"
            if any(type(limit["limitBytes"]) is not int or limit["limitBytes"] <= 0 for limit in value["memoryLimits"]):
                return None, "resource observation has no valid limitBytes"
            self.settle_memory(value)
            if self.cpus > value["cpuCount"]:
                raise AdmissionError("request exceeds machine capacity; command was not started")
            return value, None
        except (OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.TimeoutExpired) as error:
            return None, f"resource observation unavailable: {error}"

    def persist(self):
        """排他区間内での予約状態の保存

        戻り値: なし
        前提: registry lockと当該予約descriptorの保持
        """
        assert self.fd is not None
        data = (json.dumps(self.entry) + "\n").encode()
        os.lseek(self.fd, 0, os.SEEK_SET)
        os.write(self.fd, data)
        os.ftruncate(self.fd, len(data))

    def inherited_lease(self, table):
        """祖先supervisorの予約内での入れ子実行の確認

        table: 現在の親子関係
        戻り値: 同じ予約を継承できる場合のTrue
        失敗: 祖先予約を超える要求によるAdmissionError
        """
        token = os.environ.get(LEASE_ENV)
        if not token:
            return False
        path = Path(token)
        if path.parent != self.root or not path.name.endswith(".json"):
            raise AdmissionError("inherited resource lease belongs to another policy")
        try:
            with path.open() as stream:
                entry = json.load(stream)
            ancestors = set()
            pid = os.getppid()
            while pid in table and pid not in ancestors:
                ancestors.add(pid)
                pid = table[pid][0]
            valid = (entry["phase"] == "running" and entry["boot"] == self.boot
                     and entry["pid"] in ancestors
                     and table[entry["pid"]][1] == entry["start"])
        except (OSError, ValueError, KeyError):
            valid = False
        if not valid:
            raise AdmissionError("inherited resource lease has no live ancestor owner")
        ancestor = entry["memoryBytes"]
        if self.explicit is not None and self.explicit > ancestor or self.cpus > entry["cpuCount"]:
            raise AdmissionError("nested request exceeds its ancestor reservation; declare the whole workload at its outer entry")
        if self.explicit is None:
            # 入れ子は観測を取らず上限は祖先の予約だけのため、既定値由来の需要は祖先の予約と同じになる
            self.memory = ancestor if self.recorded is None else min(self.recorded, ancestor)
        self.inherited = True
        self.path = path
        return True

    def records(self):
        """所有確認済みの実行予約と待機予約の取得

        戻り値: 記録の一覧
        制約: 所有者不明の実行予約の自動削除なし
        """
        records = []
        for path in self.root.glob("*.json"):
            if path == self.path:
                records.append(self.entry)
                continue
            try:
                descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
            except FileNotFoundError:
                continue
            try:
                with os.fdopen(os.dup(descriptor)) as stream:
                    entry = json.load(stream)
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    records.append(entry)
                else:
                    if entry["phase"] == "waiting" or entry["boot"] != self.boot:
                        path.unlink(missing_ok=True)
                    else:
                        raise AdmissionError(f"unconfirmed workload owner: {path}; no new workload was started")
            finally:
                os.close(descriptor)
        return records

    def fits(self, snapshot, entries, table):
        """予約済みの将来増加を含めた入場可否の判定

        snapshot: 同じhostの資源観測
        entries: registry排他内の予約集合
        table: 現在のprocess所属
        戻り値: 入場可能時のNoneか待機理由
        """
        waiting = [row for row in entries if row["phase"] == "waiting"]
        if min(waiting, key=lambda row: (row["order"], row["pid"]))["pid"] != os.getpid():
            return "an earlier workload is waiting"
        active = [row for row in entries if row["phase"] == "running"]
        if self.cpus + sum(row["cpuCount"] for row in active) > snapshot["cpuCount"]:
            return "CPU capacity is reserved"
        growth = self.memory + sum(row["memoryBytes"] - resident_credit(row, table) for row in active)
        if growth > min(snapshot["hostMemoryHeadroomBytes"], snapshot["windowsCommitHeadroomBytes"]):
            return "Linux memory or Windows commit headroom is reserved"
        for limit in snapshot["memoryLimits"]:
            if type(limit["headroomBytes"]) is not int or limit["headroomBytes"] < 0:
                raise AdmissionError("invalid cgroup memory headroom")
            needed = self.memory + sum(row["memoryBytes"] - resident_credit(row, table, limit["path"]) for row in active)
            if needed > limit["headroomBytes"]:
                return f"memory headroom is reserved at {limit['path']}"
        return None

    def acquire(self, supervisor, deadline):
        """有限の期限内でのFIFO入場と取消の受付

        supervisor: signalと公開状態を所有する監督器
        deadline: 待機を含む呼出し全体の絶対期限
        戻り値: 入場成功のTrueか取消・期限切れのFalse
        """
        table = process_table()
        if self.inherited_lease(table):
            return True
        self.path = self.root / f"{os.getpid()}-{uuid.uuid4().hex}.json"
        self.entry = {"pid": os.getpid(), "start": table[os.getpid()][1], "boot": self.boot,
                      "phase": "waiting", "order": time.monotonic_ns(), "memoryBytes": self.memory, "cpuCount": self.cpus}
        registry = os.open(self.root / "registry.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            while supervisor.cancel_signal is None and time.time() < deadline:
                snapshot, reason = self.snapshot(deadline)
                try:
                    fcntl.flock(registry, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    supervisor.wait_for_event(min(0.05, max(0, deadline - time.time())))
                    continue
                try:
                    if self.fd is None:
                        self.fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_CLOEXEC, 0o600)
                        fcntl.flock(self.fd, fcntl.LOCK_EX)
                        self.persist()
                    records = self.records()
                    if snapshot is not None:
                        reason = self.fits(snapshot, records, process_table())
                    if reason is None and supervisor.cancel_signal is None and time.time() < deadline:
                        self.entry["phase"] = "running"
                        self.entry["memoryBytes"] = self.memory
                        self.persist()
                        return True
                finally:
                    fcntl.flock(registry, fcntl.LOCK_UN)
                if reason != self.previous_reason:
                    supervisor.record("waiting", spawned=False, reason=reason, deadline=deadline)
                    print(f"dotfiles-supervise: waiting for resources: {reason}", file=sys.stderr, flush=True)
                    self.previous_reason = reason
                    if reason is not None and reason not in self.reasons and len(self.reasons) < MAXIMUM_REASONS:
                        self.reasons.append(reason)
                supervisor.wait_for_event(min(0.5, max(0, deadline - time.time())))
            return False
        finally:
            os.close(registry)

    def close(self, drained):
        """終了確認済み予約の解放

        drained: 子孫の終了確認または未起動のTrue
        制約: 終了未確認の記録の維持
        戻り値: なし
        """
        if not self.inherited and self.fd is not None and self.path is not None:
            if drained:
                self.path.unlink(missing_ok=True)
            os.close(self.fd)
            self.fd = None
