import argparse
import ctypes
import json
import os
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


STARTUP_SECONDS = 5
CLEANUP_SECONDS = 5
PR_SET_CHILD_SUBREAPER = 36
CASES = ("cancel-term", "cancel-int", "normal-nonzero", "normal-success", "help", "version")


def owned_children(pid):
    try:
        return [int(value) for value in Path(f"/proc/{pid}/task/{pid}/children").read_text().split()]
    except FileNotFoundError:
        return []


def stop_fixture_tree(pid):
    try:
        os.kill(pid, signal.SIGSTOP)
    except ProcessLookupError:
        return
    for child in owned_children(pid):
        stop_fixture_tree(child)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def reclaim_fixture_children():
    deadline = time.monotonic() + CLEANUP_SECONDS
    while True:
        for child in owned_children(os.getpid()):
            stop_fixture_tree(child)
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if time.monotonic() >= deadline:
            raise AssertionError("the outer fixture harness could not reap its owned processes")
        if pid == 0:
            time.sleep(0.01)


def read_ready(process):
    deadline = time.monotonic() + STARTUP_SECONDS
    pending = b""
    while time.monotonic() < deadline:
        readable, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
        if not readable:
            break
        chunk = os.read(process.stdout.fileno(), 4096)
        if not chunk:
            raise AssertionError(f"native fixture exited before readiness: {process.stderr.read().decode()}")
        pending += chunk
        if b"\n" in pending:
            return json.loads(pending.split(b"\n", 1)[0])
    raise AssertionError("native fixture did not become ready within the startup deadline")


def assert_absent(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return
    raise AssertionError(f"owned process {pid} remains after launcher return (including unreaped zombies)")


def assert_descendant_stopped_and_reap(pid):
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        try:
            reaped, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            assert_absent(pid)
            return
        if reaped == pid:
            return
        time.sleep(0.01)
    raise AssertionError(f"owned descendant {pid} is still running after launcher return")


def check_case(case, launcher, key, runtime_root, fixture):
    control_directory = runtime_root / "strix.positive-control"
    control_directory.mkdir()
    control_marker = control_directory / "keep"
    control_marker.write_text("unrelated positive control")
    control = subprocess.Popen([sys.executable, str(fixture), "--control"], start_new_session=True)
    try:
        environment = os.environ.copy()
        for name in ("LLM_API_KEY", "LLM_API_BASE", "STRIX_LLM", "LLM_EXTRA_HEADERS", "XDG_RUNTIME_DIR"):
            environment.pop(name, None)
        environment.update(
            STRIX_FIXTURE_MODE="normal" if case.startswith("normal-") else "cancel",
            STRIX_FIXTURE_STATUS="37" if case == "normal-nonzero" else "0",
        )
        if case in ("help", "version"):
            key.unlink(missing_ok=True)
            result = subprocess.run(
                [str(launcher), f"--{case}"], env=environment, capture_output=True, timeout=STARTUP_SECONDS
            )
            assert result.returncode == 0, (case, result.returncode, result.stderr.decode())
            assert list(runtime_root.iterdir()) == [control_directory], "no-key informational invocation created config"
        else:
            key.write_text("synthetic-fixture-not-a-credential\n")
            environment["XDG_RUNTIME_DIR"] = str(runtime_root)
            process = subprocess.Popen(
                [str(launcher), "target with spaces", "--max-turns", "1"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            observation = read_ready(process)
            config_directory = Path(observation["config"]).parent
            assert config_directory.parent == runtime_root
            assert config_directory != control_directory
            expected = int(environment["STRIX_FIXTURE_STATUS"])
            started = time.monotonic()
            if case.startswith("cancel-"):
                cancellation = signal.SIGTERM if case == "cancel-term" else signal.SIGINT
                expected = 128 + cancellation
                process.send_signal(cancellation)
            try:
                status = process.wait(timeout=CLEANUP_SECONDS)
            except subprocess.TimeoutExpired as error:
                raise AssertionError(f"{case}: launcher did not finish owned cleanup within {CLEANUP_SECONDS}s") from error
            elapsed = time.monotonic() - started
            assert status == expected, (case, status, expected, process.stderr.read().decode())
            assert elapsed < CLEANUP_SECONDS, (case, elapsed)
            assert_absent(observation["child"])
            assert_descendant_stopped_and_reap(observation["descendant"])
            assert not config_directory.exists(), f"{case}: invocation config directory remains"
            assert list(runtime_root.iterdir()) == [control_directory], f"{case}: invocation tmpfs artifacts remain"
            print(f"{case}: status={status}; elapsed={elapsed:.3f}s; direct child joined; descendant stopped/reaped by fixture; config absent")
        assert control.poll() is None, f"{case}: unrelated process was stopped"
        assert control_marker.read_text() == "unrelated positive control", f"{case}: unrelated directory was changed"
    finally:
        control.terminate()
        control.wait(timeout=CLEANUP_SECONDS)
        control_marker.unlink()
        control_directory.rmdir()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--entry", type=Path, required=True)
    parser.add_argument("--case", choices=CASES)
    arguments = parser.parse_args()
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "fixture subreaper setup failed")
    fixture = Path(__file__).with_name("native-child.py")
    bash = shutil.which("bash")
    assert bash is not None, "fixture requires Bash on PATH"
    with tempfile.TemporaryDirectory(prefix="strix-runtime-fixture-") as work_path:
        with tempfile.TemporaryDirectory(prefix="strix-runtime-fixture-", dir="/dev/shm") as runtime_path:
            work = Path(work_path)
            runtime_root = Path(runtime_path)
            assert subprocess.check_output(["stat", "-f", "-c", "%T", str(runtime_root)]).strip() == b"tmpfs"
            key = work / "synthetic-key"
            native = work / "synthetic-native"
            native.write_text(f"#!{bash}\nexec {shlex.quote(sys.executable)} {shlex.quote(str(fixture))} \"$@\"\n")
            native.chmod(0o700)
            source = arguments.entry.read_text()
            replacements = {"@upstream@": shlex.quote(str(native)), "@goApiKeyFile@": shlex.quote(str(key)), "@image@": "synthetic-no-container"}
            for name, value in replacements.items():
                source = source.replace(name, value)
            launcher = work / "strix"
            launcher.write_text(f"#!{bash}\nset -euo pipefail\n" + source)
            launcher.chmod(0o700)
            try:
                for case in (arguments.case,) if arguments.case else CASES:
                    check_case(case, launcher, key, runtime_root, fixture)
            finally:
                reclaim_fixture_children()


if __name__ == "__main__":
    main()
