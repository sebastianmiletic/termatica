# Termatica command line

Every shell opened by Termatica receives the app's `Contents/MacOS` directory at the front of `PATH`. No separate CLI installation is required.

## Public commands

| Command | Result |
|---|---|
| `termatica config` | Open the categorized terminal config UI |
| `termatica config list` | Print the active config and every saved config |
| `termatica config get <path>` | Print a dot-separated setting |
| `termatica config set <path> <value>` | Set a JSON value or string and reload |
| `termatica config create <name>` | Save current settings as a named config and activate it |
| `termatica config use <name>` | Activate a named config |
| `termatica config rename <old> <new>` | Rename a saved config |
| `termatica config delete <name>` | Delete a saved config |
| `termatica config-file` | Create and open the authoritative `config.json` |
| `termatica config-file path` | Print the authoritative config path |
| `termatica update` | Download, verify, and install the latest GitHub release |
| `termatica update check` | Check GitHub without installing |
| `termatica reload` | Reload configuration in the running app |
| `termatica editor <name> [file ...]` | Run a supported editor in the current terminal |
| `termatica editor list` | List editor adapters |
| `termatica run <name> [text]` | Invoke a configured extension command |
| `termatica completions <zsh\|bash\|fish>` | Print a shell completion definition |
| `termatica completions install` | Write and activate all completion definitions |
| `termatica completions path` | Print the completion directory |
| `termatica help` | Show the built-in guide |
| `termatica version` | Print the app version |

The separate `plugins`, `themes`, `configs`, `code`, `marketplace`, profile, and directory menus have been removed. Use `termatica config` for all settings and named configs. Use `termatica config-file` for direct JSON access.

## Config UI

The root screen contains Config Files, Themes, Text & Colour, Appearance, Tabs & Motion, Plugins, System & Updates, and Keybindings.

| Key | Action |
|---|---|
| Up / Down or J / K | Move |
| Left / Right or H / L | Change a switch, option, or number |
| Enter | Open a section, toggle an option, or edit a value |
| N | Create a config in Config Files |
| R | Rename the selected config |
| D | Delete the selected config after confirmation |
| Q | Return or close |

Changes are saved and sent to the running app immediately. Config names may contain letters, numbers, dots, dashes, and underscores.

## Scriptable config

```sh
termatica config get fontSize
termatica config set fontSize 13
termatica config set appearance.backgroundOpacity 0.42
termatica config set colors.cursor '"#FFFFFF"'
termatica config set plugins.hyprland-layout true
termatica config set tabs.tileGap 12
termatica config set shellArguments '["-l"]'
```

Unquoted JSON numbers, booleans, arrays, objects, and quoted strings are parsed as JSON. Other input is stored as a string.

## Updates

`termatica update check` returns `0` when current, `10` when an update exists, and `1` for a network or metadata failure.

`termatica update` uses `updates.repository`, normally `sebastianmiletic/termatica`. It only accepts the expected universal ZIP with a GitHub SHA-256 digest, then verifies the extracted app's identifier, version, and code signature before staged replacement. A failed replacement restores the prior app.

Restart Termatica after a successful update.

## Editor adapter

Supported names are `vim`, `nvim`, `emacs`, `nano`, `micro`, and `hx`. `vi` aliases Vim and `helix` aliases `hx`. Emacs always launches with `-nw`.

```sh
termatica editor nvim README.md
termatica editor emacs src/main.m
termatica editor hx docs/CONFIGURATION.md
```

If an executable is unavailable, Termatica exits with status 127 and reports it.

## Completions

`termatica completions install` writes Zsh, Bash, and Fish definitions below `~/.config/termatica/completions`. They cover the complete public command set, config actions, updater actions, and editor names.

Set `TERMATICA_CONFIG_DIR=/some/folder` to redirect configuration and completion files for portable setups or automation.
