import os
import json
import asyncio

import httpx
import mcp.types as mcp_types
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server

crawl4aiBase = os.environ["CRAWL4AI_URL"]

server = Server("crawl4ai")
toolCache = []


async def loadTools():
    if not toolCache:
        async with httpx.AsyncClient(timeout=10) as client:
            res = await client.get(f"{crawl4aiBase}/mcp/schema")
            res.raise_for_status()
            toolCache.extend(res.json().get("tools", []))
    return toolCache


@server.list_tools()
async def listTools():
    return [
        mcp_types.Tool(
            name=tool["name"],
            description=tool.get("description") or "",
            inputSchema=tool.get("inputSchema") or {"type": "object"},
        )
        for tool in await loadTools()
    ]


# crawl4ai の tool 名は REST path と 1:1 対応
@server.call_tool()
async def callTool(name, arguments):
    async with httpx.AsyncClient(timeout=None) as client:
        res = await client.post(f"{crawl4aiBase}/{name}", json=arguments or {})
        res.raise_for_status()
        return [mcp_types.TextContent(type="text", text=json.dumps(res.json(), default=str))]


async def main():
    async with stdio_server() as (readStream, writeStream):
        await server.run(readStream, writeStream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
