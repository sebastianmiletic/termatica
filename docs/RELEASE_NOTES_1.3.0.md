# Termatica 1.3.0

## Benchmark redesign

`termatica bench` (`t b`) now uses a **helper tool** workflow:

- **First run** asks to install a small helper called **termyx engine bench**
  (`~/Library/Application Support/Termatica/termyx-engine-bench`).
- When you run a benchmark, **Termatica closes** and the helper opens in a
  **separate macOS Terminal window**.
- The helper runs the **full Termatica benchmark suite** using your installed
  Termatica binary (`--termyx-bench`): 9 throughput workloads
  (parser, render, and scrollback × ASCII, Unicode, CSI-heavy), each with
  **1 warmup pass + 5 measured passes** and the **median** recorded.
- It prints a **results table** comparing your measured Termatica numbers
  against the published six-terminal reference (Kitty, Ghostty, Alacritty,
  WezTerm, Rio), plus the geometric mean.
- After completion it offers to **reopen Termatica**.
- No Dock bounce, no second app copy — the benchmark runs headless in-process
  using your real Termatica binary.

## Code cleanup

- Removed unused `TRunConfigBrowser` and `TDrawConfigBrowser`.

## Scope

- Bundle under 1.03 MiB (1029.3 KiB). No theme or layout changes.