# SSH manager

Termatica includes a terminal-native manager around the system OpenSSH client.
Run `t ssh` to browse saved Termatica profiles and concrete aliases discovered
in `~/.ssh/config` or `~/.ssh/config.d/`. Use the arrow keys or J/K to move,
Enter to connect, N to create a profile, E to edit it, D to delete it, C to
open the OpenSSH config, and Q to return.

Termatica does not replace OpenSSH, invent a private transport, or store
passwords. It constructs argument arrays for `/usr/bin/ssh`, so OpenSSH keeps
ownership of host-key verification, authentication, agents, passphrases,
certificates, ControlMaster sessions, and configuration precedence.

## Saved profiles

Profiles live in `~/.config/termatica/ssh-hosts.json` with permission `0600`.
They can contain a host, user, port, identity file, ProxyJump target, multiple
local/remote/dynamic forwards, and validated `-o KEY=VALUE` options.

```sh
t ssh add production prod.example.com \
  --user deploy \
  --port 2222 \
  --identity ~/.ssh/id_ed25519 \
  --jump bastion.example.com \
  -L 8080:localhost:80 \
  -o ServerAliveInterval=30

t ssh list
t ssh show production
t ssh set production prod.example.com --user deploy --port 22
t ssh rename production prod
t ssh remove prod
```

`add` refuses to overwrite an existing name. `set` intentionally creates or
replaces one. Names, addresses, ports, forwarding specifications, jump hosts,
and option keys are validated before the file is written. JSON output is
available through `t ssh list --json`.

## Connect and diagnose

```sh
t ssh connect production
t ssh connect production -- uptime
t ssh command production -- uptime
t ssh check production
```

`connect` replaces the CLI process with the system `ssh` executable. Arguments
after `--` become the remote command. `command` prints the fully shell-quoted
command without connecting. `check` performs a five-second, non-interactive
OpenSSH attempt with `BatchMode=yes`; a failed login remains a failed check.

An unmanaged OpenSSH alias or direct hostname can be passed anywhere a saved
profile name is accepted. This lets Termatica coexist with an existing
`~/.ssh/config` instead of forcing an import or migration.

## SSH across splits and tiles

The running Termatica app must be available for these commands:

```sh
t ssh split production
t ssh split staging vertical
t ssh tile production staging database
t ssh tile --vertical production staging
```

`split` creates one horizontal or vertical split and starts the selected SSH
profile in it. `tile` starts the first host in the active pane, creates another
split for every remaining host, and starts each connection independently. With
Hyprland layout enabled, independent SSH root tabs use the balanced outer grid
while split sessions retain quarter, half, mixed, drag-to-reorder, and animated
tile geometry inside their root slot. Each pane is a separate PTY, so
one remote session cannot consume another pane's keyboard, mouse, scrollback,
cursor, process, or renderer state.

## Keys and OpenSSH files

```sh
t ssh keys
t ssh keygen work ed25519
t ssh config
t ssh known-hosts
```

`keys` lists private identity paths under `~/.ssh` and prints the public-key
fingerprint when a matching `.pub` file exists. `keygen` delegates interactive
passphrase handling to `/usr/bin/ssh-keygen`; Termatica never receives or saves
the passphrase. `config` and `known-hosts` open the standard OpenSSH files.

## Security boundary

- Passwords and passphrases are never written to the profile store.
- The profile store is user-only (`0600`) and its directory is user-owned.
- Connections use the macOS OpenSSH client and its normal host-key policy.
- Identity paths are expanded only when constructing the OpenSSH arguments.
- Split/tile commands shell-quote every generated argument before inserting it
  into a terminal.
- A local client/version test does not prove an external server, account, key,
  firewall, VPN, or bastion is reachable. Use `t ssh check NAME` for a real
  attempt and inspect its exit status.
