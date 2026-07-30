# Termatica 1.2.7

## Benchmark rework

`termatica bench` (`t b`) is now a real in-process benchmark:

- Runs as a **background utility process** — no Dock icon, no bouncing, and no
  second app copy is spawned. It uses the running Termatica binary itself.
- Runs **one workload at a time**: each case does a Parser pass, then a Render
  pass, then a Scrollback pass, printing progress as it goes.
- Each pass does **1 warmup run then 5 measured runs** and records the **median**.
- After all workloads, prints the results table comparing your measured Termatica
  numbers against the published six-terminal reference (Kitty, Ghostty,
  Alacritty, WezTerm, Rio).
- No longer reopens a new app copy at the end; it just returns you to your
  terminal after showing the results.

## Scope

- Bundle under 1 MiB (1013.2 KiB). No theme or layout changes.