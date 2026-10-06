import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys


class Session:
    def __init__(self, process):
        self.process = process
        self.sequence = 0

    async def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.process.stdin.write(
            (json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n").encode()
        )
        await self.process.stdin.drain()
        while True:
            line = await asyncio.wait_for(self.process.stdout.readline(), timeout=45)
            if not line:
                raise RuntimeError(f"MCP process exited during {method}")
            message = json.loads(line)
            if message.get("id") == request_id:
                return message

    async def initialize(self):
        response = await self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "heap-diagnostics-check", "version": "1"},
        })
        assert "result" in response, response
        self.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        await self.process.stdin.drain()

    async def call(self, name, arguments):
        return await self.request("tools/call", {"name": name, "arguments": arguments})

    async def close(self):
        self.process.stdin.close()
        try:
            await asyncio.wait_for(self.process.wait(), timeout=5)
        except TimeoutError:
            self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), timeout=5)
            except TimeoutError:
                self.process.kill()
                await self.process.wait()


def succeeded(response):
    assert "result" in response and not response["result"].get("isError"), response
    return response["result"]


def rejected(response):
    assert "error" in response or response.get("result", {}).get("isError"), response


async def main():
    os.umask(0o077)
    executable, node, fixture = sys.argv[1:4]
    deadline_only = sys.argv[4:] == ["--deadline-only"]
    subprocess.run([node, "--expose-gc", fixture], check=True)
    sessions = []
    try:
        for _ in range(2):
            process = await asyncio.create_subprocess_exec(
                executable, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, limit=1024 * 1024
            )
            session = Session(process)
            sessions.append(session)
            await session.initialize()
        first, second = sessions
        listed = succeeded(await first.request("tools/list", {}))
        names = {tool["name"] for tool in listed["tools"]}
        forbidden = {"memlab_eval", "memlab_for_each", "memlab_eval_across", "memlab_batch"}
        assert not (forbidden & names), f"host-code or indirect dispatch exposed: {forbidden & names}"
        for tool in forbidden:
            rejected(await first.call(tool, {"code": "1", "steps": [{"tool": "memlab_eval", "args": {"code": "1"}}]}))
        snapshot = str(Path("grown.heapsnapshot").resolve())
        if not deadline_only:
            rejected(await first.call("memlab_diff_snapshots", {
                "before_path": str(Path("baseline.heapsnapshot").resolve()),
                "after_path": snapshot, "set_active": False,
            }))
            rejected(await first.call("memlab_load_snapshot", {
                "file_path": snapshot, "force": True,
            }))
        succeeded(await first.call("memlab_snapshot_header", {"file_path": snapshot}))
        succeeded(await first.call("memlab_load_snapshot", {
            "file_path": snapshot, "alias": "grown", "quiet": True, "suppress_suggestions": True,
        }))
        query = {"class_name": "RetainedHeapRecord", "node_type": "object", "output_mode": "count"}
        grown = succeeded(await first.call("memlab_find_nodes_by_class", query))
        print("LOADED_CLASS_RESULT=" + json.dumps(grown))
        if deadline_only:
            started = asyncio.get_running_loop().time()
            try:
                await asyncio.wait_for(first.call("memlab_search_nodes", {
                    "name_pattern": "^(a+)+$", "type": "string",
                    "output_mode": "count", "timeout_ms": 1000,
                }), timeout=6)
                raise AssertionError("synchronous pathological regex unexpectedly completed")
            except RuntimeError:
                assert asyncio.get_running_loop().time() - started < 6
            succeeded(await second.call("memlab_server_status", {}))
            print("PASS: synchronous regex is terminated; independent session survives")
            return
        rejected(await second.call("memlab_find_nodes_by_class", query))
        succeeded(await first.call("memlab_snapshots", {"action": "unload", "handle": "grown"}))
        rejected(await first.call("memlab_find_nodes_by_class", query))
        baseline = str(Path("baseline.heapsnapshot").resolve())
        released = str(Path("released.heapsnapshot").resolve())
        for alias, file_path in [("baseline", baseline), ("grown", snapshot), ("released", released)]:
            succeeded(await first.call("memlab_load_snapshot", {
                "file_path": file_path, "alias": alias, "keep_previous": True,
                "quiet": True, "suppress_suggestions": True,
            }))
        comparison = succeeded(await first.call("memlab_diff_snapshots", {
            "before_path": baseline, "after_path": snapshot, "set_active": False,
        }))
        print("RESIDENT_COMPARISON_RESULT=" + json.dumps(comparison))
        sequence = succeeded(await first.call("memlab_sequence_analysis", {
            "paths": [baseline, snapshot, released],
        }))
        print("RESIDENT_SEQUENCE_RESULT=" + json.dumps(sequence))
        print("PASS: host-code tools denied; real snapshot parsed; sessions isolated; unload releases active graph")
    finally:
        for session in reversed(sessions):
            await session.close()


asyncio.run(main())
