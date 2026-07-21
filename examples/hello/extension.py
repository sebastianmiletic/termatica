#!/usr/bin/env python3
import json
import sys


def send(method, params):
    print(json.dumps({"jsonrpc": "2.0", "method": method, "params": params}), flush=True)


for line in sys.stdin:
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        continue

    if message.get("method") == "initialize":
        send("command.register", {
            "id": "hello.write",
            "title": "Hello: write into the shell",
            "slash": "/hello",
        })
    elif message.get("method") == "command.execute":
        query = message.get("params", {}).get("query") or "from an extension"
        safe = query.replace("'", "'\\''").replace("\n", " ")
        send("terminal.sendText", {
            "text": "printf '\\033[38;2;255;179;92mTermatica\\033[0m %s\\n' '" + safe + "'\n"
        })
