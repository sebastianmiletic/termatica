# Termatica 1.2.4

## In-terminal benchmark

- Added `termatica bench` (short form `t b`).
- The command shows a **warning** that it will close every open terminal session and restart the app, and asks for confirmation before continuing.
- It runs parser, render, and scrollback throughput workloads (ASCII, Unicode, and CSI-heavy) in-process, measuring only Termatica.
- After the benchmark completes, it prints a clean results table comparing your measured Termatica numbers against the published six-terminal reference table (Kitty, Ghostty, Alacritty, WezTerm, Rio) — your Termatica values replace the Termatica column, the competitor values stay as the published reference.
- Pressing Enter reopens the Termatica app automatically.

## Layout

- Reaffirmed the prompt anchoring to the top of the terminal window.

## Scope

- Bundle remains under 1 MiB (1011.3 KiB). No theme changes.