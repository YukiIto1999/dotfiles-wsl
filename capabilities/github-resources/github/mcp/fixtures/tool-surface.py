"""配備する GitHub MCP の起動 script から実 server を network なしで起動し、公開 tool を数える。

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


def tools_of(script):
    home = tempfile.mkdtemp()
    process = subprocess.Popen(
        argv_of(script),
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
        raise SystemExit(f"{script}: no tools/list reply")
    return {tool["name"]: tool.get("annotations", {}).get("readOnlyHint") is True for tool in tools}


for server in spec["servers"]:
    tools = tools_of(server["script"])
    if not tools:
        failures.append(f"{server['name']}: no tools")
    if server["readOnly"]:
        writes = sorted(name for name, read_only in tools.items() if not read_only)
        if writes:
            failures.append(f"{server['name']}: shared read target exposes writes {writes}")
    else:
        owned = sorted(set(spec["commandOwned"]) & set(tools))
        if owned:
            failures.append(f"{server['name']}: writer still exposes command-owned tools {owned}")
        missing = sorted(set(spec["retained"]) - set(tools))
        if missing:
            failures.append(f"{server['name']}: writer lost retained tools {missing}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
