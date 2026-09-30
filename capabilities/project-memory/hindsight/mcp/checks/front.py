import asyncio
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main():
    parameters = StdioServerParameters(command=sys.argv[1])
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()
            unavailable = await session.call_tool("memory_health", {})
            assert unavailable.isError, "backend absence was reported healthy"
            error = "\n".join(part.text for part in unavailable.content if part.type == "text")
            assert "unavailable" in error, error
            marker = "synthetic-sensitive-marker"
            invalid = await session.call_tool("memory_recall", {"cwd": "/tmp", "query": marker, "scope": marker})
            assert invalid.isError, "invalid scope was accepted"
            assert all(marker not in part.text for part in invalid.content if part.type == "text"), "schema error echoed input"
    print("MCP: backend failure and safe validation verified")


asyncio.run(main())
