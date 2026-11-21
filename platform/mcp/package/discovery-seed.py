"""Capture and check the discovery seed a dormant lazy stdio MCP front serves.

``capture --output FILE -- EXECUTABLE`` starts the fixed executable once per known
protocol version, offers that version in ``initialize``, sends
``notifications/initialized`` and then every standard list request without params.
It records the server's own reply to each request (result or JSON-RPC error) and
never calls a tool, reads a resource or gets a prompt.  Every version is captured
in two fresh processes; replies that differ between them are not a seed.

Each process gets only a private HOME, TMPDIR and RUNTIME_DIRECTORY, the
environment a session front gives its child, and nothing of the caller's
environment, so no credential, proxy or telemetry setting of the caller reaches
it.  Local seeds are generated inside the network-less Nix build sandbox.

``check [--public] FILE`` validates a seed with the same rules, which the gateway
also enforces at config load.  ``--public`` additionally rejects strings that name
user, temporary or store paths, for seeds captured from remote endpoints and
committed to the repository.

The seed shape:

    {"protocols": {"<offered version>": [
        {"method": "initialize", "params": null, "result": {...}},
        {"method": "tools/list", "params": null, "result": {...} | "error": {...}},
        ...]}}
"""

import argparse
import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

PROTOCOL_VERSIONS = ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25")
# The capability that obliges a server to answer each list request.
LIST_CAPABILITIES = {
    "tools/list": "tools",
    "prompts/list": "prompts",
    "resources/list": "resources",
    "resources/templates/list": "resources",
}
LIST_METHODS = tuple(LIST_CAPABILITIES)
CAPTURES_PER_VERSION = 2
INITIALIZE_TIMEOUT_SECONDS = 120.0
LIST_TIMEOUT_SECONDS = 60.0
CLOSE_GRACE_SECONDS = 10.0
TERM_GRACE_SECONDS = 5.0
METHOD_NOT_FOUND = -32601
CLIENT_INFO = {"name": "dotfiles-mcp-discovery-seed", "version": "1"}
PRIVATE_MARKERS = ("/home/", "/root/", "/run/user/", "/tmp/", "/nix/store/")


class SeedError(Exception):
    """A server reply or seed file that cannot become a seed."""


class Server:
    """One stdio MCP server process that owns its process group."""

    def __init__(self, executable, workdir):
        environment = {}
        for name, variable in (("home", "HOME"), ("tmp", "TMPDIR"), ("runtime", "RUNTIME_DIRECTORY")):
            path = os.path.join(workdir, name)
            os.mkdir(path, 0o700)
            environment[variable] = path
        self.stderr_path = os.path.join(workdir, "stderr")
        with open(self.stderr_path, "wb") as stderr:
            self.process = subprocess.Popen(
                [executable],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=stderr,
                cwd=environment["RUNTIME_DIRECTORY"],
                env=environment,
                start_new_session=True,
            )
        assert self.process.stdin is not None and self.process.stdout is not None
        self.input = self.process.stdin
        self.output = self.process.stdout
        self.messages = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.output:
            self.messages.put(line)
        self.messages.put(None)

    def _send(self, message):
        try:
            self.input.write(json.dumps(message).encode() + b"\n")
            self.input.flush()
        except OSError as error:
            raise SeedError(f"server input closed: {error}") from error

    def notify(self, method):
        self._send({"jsonrpc": "2.0", "method": method})

    def request(self, method, params, timeout):
        """The reply to one request; requests the server sends meanwhile are answered."""
        self.next_id += 1
        request_id = self.next_id
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self._send(message)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SeedError(f"{method}: no reply within {timeout:g}s")
            try:
                line = self.messages.get(timeout=remaining)
            except queue.Empty:
                continue
            if line is None:
                raise SeedError(f"{method}: server output ended before the reply")
            try:
                reply = json.loads(line)
            except ValueError as error:
                raise SeedError(f"{method}: server wrote a line that is not JSON-RPC") from error
            if not isinstance(reply, dict) or reply.get("jsonrpc") != "2.0":
                raise SeedError(f"{method}: server wrote a message that is not JSON-RPC 2.0")
            if "method" in reply:
                if "id" in reply:
                    self._answer(reply)
                continue
            if reply.get("id") != request_id:
                raise SeedError(f"{method}: reply to an unknown request id {reply.get('id')!r}")
            return reply

    def _answer(self, request):
        # The capture offers no client capability; only ping is owed an answer.
        if request["method"] == "ping":
            self._send({"jsonrpc": "2.0", "id": request["id"], "result": {}})
        else:
            self._send({
                "jsonrpc": "2.0",
                "id": request["id"],
                "error": {"code": METHOD_NOT_FOUND, "message": "Method not found"},
            })

    def close(self):
        """Ends the server and every process left in its group."""
        try:
            self.input.close()
        except OSError:
            pass
        try:
            self.process.wait(CLOSE_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            self._signal_group(signal.SIGTERM)
            try:
                self.process.wait(TERM_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                self._signal_group(signal.SIGKILL)
                self.process.wait()
        self._signal_group(signal.SIGKILL)

    def _signal_group(self, number):
        try:
            os.killpg(self.process.pid, number)
        except ProcessLookupError:
            pass

    def stderr_tail(self, limit=4000):
        with open(self.stderr_path, "rb") as stderr:
            return stderr.read().decode(errors="replace")[-limit:]


def entry_of(method, reply):
    """The seed entry of one reply, keeping a JSON-RPC error exactly as received."""
    if ("result" in reply) == ("error" in reply):
        raise SeedError(f"{method}: reply carries neither or both of result and error")
    entry = {"method": method, "params": None}
    if "result" in reply:
        entry["result"] = reply["result"]
    else:
        entry["error"] = reply["error"]
    return entry


def capture_version(executable, version, workdir):
    server = Server(executable, workdir)
    try:
        initialize = {"protocolVersion": version, "capabilities": {}, "clientInfo": CLIENT_INFO}
        entries = [entry_of("initialize", server.request("initialize", initialize, INITIALIZE_TIMEOUT_SECONDS))]
        if "result" not in entries[0]:
            raise SeedError(f"initialize failed: {json.dumps(entries[0]['error'])}")
        server.notify("notifications/initialized")
        for method in LIST_METHODS:
            entries.append(entry_of(method, server.request(method, None, LIST_TIMEOUT_SECONDS)))
        return entries
    except SeedError as error:
        raise SeedError(f"{version}: {error}\n--- server stderr ---\n{server.stderr_tail()}") from error
    finally:
        server.close()


def check_entries(version, entries):
    if not isinstance(entries, list) or [entry.get("method") if isinstance(entry, dict) else None for entry in entries] != [
        "initialize",
        *LIST_METHODS,
    ]:
        raise SeedError(f"{version}: entries must be initialize followed by {', '.join(LIST_METHODS)}")
    for entry in entries:
        method = entry["method"]
        outcomes = [key for key in ("result", "error") if key in entry]
        if set(entry) != {"method", "params", *outcomes} or len(outcomes) != 1:
            raise SeedError(f"{version} {method}: entry must hold method, params and one of result or error")
        if entry["params"] is not None:
            raise SeedError(f"{version} {method}: params must be null")
        if "error" in entry:
            error = entry["error"]
            if (
                not isinstance(error, dict)
                or not set(error) <= {"code", "message", "data"}
                or not isinstance(error.get("code"), int)
                or isinstance(error.get("code"), bool)
                or not isinstance(error.get("message"), str)
            ):
                raise SeedError(f"{version} {method}: error must be a JSON-RPC error object")
        elif not isinstance(entry["result"], dict):
            raise SeedError(f"{version} {method}: result must be an object")
    initialize = entries[0]
    if "result" not in initialize:
        raise SeedError(f"{version}: initialize must have a result")
    result = initialize["result"]
    capabilities = result.get("capabilities")
    if (
        not isinstance(result.get("protocolVersion"), str)
        or not isinstance(capabilities, dict)
        or not isinstance(result.get("serverInfo"), dict)
    ):
        raise SeedError(f"{version}: initialize result lacks protocolVersion, capabilities or serverInfo")
    for entry in entries[1:]:
        method = entry["method"]
        advertised = capabilities.get(LIST_CAPABILITIES[method]) is not None
        if "error" in entry and advertised:
            raise SeedError(f"{version} {method}: advertised capability answered with an error")
        if "result" in entry and "nextCursor" in entry["result"]:
            raise SeedError(f"{version} {method}: paginated list; a seed holds only complete single-page lists")


def strings_of(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from strings_of(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings_of(item)


def check_private(seed, markers):
    for text in strings_of(seed):
        for marker in markers:
            if marker and marker in text:
                raise SeedError(f"seed names a private or session-specific path containing {marker!r}")


def check_seed(seed, public):
    if not isinstance(seed, dict) or set(seed) != {"protocols"}:
        raise SeedError("seed must be an object with only protocols")
    protocols = seed["protocols"]
    if not isinstance(protocols, dict) or sorted(protocols) != sorted(PROTOCOL_VERSIONS):
        raise SeedError(f"protocols must be exactly {', '.join(PROTOCOL_VERSIONS)}")
    for version in PROTOCOL_VERSIONS:
        check_entries(version, protocols[version])
    if public:
        check_private(seed, PRIVATE_MARKERS)


def capture(executable, output):
    if not os.path.isabs(executable) or not os.access(executable, os.X_OK):
        raise SeedError(f"executable must be an absolute executable path: {executable}")
    workdir = tempfile.mkdtemp(prefix="mcp-discovery-seed.")
    try:
        protocols = {}
        for version in PROTOCOL_VERSIONS:
            captures = []
            for attempt in range(CAPTURES_PER_VERSION):
                directory = os.path.join(workdir, f"{version}.{attempt}")
                os.mkdir(directory, 0o700)
                captures.append(capture_version(executable, version, directory))
            if any(other != captures[0] for other in captures[1:]):
                raise SeedError(f"{version}: discovery differs between fresh processes")
            protocols[version] = captures[0]
        seed = {"protocols": protocols}
        check_seed(seed, public=False)
        check_private(seed, (workdir, os.path.realpath(workdir)))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    with open(output, "x", encoding="utf-8") as file:
        json.dump(seed, file, indent=2, sort_keys=True, ensure_ascii=False)
        file.write("\n")


def main(arguments):
    parser = argparse.ArgumentParser(description="Capture or check an MCP discovery seed.")
    commands = parser.add_subparsers(dest="command", required=True)
    capture_parser = commands.add_parser("capture")
    capture_parser.add_argument("--output", required=True)
    capture_parser.add_argument("executable")
    check_parser = commands.add_parser("check")
    check_parser.add_argument("--public", action="store_true")
    check_parser.add_argument("seed")
    options = parser.parse_args(arguments)
    try:
        if options.command == "capture":
            capture(options.executable, options.output)
        else:
            with open(options.seed, encoding="utf-8") as file:
                check_seed(json.load(file), options.public)
    except (SeedError, OSError, ValueError) as error:
        print(f"discovery-seed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
