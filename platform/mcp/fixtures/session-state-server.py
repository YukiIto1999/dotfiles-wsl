import atexit
import json
import os
import signal
import sys
from pathlib import Path


# discovery seed の生成は利用者の環境を渡さないため、marker の置き場が無い起動では記録しない
marker_root = os.environ.get("MCP_SESSION_FIXTURE_ROOT")
pid = os.getpid()
calls = 0
state = []


def mark(name):
    if marker_root is not None:
        Path(marker_root).mkdir(parents=True, exist_ok=True)
        (Path(marker_root) / name).touch()


mark(f"start.{pid}")


@atexit.register
def mark_exit():
    mark(f"exit.{pid}")


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)


def respond(request, result):
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})


def send(message):
    json.dump(message, sys.stdout)
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
        # 呼出しが child へ届いたことの記録。discovery の不一致で止めた呼出しは残さない
        calls += 1
        mark(f"call.{pid}.{calls}")
        arguments = request.get("params", {}).get("arguments", {})
        if arguments.get("action") == "add":
            state.append(arguments["value"])
        respond(
            request,
            {"content": [{"type": "text", "text": json.dumps(state)}], "isError": False},
        )
    elif method == "ping":
        respond(request, {})
    else:
        send(
            {
                "jsonrpc": "2.0",
                "id": request["id"],
                "error": {"code": -32601, "message": f"unsupported method: {method}"},
            }
        )
