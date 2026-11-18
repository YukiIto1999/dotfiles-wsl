"""待つ者のいない深い検証を機全体の資源予約と有限の期限へ接続する公開入口

この入口で走らせる処理は常に深い検証である。受入（T1、pre-push）の class を選ぶ引数は持たず、他の処理の邪魔になれば取り消される。
走行は repository の根と command ごとの鍵を supervisor へ渡し、実測した需要の記録から次の予約を決める。
"""

import argparse
import math
import os
import shutil
import subprocess
import sys
import time

# 実測の記録の鍵の最初の行。T1（verify）と pre-push（verify-push）の鍵と混ざらない
KEY_PREFIX = "deep"


def repository_top(git):
    """作業 directory の repository の根

    git: package が固定する git の実行 file
    戻り値: git が示す根。repository の外か git を実行できない場合は作業 directory
    """
    try:
        result = subprocess.run([git, "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=False)
    except OSError:
        return os.getcwd()
    top = result.stdout.strip() if result.returncode == 0 else ""
    return top or os.getcwd()


def resource_key(git, command):
    """実測した需要の記録を読み書きする鍵

    git: package が固定する git の実行 file
    command: 利用者が渡した command と引数
    戻り値: 区分、repository の根、command の行を改行でつないだ文字列。T1 の鍵の command の行と同じく、引数を空白でつなぐ
    制約: 同じ根と同じ command の走行だけが一つの記録を共有する。実行 file の解決後の path は PATH で変わるため使わない
    """
    return "\n".join((KEY_PREFIX, repository_top(git), " ".join(command)))


def main(arguments):
    """需要と期限を検証して既存supervisorへ一度だけ引き渡す実行

    arguments: packageが固定するsupervisorとpolicyとgitに続く利用者の引数
    戻り値: 引数不正または実行file不在の非ゼロstatus
    成功時: supervisorへのexecによるprocessの置換
    """
    supervise, policy, git, *tokens = arguments
    parser = argparse.ArgumentParser(
        prog="dotfiles-workload-run", allow_abbrev=False,
        description="Run a command as a deep verification: it waits for free resources, runs only in what the work "
                    "in front of it leaves, and is cancelled when that work needs the memory.",
    )
    parser.add_argument("--seconds", type=float, required=True,
                        help="seconds the command may run, counted from admission; waiting for resources is counted "
                             "separately and gives up with status 75, without running the command, after the same seconds")
    parser.add_argument("--memory-gib", type=float, help="expected peak physical memory of the whole workload; overrides host policy")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="command and arguments after --")
    started = time.time()
    options = parser.parse_args(tokens)
    if not math.isfinite(options.seconds) or options.seconds <= 0:
        parser.error("--seconds must be finite and positive")
    command = options.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command after -- is required")
    executable = shutil.which(command[0])
    if executable is None:
        print(f"dotfiles-workload-run: command not found: {command[0]}", file=sys.stderr)
        return 127
    demand = []
    if options.memory_gib is not None:
        if not math.isfinite(options.memory_gib) or options.memory_gib <= 0:
            parser.error("--memory-gib must be finite and positive")
        demand += ["--resource-memory", str(math.ceil(options.memory_gib * 1073741824))]
    os.execv(supervise, [supervise, "--require-drained", "--interrupt-cancels",
                        "--resource-policy", policy,
                        "--resource-wait-until", str(started + options.seconds),
                        "--resource-run-seconds", str(options.seconds),
                        "--resource-key", resource_key(git, command),
                        *demand, "--", executable, *command[1:]])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
