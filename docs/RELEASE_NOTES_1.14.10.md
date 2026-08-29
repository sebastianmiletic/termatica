# Termatica 1.14.10

Termatica 1.14.10 restores the original Command-T tab behavior.

## Command-T creates a tab again

- Command-T creates and selects an independent terminal tab directly after the
  currently selected tab.
- In ordinary mode, the previous tab and all of its splits remain intact and
  hidden while the new tab occupies the terminal surface.
- In Hyprland mode, each Command-T press creates an independent root tile and
  the outer layout rebalances across all roots.
- Command-Shift-T still splits only the focused pane horizontally.
- Command-D and Command-Shift-D remain available for explicit horizontal and
  vertical splits.

## Historical source and verification

The shortcut routing matches v1.14.4 and earlier releases, where `newTab:`
called the independent-tab path. New regressions invoke the real application
actions and verify selected-relative insertion, root identity, split isolation,
ordinary visibility, Hyprland balancing, and the unchanged focused horizontal
Command-Shift-T behavior. The complete release gate retains tile movement,
rendering, mouse, keyboard, monitor, automation, updater, universal binary, and
signing checks.
