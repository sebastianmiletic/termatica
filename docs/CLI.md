# Termatica command line

Every shell opened by Termatica receives the app's `Contents/MacOS` directory at the front of `PATH`. No separate CLI installation is required.

## Quick commands

Use `t` instead of typing `termatica`. The common paths are deliberately short:

| Quick command | Full command |
|---|---|
| `t ssh` | Open the terminal-native SSH manager |
| `t ssh tile <names...>` | Start saved SSH profiles across split panes |
| `t b` | `termatica benchmark` |
| `t sm` | `termatica system-monitor` |
| `t c` | `termatica config` |
| `t cf` | `termatica config-file` |
| `t u [check]` | `termatica update [check]` |
| `t r` | `termatica reload` |
| `t e <name> [files]` | `termatica editor <name> [files]` |
| `t x <name> [text]` | `termatica run <name> [text]` |
| `t h` / `t v` | Help / version |

Running `t` or `termatica` by itself prints the clean public command list. It
does not repeat the quick aliases, flags, or internal renderer diagnostics.
The aliases remain available and are documented here for discoverability.

## Public commands

| Command | Result |
|---|---|
| `termatica ssh` | Open the interactive manager for saved and OpenSSH-config hosts |
| `termatica ssh list [--json]` | List saved profiles as a table or JSON |
| `termatica ssh add\|set <name> <host> [options]` | Create or replace a validated password-free profile |
| `termatica ssh connect <name> [-- command]` | Connect with the system OpenSSH client |
| `termatica ssh check <name>` | Make a five-second non-interactive connection attempt |
| `termatica ssh split <name> [vertical]` | Open a profile in a new split |
| `termatica ssh tile [--vertical] <names...>` | Start multiple profiles across independent panes |
| `termatica ssh keys\|keygen` | Inspect fingerprints or create an OpenSSH identity |
| `termatica config` | Open the categorized terminal config UI |
| `termatica config list` | Print the current config and every other saved config |
| `termatica config get <path>` | Print a dot-separated setting |
| `termatica config set <path> <value>` | Set a JSON value or string and reload |
| `termatica config create <name>` | Create a benchmark-tuned default config and make it current |
| `termatica config use <name>` | Activate a named config |
| `termatica config rename <old> <new>` | Rename a saved config |
| `termatica config delete <name>` | Delete a saved config |
| `termatica config-file` | Create and open the selected config's authoritative JSON file |
| `termatica config-file path` | Print the authoritative config path |
| `termatica system-monitor` | Open a responsive live monitor for CPU, memory, storage, network, device, and top-process statistics |
| `termatica update` | Download, verify, and install the latest GitHub release |
| `termatica update check` | Check GitHub without installing |
| `termatica reload` | Reload configuration in the running app |
| `termatica benchmark` | Benchmark an isolated offscreen terminal inside the running app using the active visual config |
| `termatica editor <name> [file ...]` | Run a supported editor in the current terminal |
| `termatica editor list` | List editor adapters |
| `termatica run <name> [text]` | Invoke a configured extension command |
| `termatica completions <zsh\|bash\|fish>` | Print a shell completion definition |
| `termatica completions install` | Write and activate all completion definitions |
| `termatica completions path` | Print the completion directory |
| `termatica help` | Show the built-in guide |
| `termatica version` | Print the app version |

The separate `plugins`, `themes`, `configs`, `code`, `marketplace`, profile, and directory menus have been removed. Use `termatica config` for all settings and named configs. Use `termatica config-file` for direct JSON access.

## System monitor

`t sm` opens a live, alternate-screen view without changing the current shell
or terminal history. Each sample is buffered and compared with the previous
frame, then only changed rows are repainted. It reports device and power state,
uptime, CPU and load, memory pressure, root-volume usage, network rates and
totals, and the busiest processes. Press `C` or `M` to order processes by CPU
or memory, `P` to pause, `R` to refresh, and `Q` to return to the shell.
`termatica system-monitor --once` prints one non-interactive snapshot for
scripts and diagnostics.

## SSH manager

`t ssh` manages validated, password-free profiles while continuing to honor the
system OpenSSH configuration and security model. Profiles support users, ports,
identity files, ProxyJump, local/remote/dynamic forwarding, and custom OpenSSH
options. They can be inspected without connecting, checked against the real
network, opened normally, or launched directly into independent split panes.
See the [complete SSH guide](SSH.md) for every command and security boundary.

## Config UI

The first screen is always Config Files. It lists every actual `.json` filename exactly once and marks it CURRENT, SAVED, or INVALID. Enter opens the current file or selects another valid file and opens it. New, Rename, and Delete operate on the actual filenames; `.json` is optional when entering a name.

The next screen contains Appearance, Performance, Tabs & Tiling, Window, Terminal & Input, Motion, Extensions, Updates, and Keybindings. Renderer selection between AppKit and Metal is under Performance; blur, transparency, colours, and fonts are under Appearance.

| Key | Action |
|---|---|
| Up / Down or J / K | Move |
| Left / Right or H / L | Change a switch, option, or number |
| Enter | Open settings for the current/selected config, open a section, or edit a value |
| N | Create and open a new config |
| R | Rename the selected config |
| D | Delete the selected config after confirmation |
| Escape or Q | Return to Config Files, or quit from Config Files |

Changes are saved and sent to the running app immediately. Config names may contain letters, numbers, dots, dashes, and underscores.

Configs are independent, complete files under `~/.config/termatica/configs/`, and their filenames are their identities. `~/.config/termatica/current` selects one filename; `config.json` is a compatibility symlink to that file. Switching never shallow-merges one config into another. Older partial configs are normalized to schema version 2 on first use without discarding their explicit values.

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

`termatica completions install` writes Zsh, Bash, and Fish definitions below `~/.config/termatica/completions`. They cover both `termatica` and `t`, including the complete public command set, quick aliases, config actions, updater actions, and editor names.

Set `TERMATICA_CONFIG_DIR=/some/folder` to redirect configuration and completion files for portable setups or automation.

## Benchmarks

`termatica benchmark` (or `t b`) sends a request to the already-running app.
It reports the running version/build, active config, configured renderer, font,
display refresh, process memory, ASCII/Unicode/CSI parser-model throughput, and
warmed offscreen AppKit text/image paint FPS. It creates no PTY and does not
close or replace a terminal, tab, process, scrollback buffer, or window. The
paint FPS excludes Metal submission, WindowServer, vsync, and physical display
latency.

`make benchmark-decoder` measures the incremental C decoder without PTY, screen-model, or presentation overhead. `make benchmark-core` measures the decoder and screen model together. `make benchmark-experience` measures offscreen scroll-paint duration, parse-to-paint duration, sustained-output stability, and process CPU time. These internal benchmarks run through the native-architecture `build/TermaticaBenchmark` harness, which is not included in the app bundle.

`make benchmark` runs the full local comparison against installed Kitty and Ghostty builds and writes raw results below `/tmp/termatica-benchmark-results`.

Use `KITTY_APP`, `GHOSTTY_APP`, `BENCHMARK_REPETITIONS`, and `BENCHMARK_OUTPUT` to select apps and control the run. Methodology and current measurements are in [Terminal benchmarks](BENCHMARKS.md).
