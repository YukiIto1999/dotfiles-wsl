"""systemd-run が作った scope の中で command へ置き換わる前に、監督器へ scope へ入ったと知らせる。

    enter_scope.py SUPERVISOR_PID OOM_SCORE_ADJ EXECUTABLE ARGV0 [ARGUMENT...]

systemd-run は scope を作って自分を入れてから command を exec する。command の代わりにこの helper を渡すと、helper が動いて
いることが scope の作成の成功の証拠になる。helper は自分を SIGSTOP で止め、監督器が scope の cgroup を確かめて SIGCONT する
まで進まない。続けて command へ exec で置き換わるので、command は systemd-run が使った PID のまま scope の中で動く。

監督器だけが殺されると、止まった helper は scope の中で予約を持ち続ける。そこで helper は、監督器が死ねば SIGKILL を受けるよう
にし、起動した時点で親が監督器でなければ、command を実行せずに終わる。command へ置き換わる前にこの設定を外すので、起動した
command は監督器より長く生きられる。
"""

import ctypes
import os
import signal
import sys

PR_SET_PDEATHSIG = 1
# Python が起動時に無視へ変えた signal。無視は exec を越えて command へ残るため、監督器が command へ渡す既定の動作へ戻す
RESTORED = (signal.SIGPIPE, signal.SIGXFSZ)
# 起動した時にはもう監督器が居なかった helper の終了 status。command は実行していない
ORPHANED_STATUS = 70


def set_death_signal(number):
    """親が死んだ時に自分へ届く signal の設定

    number: signal 番号。0 は設定を外す
    失敗: prctl の失敗による OSError
    """
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_PDEATHSIG, number, 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def main(arguments):
    """oom_score_adj を設定し、監督器の確認を待ってから command へ置き換わる

    arguments: 監督器の PID、OOM_SCORE_ADJ、EXECUTABLE、ARGV0 と command の引数
    戻り値: 戻らない。監督器が居ない場合は ORPHANED_STATUS。exec に失敗した場合は errno に応じた 126 か 127
    制約: 親を確かめる前に死の通知を設定する。逆にすると、確かめた後に監督器が死んだ場合に通知が間に合わない
    """
    supervisor, score, executable, argv0, *rest = arguments
    set_death_signal(signal.SIGKILL)
    if os.getppid() != int(supervisor):
        return ORPHANED_STATUS
    if score != "0":
        # 上げる向きは非特権でも許される。deep の検証は kernel の OOM で最初に選ばれる
        with open("/proc/self/oom_score_adj", "w") as stream:
            stream.write(score)
    for number in RESTORED:
        signal.signal(number, signal.SIG_DFL)
    os.kill(os.getpid(), signal.SIGSTOP)
    # 再開された後は command が監督器より長く生きてよいので、置き換わる前に外す
    set_death_signal(0)
    try:
        os.execv(executable, [argv0, *rest])
    except OSError as error:
        print(f"dotfiles-supervise: cannot execute {executable}: {error.strerror}", file=sys.stderr)
        return 127 if isinstance(error, FileNotFoundError) else 126


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
