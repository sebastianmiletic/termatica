# Termatica command line

Every shell opened by Termatica receives the app's `Contents/MacOS` directory at the front of `PATH`. The `termatica` command is therefore available without a separate installation.

## Commands

| Command | Result |
|---|---|
| `termatica plugins` | Browse and install plugins in an ANSI terminal interface |
| `termatica themes` | Browse and install themes in an ANSI terminal interface |
| `termatica marketplace` | Browse all plugins, themes, and profiles |
| `termatica install <id>` | Install a known module directly |
| `termatica editor <name> [file ...]` | Run a supported editor in the current terminal |
| `termatica editor list` | List supported editor adapters |
| `termatica reload` | Reload configuration and extensions in the running app |
| `termatica config` | Create and open `config.json` |
| `termatica config-path` | Print the active configuration path |
| `termatica config-dir` | Open the Termatica data directory |
| `termatica plugins-dir` | Open installed extensions |
| `termatica themes-dir` | Open installed themes |
| `termatica catalog` | Create and open the user marketplace catalog |
| `termatica skeleterm` | Apply the lowest-resource profile |

Legacy flag spellings such as `termatica --plugins` remain supported.

## Editor adapter

Supported names are `vim`, `nvim`, `emacs`, `nano`, `micro`, and `hx`. `vi` aliases Vim and `helix` aliases `hx`. Emacs always launches with `-nw`, so it remains inside the terminal.

Arguments are passed directly to the selected editor:

```sh
termatica editor nvim README.md
termatica editor emacs src/main.m
termatica editor hx docs/EXTENSIONS.md
```

If the selected executable is unavailable, Termatica exits with status 127 and prints a clear message.
