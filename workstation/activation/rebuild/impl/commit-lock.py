"""基点HEADを固定した候補lock commitの作成とCAS公開

実行時の子孫回収を呼び出し側の共通supervisorへ委ねる内部command
"""

import argparse
import contextlib
import os
import subprocess
import sys
from pathlib import Path


def git(source: Path, *arguments: str, environment: dict | None = None, capture: bool = True) -> str:
    """同じcheckoutの設定を使うnative Git操作

    Args:
        source: commandの作業directoryとなる元checkout
        arguments: Gitへそのまま渡すargv
        environment: indexを指定する操作の実行環境
        capture: 戻り値としてstdoutを受け取る指定
    Returns:
        capture指定時の末尾改行を除いたstdout
        capture指定なしの空文字列
    Raises:
        subprocess.CalledProcessError: Gitが拒否した操作
    """
    result = subprocess.run(
        ["git", "-C", str(source), *arguments],
        env=environment,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.removesuffix("\n") if capture else ""


@contextlib.contextmanager
def head_guard(source: Path, expected: str):
    """基点HEADへの変更を排除するnative ref transaction

    Args:
        source: HEADを固定する元checkout
        expected: 排他取得時に要求するcommit ID
    Yields:
        HEADを固定した作業区間
    Raises:
        RuntimeError: HEADの排他取得の失敗
    """
    with subprocess.Popen(
        ["git", "-C", str(source), "update-ref", "--stdin"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as transaction:
        assert transaction.stdin is not None and transaction.stdout is not None
        try:
            transaction.stdin.write(f"start\nverify HEAD {expected}\nprepare\n")
            transaction.stdin.flush()
            replies = [transaction.stdout.readline(), transaction.stdout.readline()]
            if replies != ["start: ok\n", "prepare: ok\n"]:
                raise RuntimeError("could not lock the expected HEAD; flake.lock was not written")
            yield
        finally:
            if transaction.poll() is None:
                try:
                    transaction.stdin.write("abort\n")
                    transaction.stdin.flush()
                except BrokenPipeError:
                    pass
                transaction.stdin.close()
            transaction.wait()


def effective_git_configuration(source: Path, *context: str) -> dict[str, list[str | None]]:
    """includeの記録を除いた実効Git設定の比較値

    Args:
        source: 設定を読む元checkout
        context: Git directoryとworktreeを指定する追加のglobal option
    Returns:
        設定名から出現順を保つ値の列への対応
        値がないboolean設定のNone
    """
    values: dict[str, list[str | None]] = {}
    for entry in git(source, *context, "config", "--null", "--list").split("\0"):
        if not entry:
            continue
        key, separator, value = entry.partition("\n")
        if key == "include.path" or key.startswith("includeif.") and key.endswith(".path"):
            continue
        values.setdefault(key, []).append(value if separator else None)
    return values


def commit(options: argparse.Namespace) -> None:
    """元checkoutのhookを保つ候補commitの条件付き公開

    Args:
        options: 元checkoutと候補lockと基点と作業directoryと期待するblobと件名の指定
    副作用:
        work/commit-worktree-requested: 登録の解放確認が必要な状態のmarker
        work/lock-tree: 元indexへの書込み前に記録する候補tree ID
        work/commit-id: CAS公開前に記録する検証済み候補commit ID
        commit-idの存在: 元HEADへの公開成功の保証なし
        設定済みhookによる元worktreeとindexの変更
    回収: 子孫の終了確認後のcallerによる一時worktree登録と作業directoryの解放
    残存: 正常返却と例外後もcallerの回収まで保持する作成済みのmarkerとjournal
    Raises:
        RuntimeError: 候補または元checkoutの不一致
        subprocess.CalledProcessError: native Gitによる作成または公開の拒否
    """
    source = options.source.resolve()
    work = options.work.resolve()
    private = work / "commit-worktree"
    requested = work / "commit-worktree-requested"
    tree = None
    requested.touch()
    git(source, "worktree", "add", "--quiet", "--detach", "--no-checkout", str(private), options.base)
    private_git = git(private, "rev-parse", "--absolute-git-dir")
    index = git(source, "rev-parse", "--path-format=absolute", "--git-path", "index")
    actual_index = os.environ | {"GIT_INDEX_FILE": index}
    temporary_index = os.environ | {"GIT_INDEX_FILE": str(work / "lock-index")}
    private_context = [f"--git-dir={private_git}", f"--work-tree={source}"]
    original_config = Path(git(source, "rev-parse", "--path-format=absolute", "--git-path", "config.worktree"))
    if original_config.is_file() and git(source, "config", "--type=bool", "--default=false", "--get", "extensions.worktreeConfig") == "true":
        # config.worktreeの相対includeの基準directoryが変わるためnativeコピーだけによる設定継承は不可
        inherited_config = Path(private_git) / "inherited-config"
        git(source, "config", "--file", str(inherited_config), "--add", "include.path", str(original_config))
        os.replace(inherited_config, Path(private_git) / "config.worktree")
    with head_guard(source, options.base):
        if effective_git_configuration(source) != effective_git_configuration(source, *private_context):
            raise RuntimeError("the private worktree changes effective Git configuration; flake.lock was not written")
        if git(source, "--no-optional-locks", "status", "--porcelain", "--untracked-files=all"):
            raise RuntimeError("the checkout changed; flake.lock was not written")
        try:
            git(source, "update-index", "-q", "--refresh")
            if git(source, "hash-object", "-w", str(options.lock)) != options.blob:
                raise RuntimeError("the candidate flake.lock changed")
            git(source, "read-tree", options.base, environment=temporary_index)
            mode = git(source, "ls-files", "-s", "--", "flake.lock", environment=temporary_index).split()[0]
            git(source, "update-index", "--cacheinfo", f"{mode},{options.blob},flake.lock", environment=temporary_index)
            tree = git(source, "write-tree", environment=temporary_index)
            (work / "lock-tree").write_text(tree + "\n", encoding="ascii")
            git(source, "read-tree", "-m", "-u", options.base, tree)
            # 元のHEADを使うcommitは保護中のrefへ書けないためprivate HEADなしのcommitは不可
            git(source, *private_context, "commit", "--quiet", "-m", options.subject, "--", "flake.lock", environment=actual_index, capture=False)
            candidate = git(source, *private_context, "rev-parse", "HEAD")
            if git(source, "rev-parse", f"{candidate}^") != options.base:
                raise RuntimeError("the candidate commit does not sit on the expected base")
            if git(source, "diff-tree", "--no-commit-id", "--name-only", "-r", candidate) != "flake.lock":
                raise RuntimeError("a commit hook changed more than flake.lock")
            if git(source, "rev-parse", f"{candidate}:flake.lock") != options.blob:
                raise RuntimeError("a commit hook changed the candidate flake.lock")
            if git(source, *private_context, "--no-optional-locks", "status", "--porcelain", "--untracked-files=all", environment=actual_index):
                raise RuntimeError("the working tree is not clean after the commit hooks")
            (work / "commit-id").write_text(candidate + "\n", encoding="ascii")
        except BaseException:
            if tree is not None:
                subprocess.run(["git", "-C", str(source), "read-tree", "-m", "-u", tree, options.base], check=False)
            raise
    # 排他を解いた後のHEAD更新を上書きするためold-oidを省いた公開は不可
    git(source, "update-ref", "-m", f"commit: {options.subject}", "HEAD", candidate, options.base)


def main() -> int:
    """共通supervisor配下から呼ぶlock更新の入口

    Returns:
        公開成功時の0または拒否時の1
        子孫の終了と一時登録の解放に対するこのstatusだけによる保証なし
    """
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--source", type=Path, required=True, help="操作対象の元checkout")
    parser.add_argument("--work", type=Path, required=True, help="呼び出し側が保持する作業directory")
    parser.add_argument("--base", required=True, help="排他取得時に要求するcommit ID")
    parser.add_argument("--lock", type=Path, required=True, help="検証済み候補のflake.lock")
    parser.add_argument("--blob", required=True, help="検証済み候補lockのblob ID")
    parser.add_argument("--subject", required=True, help="native commitの件名")
    try:
        commit(parser.parse_args())
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"dotfiles-rebuild: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
