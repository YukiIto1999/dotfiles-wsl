"""通常のcommandを機全体の資源予約と有限の期限へ接続する公開入口"""

import argparse
import math
import os
import shutil
import sys
import time


def main(arguments):
    """需要と期限を検証して既存supervisorへ一度だけ引き渡す実行

    arguments: packageが固定するsupervisorとpolicyに続く利用者の引数
    戻り値: 引数不正または実行file不在の非ゼロstatus
    成功時: supervisorへのexecによるprocessの置換
    """
    supervise, policy, *tokens = arguments
    parser = argparse.ArgumentParser(
        prog="dotfiles-workload-run", allow_abbrev=False,
        description="Reserve host resources before running a command, without changing its internal parallelism.",
    )
    parser.add_argument("--seconds", type=float, required=True, help="total time budget, including resource wait")
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
                        "--resource-deadline", str(started + options.seconds),
                        *demand, "--", executable, *command[1:]])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
