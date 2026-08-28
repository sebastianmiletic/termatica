# Termatica 1.14.5

Termatica 1.14.5 makes Command-T and Command-Shift-T focused-tab split
shortcuts instead of ordinary-tab creation shortcuts.

## Focused-tab splits

- Command-T splits the focused tab vertically into side-by-side panes.
- Command-Shift-T splits the focused tab horizontally into stacked panes.
- Each new pane anchors to the currently focused pane, so other tab groups stay
  hidden, keep their existing layout, and are not split or resized.
- Command-D and Command-Shift-D remain equivalent horizontal and vertical split
  shortcuts for users who prefer the existing bindings.

## Verification

The terminal regression gate creates two independent ordinary tabs, focuses the
first and invokes the Command-T route, then focuses the second and invokes the
Command-Shift-T route. It verifies the correct anchor and orientation, exactly
two visible panes, hidden inactive groups, matching dimensions, and zero frame
overlap. The complete release gate also retains AppKit/Metal parity, Codex and
Claude redraw coverage, mouse input, dense Hyprland reflow, updater replacement,
both architectures, and strict release signatures.
