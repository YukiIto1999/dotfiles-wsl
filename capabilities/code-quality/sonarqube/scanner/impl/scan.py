import argparse
import hashlib
import json
import os
import resource
import signal
from contextlib import suppress
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone
from uuid import uuid4


def timestamp():
    """UTC observation time for evidence provenance

    Returns:
        ISO 8601 timestamp
    """
    return datetime.now(timezone.utc).isoformat()


def git_output(root, *arguments):
    """Repository metadata with explicit command-failure absence

    Args:
        root: Repository working directory
        arguments: Git subcommand arguments
    Returns:
        Raw stdout on success or None on nonzero exit
    """
    result = subprocess.run(
        ["git", "-C", str(root), *arguments], capture_output=True, check=False
    )
    return result.stdout if result.returncode == 0 else None


def observe_input(root):
    """Content observation without a current-analysis guarantee

    Args:
        root: Repository source root
    Returns:
        Revision metadata with a scoped fingerprint or explicit unknown values
    """
    revision = git_output(root, "rev-parse", "HEAD")
    paths = git_output(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    status = git_output(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    if revision is None or paths is None or status is None:
        return {"git_revision": None, "dirty": None, "fingerprint": None}
    observed = {
        "git_revision": revision.decode().strip(),
        "dirty": bool(status),
        "fingerprint": None,
        "fingerprint_scope": "Git tracked and non-ignored untracked files; symlinks hashed as links",
    }
    digest = hashlib.sha256()
    try:
        for relative in sorted(set(paths.split(b"\0")) - {b""}):
            path = root / os.fsdecode(relative)
            digest.update(relative + b"\0")
            if path.is_symlink():
                digest.update(b"link\0" + os.fsencode(os.readlink(path)))
            elif path.is_file():
                with path.open("rb") as source:
                    digest.update(b"file\0" + hashlib.file_digest(source, "sha256").digest())
            else:
                digest.update(b"absent\0")
    except OSError as error:
        observed["observation_error"] = type(error).__name__
    else:
        observed["fingerprint"] = "sha256:" + digest.hexdigest()
    return observed


def run_scan(arguments):
    """Authorized native scan with private execution evidence

    Args:
        arguments: Parsed CLI configuration with a source-external token file
    Returns:
        CLI exit code after native process collection and receipt output
    Raises:
        OSError: Unavailable setup or receipt storage
        ValueError: Invalid project configuration or credential placement
    """
    root = Path(arguments.cwd).resolve(strict=True)
    if not (root / "sonar-project.properties").is_file():
        raise ValueError("project-owned sonar-project.properties is required")
    token_path = Path(arguments.token_file).resolve(strict=True)
    if token_path.is_relative_to(root):
        raise ValueError("scanner credential must be outside the analyzed project")
    token = token_path.read_text().rstrip("\n")
    if not token or "\n" in token or "\r" in token:
        raise ValueError("scanner token file must contain a non-empty single-line value")

    os.umask(0o077)
    run_id = "scan-" + str(uuid4())
    state_root = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    run_directory = state_root / "dotfiles-wsl/code-quality" / run_id
    run_directory.mkdir(parents=True, mode=0o700)
    report = run_directory / "report-task.txt"
    before = observe_input(root)
    receipt = {
        "run_id": run_id,
        "project_key": arguments.project_key,
        "source_root": str(root),
        "server_url": arguments.server_url,
        "scanner_package_version": arguments.scanner_package_version,
        "scan_started_at": timestamp(),
        "input_before": before,
        "project_configuration_sha256": hashlib.sha256(
            (root / "sonar-project.properties").read_bytes()
        ).hexdigest(),
        "quality_gate_wait_requested": arguments.wait,
        "current_applicability": "unassessed",
    }
    environment = os.environ.copy()
    environment["SONAR_TOKEN"] = token
    environment["SONAR_HOST_URL"] = arguments.server_url
    environment["SONAR_SCANNER_OPTS"] = "-Xmx256m -XX:-HeapDumpOnOutOfMemoryError -XX:ErrorFile=/dev/null"
    environment["SONAR_SCANNER_JAVA_OPTS"] = "-Xmx1g -XX:-HeapDumpOnOutOfMemoryError -XX:ErrorFile=/dev/null"
    command = [
        arguments.scanner,
        "-Dsonar.projectKey=" + arguments.project_key,
        "-Dsonar.buildString=" + run_id,
        "-Dsonar.working.directory=" + str(run_directory / "work"),
        "-Dsonar.scanner.metadataFilePath=" + str(report),
        "-Dsonar.verbose=false",
        "-Dsonar.log.level=INFO",
        "-Dsonar.qualitygate.wait=" + str(arguments.wait).lower(),
    ]
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    process = subprocess.Popen(
        command, cwd=root, env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace",
        start_new_session=True,
    )
    wrapper_error = None
    try:
        for line in process.stdout:
            sys.stderr.write(line.replace(token, "[REDACTED]"))
        native_return_code = process.wait()
    except BaseException as error:
        signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGINT))
        with suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        with suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        native_return_code = process.wait()
        wrapper_error = error
    exit_code = native_return_code if native_return_code >= 0 else 128 - native_return_code
    cancel_signal = None
    if isinstance(wrapper_error, SystemExit):
        exit_code = wrapper_error.code
        cancel_signal = exit_code - 128
    elif isinstance(wrapper_error, KeyboardInterrupt):
        cancel_signal = signal.SIGINT
        exit_code = 128 + cancel_signal
    elif wrapper_error is not None:
        exit_code = 1
    after = observe_input(root)
    receipt.update({
        "scan_finished_at": timestamp(),
        "scanner_exit_code": exit_code,
        "scanner_return_code": native_return_code,
        "input_after": after,
        "input_unchanged_at_observations": (
            before == after if before["fingerprint"] and after["fingerprint"] else None
        ),
    })
    if cancel_signal is not None:
        receipt["wrapper_cancel_signal"] = int(cancel_signal)
    elif wrapper_error is not None:
        receipt["wrapper_error"] = type(wrapper_error).__name__
    try:
        if report.is_file():
            receipt["report_task"] = dict(
                line.split("=", 1) for line in report.read_text().splitlines() if "=" in line
            )
    except OSError as error:
        receipt["report_task_error"] = type(error).__name__
    receipt_path = run_directory / "scan.json"
    receipt_path.write_text(json.dumps(receipt, ensure_ascii=True, indent=2) + "\n")
    print(json.dumps({"receipt": str(receipt_path), "scanner_exit_code": exit_code}))
    return exit_code


def terminate_scan(signal_number, _frame):
    """First cancellation with protection against repeated cleanup interruption

    Args:
        signal_number: TERM or INT cancellation signal
        _frame: Interrupted Python execution frame
    Raises:
        SystemExit: Conventional cancellation exit code
    """
    signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGINT))
    raise SystemExit(128 + signal_number)


def main():
    """CLI boundary for authorized project analysis

    Returns:
        Native scan outcome or setup failure exit code
    """
    parser = argparse.ArgumentParser(
        description="Run upstream SonarScanner CLI with a project token file and input receipt. "
                    "Use the build-specific upstream scanner for Maven, Gradle, and .NET."
    )
    parser.add_argument("--scanner", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--scanner-package-version", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--server-url", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--cwd", required=True, help="project root with sonar-project.properties")
    parser.add_argument("--project-key", required=True)
    parser.add_argument("--token-file", required=True, help="project analysis token file; never a token value")
    parser.add_argument("--wait", action="store_true", help="wait for processing and fail on a failing quality gate")
    arguments = parser.parse_args()
    signal.signal(signal.SIGTERM, terminate_scan)
    signal.signal(signal.SIGINT, terminate_scan)
    try:
        return run_scan(arguments)
    except (OSError, ValueError):
        print("SonarScanner setup or input observation failed; check project and credential paths", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
