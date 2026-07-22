# Termatica command line

Every shell opened by Termatica receives the app's `Contents/MacOS` directory at the front of `PATH`. The `termatica` command is therefore available without a separate installation.

## Commands

| Command | Result |
|---|---|
| `termatica plugins` | Browse, download, enable, and disable plugins in an ANSI terminal interface |
| `termatica themes` | Browse and activate themes in an ANSI terminal interface |
| `termatica configs` | Browse, activate, save, rename, and delete named JSON configurations |
| `termatica configs list` | Print the active config and every saved config |
| `termatica configs path` | Print the named-config directory |
| `termatica configs save <name>` | Save the active settings as a named config and keep it active |
| `termatica configs use <name>` | Replace the active settings with a saved config |
| `termatica configs rename <old> <new>` | Rename a saved config |
| `termatica configs delete <name>` | Delete a saved config |
| `termatica install <id>` | Install a known module directly |
| `termatica run <name> [query]` | Invoke a command registered by an installed extension |
| `termatica editor <name> [file ...]` | Run a supported editor in the current terminal |
| `termatica editor list` | List supported editor adapters |
| `termatica reload` | Reload configuration and extensions in the running app |
| `termatica config` | Create and open `config.json` |
| `termatica config-path` | Print the active configuration path |
| `termatica config-dir` | Open the Termatica data directory |
| `termatica plugins-dir` | Open installed extensions |
| `termatica themes-dir` | Open installed themes |
| `termatica skeleterm` | Apply the direct low-memory mode |

Legacy flag spellings such as `termatica --plugins` remain supported.

Interactive plugin and theme lists use Up/Down or J/K to move, Enter to install or toggle, and Q to exit. State is shown as `GET`, `ON`, or `OFF`. Changes reload immediately and the menu remains open for additional actions. The two lists never mix categories. When input is redirected, the browser accepts multiple row numbers or module ids and closes on `q` or end-of-file.

The configuration browser also remains open for multiple actions. Use Up/Down or J/K to move, Enter to activate, S to save, R to rename, D to delete with confirmation, and Q to exit. Names may contain letters, numbers, dots, dashes, and underscores. Files live in `~/.config/termatica/configs`, remain readable after installing or replacing the app, and are suitable for scripts or coding agents. Set `TERMATICA_CONFIG_DIR` when a portable or isolated configuration root is required.

## Editor adapter

Supported names are `vim`, `nvim`, `emacs`, `nano`, `micro`, and `hx`. `vi` aliases Vim and `helix` aliases `hx`. Emacs always launches with `-nw`, so it remains inside the terminal.

Arguments are passed directly to the selected editor:

```sh
termatica editor nvim README.md
termatica editor emacs src/main.m
termatica editor hx docs/EXTENSIONS.md
```

If the selected executable is unavailable, Termatica exits with status 127 and prints a clear message.
