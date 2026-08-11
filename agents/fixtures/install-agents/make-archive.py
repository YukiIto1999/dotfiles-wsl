import io
import os
import subprocess
import sys
import tarfile
import tempfile


archive, scenario, shell = sys.argv[1:4]
LOGICAL_SIZE_LIMIT = 2_147_483_648


def make_sparse_archive(member_sizes: dict[str, int]) -> None:
    with tempfile.TemporaryDirectory() as directory:
        for name, size in member_sizes.items():
            path = os.path.join(directory, name)
            with open(path, "wb") as sparse_file:
                sparse_file.truncate(size)
            os.chmod(path, 0o644)
        subprocess.run(
            [
                "tar",
                "--create",
                "--gzip",
                "--sparse",
                "--format=gnu",
                "--owner=0",
                "--group=0",
                "--mtime=@1",
                "--file",
                archive,
                "--directory",
                directory,
                *member_sizes.keys(),
            ],
            check=True,
        )


if scenario == "large-member":
    make_sparse_archive({"larger-than-limit": LOGICAL_SIZE_LIMIT + 1})
    sys.exit(0)
if scenario == "large-total":
    half_plus_one = LOGICAL_SIZE_LIMIT // 2 + 1
    make_sparse_archive({"large-a": half_plus_one, "large-b": half_plus_one})
    sys.exit(0)


def entrypoint_body(probe: str) -> bytes:
    checks = f"""#!{shell}
[[ ${{1-}} == --version ]] || exit 91
[[ $0 == /dev/fd/* || $0 == /proc/self/fd/* ]] || exit 102
for descriptor in /proc/self/fd/*; do
  [[ ! -d $descriptor ]] || exit 105
done
{shell} -c 'for descriptor in /proc/self/fd/*; do [[ ! -d $descriptor ]] || exit 1; done' \
  || exit 106
printf '%s\n' probe > ./probe-relative-write
[[ $PWD == /proc/self/cwd ]] || exit 104
[[ $HOME == /proc/self/cwd/../home ]] || exit 92
[[ $CODEX_HOME == /proc/self/cwd/../codex-home ]] || exit 93
[[ $XDG_CACHE_HOME == /proc/self/cwd/../cache ]] || exit 94
[[ $XDG_CONFIG_HOME == /proc/self/cwd/../config ]] || exit 95
[[ $XDG_DATA_HOME == /proc/self/cwd/../data ]] || exit 96
[[ $XDG_STATE_HOME == /proc/self/cwd/../state ]] || exit 97
[[ $TMPDIR == /proc/self/cwd/../tmp ]] || exit 98
[[ $PATH == /proc/self/cwd/../../payload/bin:/proc/self/cwd/../../payload/codex-path ]] || exit 99
[[ $LC_ALL == C && $TERM == dumb ]] || exit 100
[[ -z ${{FIXTURE_INHERITED_SECRET+x}} ]] || exit 101
[[ -z ${{FIXTURE_ATOMIC_HOOK_EVENT+x}} ]] || exit 107
if IFS= read -r fixture_stdin; then exit 103; fi
"""
    if probe == "nonzero":
        checks += "exit 23\n"
    elif probe == "timeout":
        checks += "trap '' TERM\nwhile :; do :; done\n"
    elif probe == "mutate":
        checks += "printf x >>\"$0\"\nprintf '%s\\n' 'codex fixture 1.0.0'\n"
    else:
        checks += "printf '%s\\n' 'codex fixture 1.0.0'\n"
    return checks.encode()


def single_binary_body() -> bytes:
    return f"""#!{shell}
[[ ${{1-}} == --version ]] || exit 91
printf '%s\\n' 'codex fixture 1.0.0'
""".encode()


def add_directory(tar: tarfile.TarFile, name: str, mode: int = 0o755) -> None:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = mode
    info.mtime = 1
    tar.addfile(info)


def add_file(tar: tarfile.TarFile, name: str, data: bytes, mode: int) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.mtime = 1
    tar.addfile(info, io.BytesIO(data))


def add_link(tar: tarfile.TarFile, name: str, target: str, hard: bool) -> None:
    info = tarfile.TarInfo(name)
    info.type = tarfile.LNKTYPE if hard else tarfile.SYMTYPE
    info.linkname = target
    info.mode = 0o755
    info.mtime = 1
    tar.addfile(info)


def add_fifo(tar: tarfile.TarFile, name: str) -> None:
    info = tarfile.TarInfo(name)
    info.type = tarfile.FIFOTYPE
    info.mode = 0o600
    info.mtime = 1
    tar.addfile(info)


required_files = {
    "bin/codex": (entrypoint_body("success"), 0o755),
    "codex-package.json": (b'{"version":"1.0.0"}\n', 0o644),
    "bin/codex-code-mode-host": (b"sidecar\n", 0o755),
    "codex-path/rg": (b"rg\n", 0o755),
    "codex-resources/bwrap": (b"bwrap\n", 0o755),
}

probe = "success"
if scenario.startswith("probe-"):
    probe = scenario.removeprefix("probe-")
    scenario = "valid"
    required_files["bin/codex"] = (entrypoint_body(probe), 0o755)

missing = None
if scenario.startswith("missing:"):
    missing = scenario.removeprefix("missing:")
    scenario = "valid"

single_binary = scenario == "single-binary"
if single_binary:
    scenario = "valid"

version = None
if scenario.startswith("version:"):
    version = scenario.removeprefix("version:")
    scenario = "valid"
    required_files["codex-package.json"] = (
        f'{{"version":"{version}"}}\n'.encode(),
        0o644,
    )

with tarfile.open(archive, "w:gz", format=tarfile.GNU_FORMAT) as tar:
    if single_binary:
        add_file(tar, "opencode", single_binary_body(), 0o755)
    if scenario == "wrapper":
        prefix = "wrapper/"
    else:
        prefix = ""

    if scenario == "absolute":
        add_file(tar, "/absolute", b"absolute\n", 0o644)
    elif scenario == "parent":
        add_file(tar, "../escape", b"escape\n", 0o644)
    elif scenario == "embedded-parent":
        add_file(tar, "bin/../escape", b"escape\n", 0o644)
    elif scenario == "empty-segment":
        add_file(tar, "bin//escape", b"escape\n", 0o644)
    elif scenario == "current-segment":
        add_file(tar, "bin/./escape", b"escape\n", 0o644)
    elif scenario == "backslash":
        add_file(tar, "bin\\escape", b"escape\n", 0o644)
    elif scenario == "control":
        add_file(tar, "bin/control\x01name", b"control\n", 0o644)
    elif scenario == "duplicate-file":
        add_file(tar, "duplicate", b"one\n", 0o644)
        add_file(tar, "duplicate", b"two\n", 0o644)
    elif scenario == "duplicate-directory":
        add_directory(tar, "duplicate/")
        add_directory(tar, "duplicate/")
    elif scenario == "file-directory-collision":
        add_file(tar, "collision", b"file\n", 0o644)
        add_file(tar, "collision/child", b"child\n", 0o644)
    elif scenario == "symlink-internal":
        add_link(tar, "internal-link", "bin/codex", False)
    elif scenario == "symlink-external":
        add_link(tar, "external-link", "/tmp/outside", False)
    elif scenario == "hardlink-internal":
        add_link(tar, "internal-hardlink", "bin/codex", True)
    elif scenario == "hardlink-external":
        add_link(tar, "external-hardlink", "../../outside", True)
    elif scenario == "fifo":
        add_fifo(tar, "fixture-fifo")
    elif scenario == "reserved-marker":
        add_file(tar, ".dotfiles-agent-release.json", b'{"foreign":true}\n', 0o600)

    if not single_binary:
        directories = ["bin/", "codex-path/", "codex-resources/", "extra/"]
        for directory in directories:
            if missing != directory.removesuffix("/"):
                add_directory(tar, prefix + directory)

        for name, (data, mode) in required_files.items():
            if missing == name:
                continue
            if scenario == "wrong-kind" and name == "bin/codex-code-mode-host":
                add_directory(tar, prefix + name + "/")
                continue
            if scenario == "nonexec-required" and name == "codex-path/rg":
                mode = 0o644
            if scenario == "exec-manifest" and name == "codex-package.json":
                mode = 0o755
            add_file(tar, prefix + name, data, mode)

        add_file(tar, prefix + "extra/allowed.txt", b"extra content is permitted\n", 0o644)

        if scenario == "many-members":
            for index in range(4097):
                add_directory(tar, f"many/{index}/")
