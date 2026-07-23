# Termatica extension protocol v1

Termatica extensions are executable folders. The host has no language runtime requirement and communicates over stdin/stdout using one JSON object per line.

The plugins shipped in Termatica's own catalog are recognized by identifier and registered natively, avoiding a persistent helper process. Custom and downloaded extensions use the complete protocol below without reduced capabilities.

## Package layout

```text
my-extension/
├── extension.json
└── extension.py
```

`extension.json`:

```json
{
  "id": "com.example.my-extension",
  "name": "My Extension",
  "version": "1.0.0",
  "entry": "extension.py"
}
```

The entry file must be executable. It may be a compiled program or a script with a valid shebang. Termatica sets:

- `TERMATICA_EXTENSION_ID`
- `TERMATICA_PROTOCOL_VERSION=1`

## Lifecycle

Termatica starts each valid extension and writes:

```json
{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":1,"appVersion":"0.3.3"}}
```

An extension registers a terminal command by writing:

```json
{"jsonrpc":"2.0","method":"command.register","params":{"id":"ai.ask","title":"AI: ask about the terminal","slash":"/ai"}}
```

The `slash` field is optional. With it, `termatica run ai explain the error` invokes the command and passes `explain the error` as `query`.

When the user runs the command, Termatica writes:

```json
{
  "jsonrpc": "2.0",
  "method": "command.execute",
  "params": {
    "id": "ai.ask",
    "query": "explain the error",
    "cwd": "/current/directory",
    "selection": "selected terminal text",
    "screen": "currently visible terminal text"
  }
}
```

## Host methods

Extensions can currently emit these notifications:

### `command.register`

Adds a command that can be invoked with `termatica run <slash-or-id> [query]`. Parameters: `id`, `title`, and optional `slash`.

### `terminal.sendText`

Sends text through the active terminal PTY exactly as if the user pasted it.

```json
{"jsonrpc":"2.0","method":"terminal.sendText","params":{"text":"git status\n"}}
```

### `ui.notify`

Writes a diagnostic notification when `TERMATICA_VERBOSE=1` is set. This method is reserved for a native non-modal notification surface in a later protocol revision.

## Building an AI harness

An AI extension normally follows this sequence:

1. Register a slash command such as `/pi`.
2. Receive the query, current directory, selected text, and visible terminal state.
3. Start or contact the chosen AI agent outside Termatica.
4. Stream status within the extension or wait for a result.
5. Send a proposed command with `terminal.sendText`.

Keep destructive commands behind explicit user confirmation in your extension. Termatica does not grant extensions special privileges, but it also does not sandbox them.

## Security boundary

An installed extension is local executable code. It can access anything available to the logged-in user, independently of this protocol. Review the source, pin versions, and install only trusted extensions. Termatica never downloads or installs code automatically in protocol v1.
