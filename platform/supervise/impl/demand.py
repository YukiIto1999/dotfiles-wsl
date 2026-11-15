"""実測した物理memoryのピークの記録と、記録からの需要の導出"""

import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess

RECORD_VERSION = 1
# 古い実測を残す件数、需要の導出に使う新しい実測の件数、その実測を使う期間、ピークへ足す割合
KEPT_RECORDS = 10
USED_RECORDS = 5
USABLE_SECONDS = 30 * 24 * 60 * 60
MARGIN_PERCENT = 20
GIT_SECONDS = 10
# toolchain、依存、検証入口の宣言。変わると過去の実測は使わない。`*.lock`は根直下だけを指す
FINGERPRINT_PATHSPECS = (
    ":(top,glob)*.lock",
    "flake.nix",
    "devenv.nix",
    "devenv.yaml",
    "package.json",
    "pnpm-lock.yaml",
    "package-lock.json",
    "Cargo.toml",
    "rust-toolchain",
    "rust-toolchain.toml",
    "global.json",
    "Directory.Build.props",
    "Directory.Packages.props",
    "nx.json",
    "verification-budget.json",
    "justfile",
    "Makefile",
)


def fingerprint():
    """走行の宣言の識別子の取得

    戻り値: 作業directoryが属するgit repositoryの根で、宣言fileの`git ls-files -s`の出力から得たsha256の16進数。
        repositoryでない場合とgitの失敗は空文字列
    """
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=GIT_SECONDS, check=True).stdout
        listing = subprocess.run(["git", "-C", os.fsdecode(top.rstrip(b"\n")), "ls-files", "-s", "--",
                                  *FINGERPRINT_PATHSPECS], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 timeout=GIT_SECONDS, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    return hashlib.sha256(listing).hexdigest()


def well_formed(row):
    """記録一件の形式の確認

    row: 記録fileから読んだ値
    戻り値: 需要の導出に使える形式のTrue
    """
    return (isinstance(row, dict)
            and type(row.get("at")) in (int, float) and math.isfinite(row["at"])
            and type(row.get("peakBytes")) is int and row["peakBytes"] > 0
            and type(row.get("reservedBytes")) is int and row["reservedBytes"] > 0
            and type(row.get("fingerprint")) is str
            and type(row.get("exceeded")) is bool)


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
        try:
            with open(self.path) as stream:
                document = json.load(stream)
        except FileNotFoundError:
            return []
        except ValueError as error:
            raise ValueError(f"{self.path} is not valid JSON: {error}") from error
        if (not isinstance(document, dict) or document.get("version") != RECORD_VERSION
                or not isinstance(document.get("records"), list)):
            raise ValueError(f"{self.path} is not a version {RECORD_VERSION} record")
        return [row for row in document["records"] if well_formed(row)]

    def recorded_demand(self, current, now):
        """記録から導く物理memory需要の取得

        current: 現在のfingerprint
        now: 現在のEPOCH秒
        戻り値: fingerprintが現在と一致し30日以内の新しい5件のピークの最大に20%を足した値の切り上げ。該当が無ければNone
        失敗: load と同じ
        """
        usable = [row for row in self.load() if row["fingerprint"] == current and now - row["at"] <= USABLE_SECONDS]
        newest = sorted(usable, key=lambda row: row["at"], reverse=True)[:USED_RECORDS]
        if not newest:
            return None
        return -(-max(row["peakBytes"] for row in newest) * (100 + MARGIN_PERCENT) // 100)

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
