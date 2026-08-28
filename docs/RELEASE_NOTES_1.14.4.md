# Termatica 1.14.4

Termatica 1.14.4 fixes tab creation and adds another renderer hardening pass for
rapidly redrawn AI coding interfaces.

## Predictable tabs

- Command-T and Command-Shift-T now create an ordinary tab immediately below
  the selected tab.
- The numbered rail reads from top to bottom, and insertion animates the actual
  new tab instead of the last tab in the collection.
- Command-D and Command-Shift-D remain the dedicated horizontal and vertical
  split shortcuts.
- The same insertion order is used in Hyprland mode, whose balanced layout
  recalculates every PTY grid after tabs open or close.

## Clean redraws and stable permissions

- Wide-cell pairs are repaired before immutable snapshots, including emoji and
  joined-grapheme width transitions that previously left stale neighboring text.
- AppKit and Metal clip every glyph to its allocated cell span, preventing font
  fallback, italic overhang, or atlas padding from covering Codex and TUI text.
- Release builds use one stable certificate-backed designated requirement so
  macOS can retain protected-folder choices after the one-time transition from
  older ad-hoc builds.

## Verification

The release gate covers top-to-bottom tab positioning, insertion immediately
after the selection, split-free Command-Shift-T behavior, Codex synchronized
redraws, emoji width upgrades, AppKit/Metal parity, dense Hyprland open/close
reflow, both architectures, updater replacement, and strict code signatures.
