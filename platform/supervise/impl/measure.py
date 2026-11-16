"""資源予約を持つ走行一回の計測の journald への一行の送出"""

import json
import socket

JOURNAL_SOCKET = "/run/systemd/journal/socket"
IDENTIFIER = "dotfiles-supervise"


def emit(path, record):
    """計測の一行の journald の native protocol での送出

    path: journald の native socket のpath
    record: 一走行の計測のJSON化できる辞書
    戻り値: なし
    副作用: MESSAGE へJSON一行を入れ、SYSLOG_IDENTIFIER が dotfiles-supervise の journal entry を一件足す
    失敗: socket が無い場合や送れない場合の OSError
    制約: MESSAGE はJSONの改行の逃し字で一行に収まる。同じ内容を別の fields へ複製しない
    """
    message = json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    datagram = f"MESSAGE={message}\nPRIORITY=6\nSYSLOG_IDENTIFIER={IDENTIFIER}\n".encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC) as journal:
        journal.sendto(datagram, path)
