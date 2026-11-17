"""実測した物理memoryのピークの記録と、記録からの需要の導出"""

import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path

RECORD_VERSION = 1
# 古い実測を残す件数と、需要の導出に使う新しい実測の件数
KEPT_RECORDS = 10
USED_RECORDS = 5


def well_formed(row):
    """記録一件の形式の確認

    row: 記録fileから読んだ値
    戻り値: 需要の導出に使える形式のTrue
    """
    return (isinstance(row, dict)
            and type(row.get("at")) in (int, float) and math.isfinite(row["at"])
            and type(row.get("peakBytes")) is int and row["peakBytes"] > 0
            and type(row.get("reservedBytes")) is int and row["reservedBytes"] > 0
            and type(row.get("exceeded")) is bool)


def read_records(path):
    """記録file一つの読取

    path: 鍵ごとの記録file
    戻り値: 形式の正しい記録の一覧。fileが無ければ空
    失敗: 読めないfileによるOSErrorと、壊れた内容によるValueError
    """
    try:
        with open(path) as stream:
            document = json.load(stream)
    except FileNotFoundError:
        return []
    except ValueError as error:
        raise ValueError(f"{path} is not valid JSON: {error}") from error
    if (not isinstance(document, dict) or document.get("version") != RECORD_VERSION
            or not isinstance(document.get("records"), list)):
        raise ValueError(f"{path} is not a version {RECORD_VERSION} record")
    return [row for row in document["records"] if well_formed(row)]


class DemandHistory:
    """鍵ごとに保つ実測した物理memoryのピークの記録

    key: 同じ種類の走行へ呼出し側が与える鍵
    寿命: 一呼出し。記録fileは呼出しを越えて残る
    失敗: 状態directoryを決められない場合のOSError
    """

    def __init__(self, key):
        state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
        if not os.path.isabs(state):
            raise OSError(errno.EINVAL, f"the state directory is not an absolute path: {state}")
        digest = hashlib.sha256(os.fsencode(key)).hexdigest()
        self.directory = Path(state, "dotfiles-wsl", "workload", "demand")
        self.path = self.directory / f"{digest}.json"
        self.lock = self.directory / f"{digest}.lock"

    def load(self):
        """記録fileの読取

        戻り値: 形式の正しい記録の一覧。fileが無ければ空
        失敗: 読めないfileによるOSErrorと、壊れた内容によるValueError
        """
        return read_records(self.path)

    def recorded_demand(self):
        """記録から導く物理memory需要の取得

        戻り値: 新しい5件のピークの最大。記録が無ければNone
        失敗: load と同じ
        """
        newest = sorted(self.load(), key=lambda row: row["at"], reverse=True)[:USED_RECORDS]
        if not newest:
            return None
        return max(row["peakBytes"] for row in newest)

    def host_demand(self):
        """この host の他の鍵の実測から導く物理memory需要の取得

        戻り値: 各鍵の最新の記録のピークの中央値。件数が偶数なら大きい側。使える記録が一つも無ければNone
        制約: 読めない fileと形の不正な fileは、その鍵が無いものとして黙って無視する。失敗を呼び側へ返さない
        """
        try:
            paths = list(self.directory.glob("*.json"))
        except OSError:
            return None
        peaks = []
        for path in paths:
            try:
                records = read_records(path)
            except (OSError, ValueError):
                continue
            if records:
                peaks.append(max(records, key=lambda row: row["at"])["peakBytes"])
        if not peaks:
            return None
        return sorted(peaks)[len(peaks) // 2]

    def append(self, record):
        """記録の先頭への追加

        record: 一走行の実測
        戻り値: なし
        制約: 新しい順の10件だけを残す。lockの中で読み直し、一時fileからのrenameで公開する。壊れた既存の記録は置き換える
        失敗: 記録できない場合のOSError
        """
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock = os.open(self.lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                earlier = self.load()
            except ValueError:
                earlier = []
            temporary = self.directory / f"{self.path.name}.{os.getpid()}.tmp"
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            try:
                with os.fdopen(descriptor, "w") as stream:
                    json.dump({"version": RECORD_VERSION, "records": [record, *earlier][:KEPT_RECORDS]}, stream)
                    stream.write("\n")
                os.rename(temporary, self.path)
            except BaseException:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass
                raise
        finally:
            os.close(lock)
