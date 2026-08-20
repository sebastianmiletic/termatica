# Termatica 1.13.6

Termatica 1.13.6 fixes the intermittent overlapping-text path seen most often
during Codex CLI's synchronized, in-place redraws and makes config ordering
stable and immediately readable.

- Overwriting either half of a double-width Unicode cell now clears the whole
  old pair before placing new content.
- Erase, insert, and delete operations repair split wide-cell pairs instead of
  leaving a glyph and continuation cell in contradictory states.
- AppKit clips text and glow to the fixed row being painted, preventing stale
  fragments from surviving in adjacent rows after partial redraws.
- The default `fontFeatures: []` profile no longer has ligatures forced on;
  `liga` remains available and is honored when explicitly configured.
- The active config is always the first row in the interactive config screen
  and the first result from `termatica config list`; remaining files keep a
  deterministic case-insensitive order.
- The native release gate now reproduces synchronized Codex-style long-to-short
  redraws, wide-glyph continuation overwrites, AppKit row clipping, and
  active-first ordering in both config interfaces.

The release remains a universal macOS 13+ application with AppKit as the
benchmark-tuned default renderer and Metal available as an opt-in backend.
