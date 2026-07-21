#!/usr/bin/env python3
"""Terminal-only editor controls for the Termatica extension protocol."""

import json
import shlex
import sys


EDITORS = {
    "vim": "Vim",
    "nvim": "Neovim",
    "emacs": "Emacs terminal",
    "nano": "Nano",
    "micro": "Micro",
    "hx": "Helix",
}


def send(method, params):
    print(json.dumps({"jsonrpc": "2.0", "method": method, "params": params}), flush=True)


for line in sys.stdin:
    try:
        message = json.loads(line)
        method = message.get("method")

        if method == "initialize":
            for key, title in EDITORS.items():
                send("command.register", {
                    "id": f"editor.{key}",
                    "title": f"Editor: {title} (terminal)",
                    "slash": f"/{key}",
                })
        elif method == "command.execute":
            params = message.get("params", {})
            editor = params.get("id", "").split(".")[-1]
            if editor in EDITORS:
                query = params.get("query", "")
                command = f"termatica editor {shlex.quote(editor)}"
                if query:
                    command += f" {shlex.quote(query)}"
                send("terminal.sendText", {"text": command + "\n"})
    except Exception as error:
        send("ui.notify", {"message": f"editor controls: {error}"})
