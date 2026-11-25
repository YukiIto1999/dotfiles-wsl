"""検証の控えとツール呼び出しの変更検出に使う v4 の作業木の鍵。"""

import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


def git(repo, *args, env=None):
    return subprocess.run(
        ("git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", repo, *args),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    ).stdout


def git_path(repo, name):
    return Path(os.fsdecode(git(repo, "rev-parse", "--path-format=absolute", "--git-path", name).removesuffix(b"\n")))


def gitlink_key(path, scratch):
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return b"unpopulated"
    if not stat.S_ISDIR(mode):
        raise ValueError(f"gitlink {path} が実 directory でない")
    if not any(path.iterdir()):
        return b"unpopulated"
    root = os.fsdecode(git(path, "rev-parse", "--show-toplevel").removesuffix(b"\n"))
    if Path(root).resolve(strict=True) != path.resolve(strict=True):
        raise ValueError(f"gitlink {path} が repository の根でない")
    return tree_key(path, scratch)


def tree_key(repo, scratch_parent):
    with tempfile.TemporaryDirectory(dir=scratch_parent, prefix="dotfiles-gate-key.") as tmp:
        scratch = Path(tmp)
        index = git_path(repo, "index")
        objects = git_path(repo, "objects")
        (scratch / "objects").mkdir()
        # Git が同じ秒に書き換えた file を再検査できるよう index の時刻を保持
        if index.exists():
            shutil.copy2(index, scratch / "index")
        private_index = os.environ | {"GIT_INDEX_FILE": str(scratch / "index")}
        private_tree = private_index | {
            "GIT_OBJECT_DIRECTORY": str(scratch / "objects"),
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(objects),
        }
        git(repo, "-c", "core.splitIndex=false", "add", "-A", ".", env=private_tree)
        tree = git(repo, "-c", "core.splitIndex=false", "write-tree", env=private_tree).removesuffix(b"\n")
        if not re.fullmatch(rb"[0-9a-f]{40}(?:[0-9a-f]{24})?", tree):
            raise ValueError("git write-tree が tree id を返さなかった")
        digest = hashlib.sha256(b"dotfiles-agent-gate-v4\0tree\0" + tree + b"\0untracked\0")
        digest.update(git(repo, "ls-files", "--others", "--exclude-standard", "-z"))
        digest.update(b"\0gitlinks\0")
        staged = git(repo, "ls-files", "--stage", "-z", env=private_index)
        for match in re.finditer(rb"(?:\A|(?<=\0))160000 [0-9a-f]+ [0-3]\t([^\0]+)\0", staged):
            path = match[1]
            digest.update(path + b"\0")
            digest.update(gitlink_key(repo / os.fsdecode(path), scratch) + b"\0")
        digest.update(b"\0")
        return digest.hexdigest().encode("ascii")


if __name__ == "__main__":
    try:
        print(tree_key(Path(sys.argv[1]), Path(sys.argv[2])).decode("ascii"))
    except subprocess.CalledProcessError as error:
        diagnostic = os.fsdecode(error.stderr).splitlines()
        sys.exit(diagnostic[0] if diagnostic else str(error))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
