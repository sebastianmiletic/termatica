# App-control reliability campaign

The benchmark harness includes a deterministic, isolated app-control campaign:

```sh
TERMATICA_CONFIG_DIR="$(mktemp -d)" \
  build/TermaticaBenchmark --app-control-campaign 500 0x5445524d
```

The campaign drives real Termatica window controllers and PTYs through hundreds
of seeded actions: open and close windows, tabs, and panes; change focus; resize
windows; switch AppKit/Metal, fonts, and padding; send Unicode and synchronized
output; and launch bounded Codex, tmux, SSH, Vim, and system-monitor commands
when those tools are installed.

After every action it validates automation topology, active-terminal ownership,
split-anchor acyclicity, visible render snapshots, and terminal-count bounds.
Each config mutation deliberately generates both the direct reload request and
the watcher-equivalent request, then proves that exactly one reload is applied.
The seed and action count are printed on success so any failure is reproducible.

`make check` runs a 300-action campaign on local macOS builds. Longer campaigns
can raise the action count up to 2,000 and repeat with different seeds. Always
use an isolated `TERMATICA_CONFIG_DIR`; the harness creates real child processes
and intentionally changes its selected config.
