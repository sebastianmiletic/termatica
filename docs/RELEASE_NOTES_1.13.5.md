# Termatica 1.13.5

Termatica 1.13.5 completes ordinary non-Hyprland pane behavior and hardens the
motion, hiding, overlap, and default-profile paths around it.

- Horizontal, vertical, and mixed splits work without enabling Hyprland.
- Every ordinary tab keeps its own independent split group; switching tabs no
  longer reveals or tiles unrelated terminals.
- Pane geometry uses translation-only motion and clip-only entry reveals, so
  live terminal glyphs are never scaled during resize or movement.
- Motion and its regression coverage respect the macOS Reduce Motion setting.
- The auto-hiding tab rail stays within the available window height and shows a
  stable active-tab window when every tab control cannot fit; scrolling over
  the rail reaches tabs outside that window.
- Complete new config profiles keep installed optional plugins off by default.
- Native regression coverage verifies mixed splits, tab isolation, hide/reveal
  state, constrained rail geometry, motion transforms, and Hyprland drag/swap.
