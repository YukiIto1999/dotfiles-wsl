"""配備する GitHub MCP が、従来の標準 toolset の全 schema と Actions の読取を公開することを確かめる。

script が読む token file の代わりに合成の token を渡し、exec 行の argv だけをそのまま使う。
"""

import json
import shlex
import subprocess
import sys
import tempfile
import threading

spec = json.loads(sys.argv[1])
failures = []


def argv_of(script):
    with open(script) as handle:
        lines = [line.strip() for line in handle if line.strip().startswith("exec ")]
    if len(lines) != 1 or not lines[0].endswith(' "$@"'):
        raise SystemExit(f"{script}: expected one exec line ending in \"$@\", found {lines}")
    return shlex.split(lines[0][len("exec ") : -len(' "$@"')])


def tools_of(argv):
    with tempfile.TemporaryDirectory() as home:
        return discover_tools(argv, home)


def discover_tools(argv, home):
    process = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env={"HOME": home, "GITHUB_PERSONAL_ACCESS_TOKEN": "synthetic-token"},
    )
    stdin, stdout = process.stdin, process.stdout
    assert stdin is not None and stdout is not None
    # 応答が来なければ server を止め、readline を EOF で抜ける
    watchdog = threading.Timer(60, process.kill)
    watchdog.start()
    try:
        for message in [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "tool-surface", "version": "1"},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ]:
            stdin.write((json.dumps(message) + "\n").encode())
        stdin.flush()
        tools = None
        for line in stdout:
            message = json.loads(line)
            if message.get("id") == 2:
                tools = message["result"]["tools"]
                break
    finally:
        watchdog.cancel()
        process.kill()
        process.wait()
    if tools is None:
        raise SystemExit(f"{argv}: no tools/list reply")
    return {tool["name"]: tool for tool in tools}


actions = {"actions_get", "actions_list", "get_job_logs"}
baseline = [
    "stdio",
    "--toolsets",
    "context,issues,pull_requests,repos,users",
]
for server in spec:
    command = argv_of(server["script"])
    native = tools_of([command[0], *baseline])
    exposed = tools_of(command)
    differences = sorted(name for name, schema in native.items() if exposed.get(name) != schema)
    if differences:
        failures.append(f"{server['name']}: baseline schemas missing or changed: {differences}")
    extra = set(exposed) - set(native)
    if extra != actions:
        failures.append(f"{server['name']}: added operations {sorted(extra)}, expected {sorted(actions)}")
    for name in extra:
        if exposed[name].get("annotations", {}).get("readOnlyHint") is not True:
            failures.append(f"{server['name']}: unexpected write in added operation {name}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
