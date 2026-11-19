"""重い走行を機全体の資源予約と有限の期限へ接続する公開入口

package は入口ごとに program を固定して渡し、この file は二つの入口を持つ。

deep（dotfiles-workload-run）は待つ者のいない深い検証である。受入（T1、pre-push）の class を選ぶ引数は持たず、他の処理の邪魔になれば取り消される。
capped（dotfiles-capped-run）は新しい前景の重い走行で、CPU の割合を必ず指定して走行の scope の CPUQuota へ掛ける。
取り消されず、動いている走行を取り消さない。

どちらも repository の根と command ごとの鍵を supervisor へ渡し、実測した需要の記録から次の予約を決める。
"""

import argparse
import math
import os
import shutil
import subprocess
import sys
import time

# 入口の名前。実測の記録の鍵の最初の行にもなり、T1（verify）と pre-push（verify-push）の鍵とも、入口の間でも混ざらない
DEEP = "deep"
CAPPED = "capped"


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


def resource_key(git, program, command):
    """実測した需要の記録を読み書きする鍵

    git: package が固定する git の実行 file
    program: 入口。DEEP か CAPPED
    command: 利用者が渡した command と引数
    戻り値: 入口、repository の根、command の行を改行でつないだ文字列。T1 の鍵の command の行と同じく、引数を空白でつなぐ
    制約: 同じ入口で同じ根と同じ command の走行だけが一つの記録を共有する。実行 file の解決後の path は PATH で変わるため使わない
    """
    return "\n".join((program, repository_top(git), " ".join(command)))


def build_parser(program):
    """入口ごとの引数の定義

    program: 入口。DEEP か CAPPED
    戻り値: 入口の引数を解釈する parser。CAPPED は CPU の割合と待機と走行の秒数を全て必須にし、既定値で補わない
    """
    if program == DEEP:
        parser = argparse.ArgumentParser(
            prog="dotfiles-workload-run", allow_abbrev=False,
            description="Run a command as a deep verification: it waits for free resources, runs only in what the work "
                        "in front of it leaves, and is cancelled when that work needs the memory.",
        )
        parser.add_argument("--seconds", type=float, required=True,
                            help="seconds the command may run, counted from admission; waiting for resources is counted "
                                 "separately and gives up with status 75, without running the command, after the same seconds")
    else:
        parser = argparse.ArgumentParser(
            prog="dotfiles-capped-run", allow_abbrev=False,
            description="Run a command as a foreground heavy run in its own scope with a CPU cap, which every descendant shares. "
                        "It does not preempt, and is not preempted by admission of another run (its own run limit and an interrupt "
                        "still cancel it): it waits until the cap and its memory fit, "
                        "and inside another managed scope it only runs when that scope already has exactly this CPU cap.",
        )
        parser.add_argument("--cpu-percent", type=int, required=True,
                            help="CPU the whole run may use, in percent of one CPU (100 is one CPU, 400 is four); the sum over all "
                                 "capped runs is bounded by the host budget, and a request above that budget is refused "
                                 "with status 70 without waiting")
        parser.add_argument("--wait-seconds", type=float, required=True,
                            help="seconds the run may wait for its CPU and memory to be reserved; gives up with status 75, "
                                 "without running the command")
        parser.add_argument("--run-seconds", type=float, required=True,
                            help="seconds the command may run, counted from admission; past it the run is cancelled with status 124")
    parser.add_argument("--memory-gib", type=float, help="expected peak physical memory of the whole workload; overrides host policy")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="command and arguments after --")
    return parser


def check_seconds(parser, option, value):
    """有限で正の秒数の確認

    parser: 不正な値を使い方の誤り（status 2）として報告する parser
    option: 診断に出す option の名前
    value: 利用者が渡した秒数
    """
    if not math.isfinite(value) or value <= 0:
        parser.error(f"{option} must be finite and positive")


def main(arguments):
    """需要と期限を検証して既存supervisorへ一度だけ引き渡す実行

    arguments: 入口とpackageが固定するsupervisorとpolicyとgitに続く利用者の引数
    戻り値: 引数不正または実行file不在の非ゼロstatus
    成功時: supervisorへのexecによるprocessの置換
    """
    program, supervise, policy, git, *tokens = arguments
    parser = build_parser(program)
    started = time.time()
    options = parser.parse_args(tokens)
    if program == DEEP:
        check_seconds(parser, "--seconds", options.seconds)
        wait_seconds = run_seconds = options.seconds
        cpu = []
    else:
        check_seconds(parser, "--wait-seconds", options.wait_seconds)
        check_seconds(parser, "--run-seconds", options.run_seconds)
        if options.cpu_percent < 1:
            parser.error("--cpu-percent must be a positive integer")
        wait_seconds, run_seconds = options.wait_seconds, options.run_seconds
        cpu = ["--resource-cpu", str(options.cpu_percent)]
    command = options.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command after -- is required")
    executable = shutil.which(command[0])
    if executable is None:
        print(f"{parser.prog}: command not found: {command[0]}", file=sys.stderr)
        return 127
    demand = []
    if options.memory_gib is not None:
        if not math.isfinite(options.memory_gib) or options.memory_gib <= 0:
            parser.error("--memory-gib must be finite and positive")
        demand += ["--resource-memory", str(math.ceil(options.memory_gib * 1073741824))]
    os.execv(supervise, [supervise, "--require-drained", "--interrupt-cancels",
                        "--resource-policy", policy,
                        "--resource-wait-until", str(started + wait_seconds),
                        "--resource-run-seconds", str(run_seconds),
                        "--resource-key", resource_key(git, program, command),
                        *cpu, *demand, "--", executable, *command[1:]])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
