"""systemd-run が作った scope の中で command へ置き換わる前に、監督器へ scope へ入ったと知らせる。

    enter_scope.py OOM_SCORE_ADJ EXECUTABLE ARGV0 [ARGUMENT...]

systemd-run は scope を作って自分を入れてから command を exec する。command の代わりにこの helper を渡すと、helper が動いて
いることが scope の作成の成功の証拠になる。helper は自分を SIGSTOP で止め、監督器が scope の cgroup を確かめて SIGCONT する
まで進まない。続けて command へ exec で置き換わるので、command は systemd-run が使った PID のまま scope の中で動く。
"""

import os
import signal
import sys

# Python が起動時に無視へ変えた signal。無視は exec を越えて command へ残るため、監督器が command へ渡す既定の動作へ戻す
RESTORED = (signal.SIGPIPE, signal.SIGXFSZ)


def main(arguments):
    """oom_score_adj を設定し、監督器の確認を待ってから command へ置き換わる

    arguments: OOM_SCORE_ADJ、EXECUTABLE、ARGV0 と command の引数
    戻り値: 戻らない。exec に失敗した場合は errno に応じた 126 か 127
    """
    score, executable, argv0, *rest = arguments
    if score != "0":
        # 上げる向きは非特権でも許される。deep の検証は kernel の OOM で最初に選ばれる
        with open("/proc/self/oom_score_adj", "w") as stream:
            stream.write(score)
    for number in RESTORED:
        signal.signal(number, signal.SIG_DFL)
    os.kill(os.getpid(), signal.SIGSTOP)
    try:
        os.execv(executable, [argv0, *rest])
    except OSError as error:
        print(f"dotfiles-supervise: cannot execute {executable}: {error.strerror}", file=sys.stderr)
        return 127 if isinstance(error, FileNotFoundError) else 126


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
