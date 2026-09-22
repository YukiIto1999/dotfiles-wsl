import argparse
import asyncio
import json
import os
import sys

from hooks import run_hook
from memory import Client, MemoryFailure, canonical, project_bank
from server import dispatch, run_server


def input_object() -> dict:
    try:
        value = json.load(sys.stdin)
    except ValueError:
        raise MemoryFailure("invalid_input", "stdin must contain one JSON object") from None
    if not isinstance(value, dict):
        raise MemoryFailure("invalid_input", "stdin must contain one JSON object")
    return value


async def main() -> None:
    parser = argparse.ArgumentParser(prog="dotfiles-memory")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("mcp")
    commands.add_parser("health")
    for name in ("recall", "save", "verify", "status"):
        commands.add_parser(name, help="Read arguments as one JSON object from stdin")
    project = commands.add_parser("project")
    project.add_argument("cwd")
    hook = commands.add_parser("hook")
    hook.add_argument("--harness", choices=["claude", "codex", "omp", "opencode"], required=True)
    hook.add_argument("event", choices=["session-start", "prompt-submit", "pre-compact", "stop", "session-end"])
    migration = commands.add_parser("migrate", help="Import an immutable legacy export into isolated history")
    migration.add_argument("--source", required=True)
    migration.add_argument("--sha256", required=True)
    migration.add_argument("--verify-only", action="store_true")
    arguments = parser.parse_args()
    if arguments.command == "project":
        print(canonical({"bank_id": project_bank(arguments.cwd)}))
        return
    url = os.environ["PROJECT_MEMORY_URL"]
    if arguments.command == "mcp":
        await run_server(url)
        return
    async with Client(url) as client:
        if arguments.command == "hook":
            output = await run_hook(client, arguments.harness, arguments.event, input_object())
            if output:
                print(output)
            return
        if arguments.command == "migrate":
            from migration import migrate
            result = await migrate(client, arguments.source, arguments.sha256, arguments.verify_only)
        else:
            result = await dispatch(client, arguments.command, {} if arguments.command == "health" else input_object())
        print(canonical(result))


def report_failure(error: BaseException) -> None:
    if isinstance(error, BaseExceptionGroup):
        for child in error.exceptions:
            report_failure(child)
    elif isinstance(error, MemoryFailure):
        print(f"project-memory: {error}", file=sys.stderr)
    elif isinstance(error, TimeoutError):
        print("project-memory: unavailable: deadline expired; result is not verified", file=sys.stderr)
    else:
        print(f"project-memory: internal error ({type(error).__name__}); result is not verified", file=sys.stderr)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (MemoryFailure, TimeoutError, ExceptionGroup) as error:
        report_failure(error)
        sys.exit(1)
