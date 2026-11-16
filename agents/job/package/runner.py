"""非対話 job の排他、絶対の実行期限、実行依存の保護を所有する runner。子孫の回収は共通の supervisor へ委ねる。"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO

PROG = "dotfiles-agent-job"
DEADLINE_ENV = "DOTFILES_JOB_DEADLINE"
NAME_ENV = "DOTFILES_JOB_NAME"
RUNTIME_DIRECTORY = "dotfiles-agent-job"
EXIT_SOFTWARE = 70
EXIT_BUSY = 75
EXIT_TIMEOUT = 124
POLL_SECONDS = 0.05
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
EXECUTABLE_NAME = re.compile(r"[a-z][a-z0-9-]*")


class JobError(Exception):
    pass


class Busy(Exception):
    pass


class Cancellation:
    def __init__(self) -> None:
        self.signal: int | None = None

    def __call__(self, signum: int, _frame: object) -> None:
        if self.signal is None:
            self.signal = signum


def say(message: str) -> None:
    print(f"{PROG}: {message}", file=sys.stderr, flush=True)


def runtime_directory() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR", "")
    if not base.startswith("/"):
        raise JobError("XDG_RUNTIME_DIR is not an absolute path; the job lock and roots have no place to live")
    path = Path(base) / RUNTIME_DIRECTORY
    path.mkdir(mode=0o700, exist_ok=True)
    status = path.lstat()
    if not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid():
        raise JobError(f"{path} is not a directory owned by this user")
    return path


def acquire(runtime: Path, name: str) -> int:
    descriptor = os.open(runtime / f"{name}.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        raise Busy() from None
    return descriptor


def prepare(runtime: Path, name: str) -> tuple[Path, Path]:
    """run 専用の roots directory と result の path の用意

    runtime: 利用者専用の runtime directory
    name: job 名
    戻り値: 新規の空の roots directory と file を操作していない result の path の組
    前提: name の排他 lock の保持
    副作用: 前回の roots directory の置換
    失敗: roots が symlink のとき JobError
    """
    roots = runtime / f"{name}.roots"
    if roots.is_symlink():
        raise JobError(f"{roots} is a symlink; refusing to reuse it")
    if roots.exists():
        shutil.rmtree(roots)
    roots.mkdir(mode=0o700)
    return roots, runtime / f"{name}.result"


@dataclass(frozen=True)
class Ended:
    """supervisor 配下で終えた command の結果

    status: supervisor が返した command の終了 status
    drained: command と全ての子孫の終了に対する supervisor の確認
    reason: runner が求めた停止の原因の cancelled と deadline
    reason が None: 停止要求なし
    不変条件: drained が False のとき status は EXIT_SOFTWARE
    不変条件: drained が True で reason が None でないとき job の終了 status は status でなく reason が決定
    """

    status: int
    drained: bool
    reason: str | None = None


@dataclass(frozen=True)
class Run:
    """一回の job 実行が共有する状態

    options: parse が検証した runner の option
    deadline: 絶対の実行期限の epoch 秒
    lock: job 名ごとの排他 lock を保持する file descriptor
    cancellation: 最初に受けた取消 signal の記録
    runtime: lock と roots と result を置く利用者専用の directory
    roots: 実行依存の GC root を置く run 専用の directory
    result: supervisor が終了確認を書く report の path
    不変条件: lock は run の終了までの保持
    不変条件: roots と result は runtime 直下の job 名に固有の path
    """

    options: argparse.Namespace
    deadline: float
    lock: int
    cancellation: Cancellation
    runtime: Path
    roots: Path
    result: Path


@dataclass(frozen=True)
class Worker:
    """実行依存を保護してから起動する worker の指定

    program: worker として起動する実行 file の path
    arguments: 実行 path の option を除いた worker の引数
    executables: option 名から実効の実行 path への対応
    実効の実行 path: 宣言値を既定とし worker の引数で最後に明示した値の優先
    不変条件: arguments は executables の option を含まず元の順序の保持
    """

    program: str
    arguments: list[str]
    executables: dict[str, str]

    def command(self, physical: dict[str, str]) -> list[str]:
        """実行 path を保護済みの物理 path へ固定した worker の起動 command

        physical: executables と同じ option 名から保護済みの物理 path への対応
        戻り値: program の次に --名前 と物理 path の対を physical の順に置き arguments を続けた argv
        """
        options = [token for name, path in physical.items() for token in (f"--{name}", path)]
        return [self.program, *options, *self.arguments]


def stop_reason(run: Run) -> str | None:
    """停止を要する原因の判定

    run: 取消の記録と絶対の実行期限を持つ実行状態
    戻り値: cancelled は取消 signal の受信済み
    戻り値: deadline は取消 signal が未受信で絶対の実行期限の到達済み
    戻り値: None は停止要求なし
    """
    if run.cancellation.signal is not None:
        return "cancelled"
    if time.time() >= run.deadline:
        return "deadline"
    return None


def confirmed_drained(result: Path) -> bool:
    try:
        report = json.loads(result.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return report.get("phase") == "finished" and report.get("drained") is True


def supervise(run: Run, command: list[str], stdout: TextIO | None = None, stderr: TextIO | None = None) -> Ended:
    """supervisor 配下での command の実行

    run: lock と絶対の実行期限と取消の記録と result の path を持つ実行状態
    command: supervisor 配下で起動する command の argv
    stdout: command の標準出力の受け先で None は runner の標準出力
    stderr: command の標準エラーの受け先で None は runner の標準エラー
    戻り値: 停止原因と子孫の終了確認を伴う command の結果
    前提: run.lock が排他済みの file descriptor
    前提: stdout と stderr が file descriptor を持つ open file
    不変条件: runner が先に死んでも supervisor が子孫の終了まで保持する lock
    不変条件: 起動した supervisor の終了後だけの返却
    起動前の停止要求: command を起動せず終了確認済みの結果の返却
    副作用: run.result の以前の report の破棄
    副作用: command の環境への DOTFILES_JOB_DEADLINE と DOTFILES_JOB_NAME の提供
    副作用: 停止要求の受付後の supervisor への TERM 送信と終了待ち
    失敗: supervisor を起動できないとき JobError
    """
    reason = stop_reason(run)
    if reason is not None:
        return Ended(EXIT_SOFTWARE, True, reason)
    run.result.unlink(missing_ok=True)
    environment = {**os.environ, DEADLINE_ENV: f"{run.deadline:.3f}", NAME_ENV: run.options.name}
    try:
        supervisor = subprocess.Popen(
            [
                run.options.supervise,
                "--term-grace", str(run.options.drain_seconds),
                "--result", str(run.result),
                "--hold-fd", str(run.lock),
                "--parent-death-cancels", str(os.getpid()),
                "--", *command,
            ],
            env=environment,
            pass_fds=(run.lock,),
            stdout=stdout,
            stderr=stderr,
        )
    except OSError as error:
        raise JobError(f"cannot start the supervisor: {error}") from None

    reason = None
    while supervisor.poll() is None:
        reason = stop_reason(run)
        if reason is not None:
            # supervisor が SIGINT を無視するため INT のままの転送は不可で TERM へ変換
            supervisor.send_signal(signal.SIGTERM)
            supervisor.wait()
            break
        time.sleep(POLL_SECONDS)

    drained = confirmed_drained(run.result)
    return Ended(supervisor.returncode if drained else EXIT_SOFTWARE, drained, reason)


def hold(run: Run, executables: dict[str, str]) -> tuple[Ended, dict[str, str]]:
    """実行依存と実効の実行 file の GC root 取得

    run: protect の command と保護する実行依存の path と roots の置き場を持つ実行状態
    executables: option 名から実効の実行 path への対応
    戻り値: 保護の結果と option 名から物理 path への対応の組
    物理 path: protect が開いた store object の内側で解決した path
    戻り値の対応: Ended が reason なしで drained が True のとき executables と同じ名前と順序の全件
    戻り値の対応: 他の Ended のとき空で worker は起動不可
    保護対象なし: protect を起動せず status 0 の結果と空の対応
    protect の扱い: 絶対の実行期限と取消の対象で子孫の終了確認までの待機
    前提: run.lock の保持
    前提: run.roots の用意
    失敗: protect が非 0 で終えたとき stderr の末尾を含む JobError
    失敗: protect の出力行数が保護対象の数と異なるとき JobError
    """
    held = run.options.hold
    paths = [*held, *executables.values()]
    if not paths:
        return Ended(0, True), {}
    with (
        tempfile.TemporaryFile("w+", encoding="utf-8", errors="replace", dir=run.runtime) as printed,
        tempfile.TemporaryFile("w+", encoding="utf-8", errors="replace", dir=run.runtime) as errors,
    ):
        command = [run.options.protect, "--resolved", str(run.roots), *paths]
        ended = supervise(run, command, stdout=printed, stderr=errors)
        if ended.reason is not None or not ended.drained:
            return ended, {}
        if ended.status != 0:
            errors.seek(0)
            raise JobError(f"cannot protect the execution dependencies: {errors.read().strip()[-500:]}")
        printed.seek(0)
        resolved = printed.read().splitlines()
    if len(resolved) != len(paths):
        raise JobError("cannot protect the execution dependencies: the protection is incomplete")
    return ended, dict(zip(executables, resolved[len(held):]))


def conclude(run: Run, ended: Ended) -> int:
    """job の終了 status の決定

    run: job 名と取消 signal を持つ実行状態
    ended: 最後の supervise の結果
    戻り値: drained が False のとき EXIT_SOFTWARE
    戻り値: reason が deadline のとき EXIT_TIMEOUT
    戻り値: reason が cancelled のとき 128 に受信した signal 番号を加えた値
    戻り値: 他は ended.status
    戻り値の優先順位: 記述の順
    副作用: 終了未確認と期限と取消の標準エラーへの通知
    """
    name = run.options.name
    if not ended.drained:
        say(f"{name}: the supervisor did not confirm that every process had ended; the roots are kept")
        return EXIT_SOFTWARE
    if ended.reason == "deadline":
        say(f"{name}: the execution limit was reached")
        return EXIT_TIMEOUT
    if ended.reason == "cancelled":
        say(f"{name}: cancelled")
        return 128 + (run.cancellation.signal or signal.SIGTERM)
    return ended.status


def execute(run: Run, worker: Worker) -> tuple[int, bool]:
    """実行依存の保護後の worker の実行

    run: 実行状態
    worker: 起動する worker と実効の実行 path
    戻り値: job の終了 status と子孫の終了確認の組
    戻り値の drained: False の間 roots の解放不可
    前提: run.lock の保持
    前提: run.roots の用意
    不変条件: worker の起動は保護の完了確認後に限る
    不変条件: worker の実行 path は保護済みの物理 path
    不変条件: 保護が完了しないとき worker 未起動
    失敗: hold と supervise の JobError
    """
    ended, physical = hold(run, worker.executables)
    if ended.reason is None and ended.drained:
        # profile は保護の後も動くため設定 path のままの起動は不可
        ended = supervise(run, worker.command(physical))
    return conclude(run, ended), ended.drained


def executable_declaration(text: str) -> tuple[str, str]:
    """--executable の NAME=ABSOLUTE-PATH 形式の値の解釈

    text: NAME と ABSOLUTE-PATH を最初の = でつないだ値
    NAME: 英小文字で始まる英小文字と数字とハイフンの並び
    ABSOLUTE-PATH: / で始まる path
    戻り値: -- を除く option 名と絶対 path の組
    失敗: NAME=ABSOLUTE-PATH の形式違反は ArgumentTypeError
    """
    name, separator, path = text.partition("=")
    if not separator or not EXECUTABLE_NAME.fullmatch(name) or not path.startswith("/"):
        raise argparse.ArgumentTypeError(f"expected NAME=ABSOLUTE-PATH: {text}")
    return name, path


def executable_option(parser: argparse.ArgumentParser, declared: dict[str, str], option: str) -> str | None:
    """worker の引数の option が宣言済みの実行 file を指すかの判定

    parser: 略記の拒否を usage error として報告する parser
    declared: 宣言済みの option 名から既定の path への対応
    option: worker の引数の最初の = より前の部分
    戻り値: --名前 と完全に一致する宣言済みの option 名
    戻り値: 該当しない引数は None
    失敗: 宣言済みの --名前 の略記は status 2 の usage error
    """
    if not option.startswith("--") or option == "--":
        return None
    exact = option[2:]
    if exact in declared:
        return exact
    for name in declared:
        spelled = f"--{name}"
        if spelled.startswith(option):
            parser.error(f"{option} abbreviates {spelled}; write the option in full")
    return None


def choose_executables(
    parser: argparse.ArgumentParser, declared: dict[str, str], arguments: list[str]
) -> tuple[dict[str, str], list[str]]:
    """worker の引数が明示した実行 path を反映した実効の実行 path の確定

    parser: 不正な指定を usage error として報告する parser
    declared: 宣言済みの option 名から既定の path への対応
    arguments: program を除いた worker の引数
    戻り値: 実効の実行 path の対応と実行 path の option を除いた残りの引数の組
    実効の対応: declared の全ての名前を含み最後に明示した値が既定に優先
    残りの引数: 元の順序の保持
    失敗: 略記した宣言済み option は status 2 の usage error
    失敗: 値のない宣言済み option は status 2 の usage error
    失敗: 空の値の宣言済み option は status 2 の usage error
    """
    chosen = dict(declared)
    remaining: list[str] = []
    waiting: str | None = None
    for argument in arguments:
        if waiting is not None:
            chosen[waiting] = argument
            waiting = None
            continue
        option, equals, value = argument.partition("=")
        name = executable_option(parser, declared, option)
        if name is None:
            remaining.append(argument)
        elif equals:
            chosen[name] = value
        else:
            waiting = name
    if waiting is not None:
        parser.error(f"--{waiting} needs a value")
    for name, path in chosen.items():
        if not path:
            parser.error(f"--{name} needs a value")
    return chosen, remaining


def parse(argv: list[str] | None) -> tuple[argparse.Namespace, Worker]:
    """runner の command line の解釈

    argv: runner の option と -- と worker の command を並べた program 名を除く引数
    argv が None: sys.argv[1:] の使用
    戻り値: 検証済みの option と実効の実行 path を確定した worker の組
    失敗: -- がないとき使い方を示す SystemExit
    失敗: 検証に反する option と worker の指定は status 2 の usage error
    """
    arguments = sys.argv[1:] if argv is None else argv
    if "--" not in arguments:
        raise SystemExit(f"{PROG}: usage: {PROG} OPTIONS -- WORKER [ARG...]")
    split = arguments.index("--")
    parser = argparse.ArgumentParser(prog=PROG)
    parser.add_argument("--name", required=True)
    parser.add_argument("--limit-seconds", required=True, type=float)
    parser.add_argument("--drain-seconds", required=True, type=float)
    parser.add_argument("--supervise", required=True)
    parser.add_argument("--protect", required=True)
    parser.add_argument("--hold", action="append", default=[])
    parser.add_argument("--executable", action="append", default=[], type=executable_declaration, metavar="NAME=PATH")
    options = parser.parse_args(arguments[:split])
    command = arguments[split + 1 :]
    if not NAME.fullmatch(options.name):
        parser.error(f"invalid job name: {options.name}")
    if not command:
        parser.error("no worker command after --")
    if options.limit_seconds <= 0 or options.drain_seconds <= 0:
        parser.error("--limit-seconds and --drain-seconds must be positive")
    declared: dict[str, str] = {}
    for name, path in options.executable:
        if name in declared:
            parser.error(f"executable declared twice: {name}")
        declared[name] = path
    executables, remaining = choose_executables(parser, declared, command[1:])
    return options, Worker(command[0], remaining, executables)


def main(argv: list[str] | None = None) -> int:
    """job 名ごとの排他と絶対の実行期限の下での worker の一回の実行

    argv: parse が受ける引数で None は sys.argv[1:]
    戻り値: 正常終了での worker の終了 status
    戻り値: EXIT_BUSY は同じ job 名の別の run による lock の保持
    戻り値: EXIT_TIMEOUT は絶対の実行期限の到達
    戻り値: 128 に signal 番号を加えた値は取消
    戻り値: EXIT_SOFTWARE は runner の失敗と子孫の終了未確認
    副作用: TERM と INT と HUP の取消 handler の登録
    不変条件: roots の解放は子孫の終了確認後に限る
    失敗: parse の使い方の誤りは SystemExit
    """
    started = time.time()
    options, worker = parse(argv)
    deadline = started + options.limit_seconds
    cancellation = Cancellation()
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, cancellation)

    roots: Path | None = None
    status = EXIT_SOFTWARE
    drained = True
    try:
        runtime = runtime_directory()
        lock = acquire(runtime, options.name)
        try:
            roots, result = prepare(runtime, options.name)
            run = Run(options, deadline, lock, cancellation, runtime, roots, result)
            status, drained = execute(run, worker)
        finally:
            if roots is not None and drained:
                try:
                    shutil.rmtree(roots)
                except OSError as error:
                    say(f"{options.name}: roots could not be released: {error}")
                    status = status or EXIT_SOFTWARE
    except Busy:
        say(f"{options.name}: another run holds this job; it was not started")
        return EXIT_BUSY
    except JobError as error:
        say(f"{options.name}: {error}")
        return EXIT_SOFTWARE
    return status


if __name__ == "__main__":
    sys.exit(main())
