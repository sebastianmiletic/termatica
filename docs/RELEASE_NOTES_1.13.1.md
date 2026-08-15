# Termatica 1.13.1

Termatica 1.13.1 makes the live system monitor calm and efficient, and reduces
the everyday command surface to the tools users actually need.

## Smooth system monitoring

- `t sm` builds each sample as a buffered frame and compares it with the prior
  frame.
- Only rows whose content changed are repainted. The full alternate screen is
  cleared once on entry, not once per sample.
- CPU, memory, storage, network, device, battery, uptime, pause, refresh, and
  process sorting remain available without terminal flicker.

## Clearer commands

- Bare `t` and `termatica` show one concise list of full public commands.
- Quick aliases remain functional and are documented on GitHub, but are not
  repeated in the command output.
- `help` and `version` are commands; the top-level `--help` and `--version`
  flags are no longer accepted.
- Renderer report, qualification, campaign, and retry commands and aliases are
  removed from the public CLI and shell completions. The internal AppKit and
  optional Metal rendering engines remain intact.

The regression suite verifies the changed-row monitor implementation in a real
pseudo-terminal, the simplified command list, rejected legacy flags, removed
renderer commands and completions, SSH management, configuration isolation,
terminal input and rendering, packaging, signing, and updater safety.

The universal Apple Silicon and Intel app bundle is 1,476,306 bytes
(1,441.7 KiB), remaining comfortably below 2 MB.
