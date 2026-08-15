# Termatica 1.13.0

Termatica 1.13.0 turns the sub-2 MB native terminal into a stronger remote-work
environment with a complete terminal-native SSH manager, live system monitoring,
and broader AI CLI and TUI compatibility.

## SSH management

- Open the interactive manager with `t ssh`.
- Save password-free profiles with user-only `0600` permissions.
- Discover concrete aliases from `~/.ssh/config` and `~/.ssh/config.d`.
- Add, edit, rename, inspect, remove, list, or export profiles as JSON.
- Use identities, custom ports, ProxyJump, OpenSSH options, and local, remote,
  or dynamic forwarding.
- Check connections with batch mode and a bounded timeout.
- Launch a saved host in a new split, or tile several independent SSH sessions
  with one command.
- Inspect identity fingerprints and create Ed25519, ECDSA, or RSA keys through
  the system OpenSSH tools.

Termatica never stores SSH passwords or private-key passphrases. Direct
connections execute `/usr/bin/ssh` with an argument array, while generated
split and tile commands shell-quote every argument.

## Monitoring and terminal compatibility

- Open the live system monitor with `t sm` for CPU, load, memory pressure,
  storage, network rates, device details, uptime, battery, and processes.
- Complete Kitty keyboard progressive-enhancement handling for AI CLIs and
  terminal interfaces, including bounded mode stacks, repeat/release events,
  associated text, shifted keys, and modifier-key events.
- Expand the real-PTY compatibility gate across installed Codex, Claude,
  Gemini, OpenCode, Pi, Nano, btop, and Yazi programs.

## Interface and footprint

- Keep ordinary tab surfaces immediate and stable, with restrained motion only
  on the compact tab control.
- Preserve independent animated geometry for split and Hyprland tile layouts.
- Ship as a signed universal Apple Silicon and Intel application. The verified
  local bundle for this release is 1,508,721 bytes (1,473.4 KiB).

The release regression suite covers the interactive SSH manager, secure profile
storage, generated OpenSSH commands, the system monitor, terminal input and
rendering, configuration isolation, packaging, signing, and updater safety.
