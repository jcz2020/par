"""A minimal MCP stdio server for the Python binding tests.

The OCaml test suite has its own mock server, but the Python CI job never runs
``dune build``, so that binary is not available there. This one speaks just
enough JSON-RPC for PAR's transport handshake and tool listing, and nothing
else: it exists to prove that a Python program can configure a server, spawn
it, and read its tool descriptors.

Run directly (``python mcp_mock_server.py``); it reads one JSON object per line
from stdin and writes one reply per line to stdout.
"""

import json
import sys

TOOLS = [
    {
        "name": "echo",
        "description": "Echoes the message back",
        "inputSchema": {
            "type": "object",
            "properties": {"message": {"type": "string"}},
        },
    },
    {
        "name": "add",
        "description": "Adds two integers",
        "inputSchema": {
            "type": "object",
            "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
        },
    },
]


def _reply(request_id, result):
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def _handle(request):
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        return _reply(request_id, {
            "protocolVersion": "2025-06-18",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "python-mock", "version": "0.1.0"},
        })
    if method == "tools/list":
        return _reply(request_id, {"tools": TOOLS})
    if method == "tools/call":
        params = request.get("params") or {}
        if params.get("name") == "echo":
            message = (params.get("arguments") or {}).get("message", "")
            return _reply(request_id, {
                "content": [{"type": "text", "text": message}],
                "isError": False,
            })
        return _reply(request_id, {
            "content": [{"type": "text", "text": "unknown tool"}],
            "isError": True,
        })
    if method is None:
        return None  # a notification, e.g. notifications/initialized
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": -32601, "message": f"Method not found: {method}"},
    }


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = _handle(request)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
