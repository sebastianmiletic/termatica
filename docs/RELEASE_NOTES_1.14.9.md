# Termatica 1.14.9

Termatica 1.14.9 makes tiled-window dragging position based.

## Tiles move; their identity does not

- Dragging one of two half-screen tiles moves that same tile to the opposite
  side. Its terminal session, visible content, dimensions, and split identity
  stay attached to it.
- The other tile settles into the vacated position instead of having its model
  identity exchanged with the dragged terminal.
- Directly split panes can reverse their left/right or top/bottom positions
  without rewriting their split relationship.
- In Hyprland layouts, nested groups move as complete spatial units. A half
  beside two quarters can change sides while the half remains a half and both
  quarters remain quarters.
- Tab order and terminal contents are not modified by tile movement.

## Verification

The release regression uses real drag callbacks for two Hyprland halves and a
mixed half-plus-quarters layout. It verifies exact terminal identity order,
content ownership, split anchors, dimensions, destination positions, focus,
translation-only animation, and hit testing. Ordinary split panes also move in
both directions while retaining their original topology and exact frames. The
complete release gate retains renderer, mouse, keyboard, external-monitor,
real-PTY automation, updater, universal architecture, and signing checks.
