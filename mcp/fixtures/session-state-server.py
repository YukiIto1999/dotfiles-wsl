import atexit
import json
import os
import signal
import sys
from pathlib import Path


marker_root = Path(os.environ["MCP_SESSION_FIXTURE_ROOT"])
marker_root.mkdir(parents=True, exist_ok=True)
pid = os.getpid()
(marker_root / f"start.{pid}").touch()
state = []


@atexit.register
def mark_exit():
    (marker_root / f"exit.{pid}").touch()


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)


def respond(request, result):
    json.dump({"jsonrpc": "2.0", "id": request["id"], "result": result}, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if "id" not in request:
        continue
    if method == "initialize":
        respond(
            request,
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "session-state-fixture", "version": "1"},
            },
        )
    elif method == "tools/list":
        respond(
            request,
            {
                "tools": [
                    {
                        "name": "state",
                        "description": "Mutate or read session-local state.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "action": {"enum": ["add", "list"]},
                                "value": {"type": "string"},
                            },
                            "required": ["action"],
                        },
                    }
                ]
            },
        )
    elif method == "tools/call":
        arguments = request.get("params", {}).get("arguments", {})
        if arguments.get("action") == "add":
            state.append(arguments["value"])
        respond(
            request,
            {"content": [{"type": "text", "text": json.dumps(state)}], "isError": False},
        )
    else:
        respond(
            request,
            {
                "content": [{"type": "text", "text": f"unsupported method: {method}"}],
                "isError": True,
            },
        )
