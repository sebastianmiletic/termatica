# Termatica 1.10.0

Termatica 1.10.0 completes Metal Phase 8 pane-isolated recovery. AppKit remains
the default renderer; Metal remains an option in config.

- `t rt` explicitly retries only quarantined Metal panes in the running app.
- Retry does not change the active config, restart PTYs, or clear terminal
  content, scrollback, tabs, or splits.
- A failed retry stays safely quarantined on AppKit; it does not enter an
  automatic retry loop.
- Healthy panes are not reconfigured while another pane retries.
- `t rr` schema 3 adds aggregate renderer-health and per-pane retry counters.
- The Phase 8 native gate proves failed retry isolation, subsequent recovery
  where Metal is available, preserved Unicode content, and report accounting.

The release also retains the Phase 7 behavior: initialization or runtime Metal
failure automatically falls back to AppKit and lifecycle events do not retry a
quarantined renderer.

Local release gates passed `make check`, real-PTY compatibility, ASan, UBSan,
zero-diagnostic static analysis, a five-minute Metal Unicode/image soak, and
universal package/signature/checksum/DMG verification. The fresh comparative
benchmark and its power/load limitations are documented in `docs/BENCHMARKS.md`.
