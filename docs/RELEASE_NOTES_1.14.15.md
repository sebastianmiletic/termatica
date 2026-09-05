# Termatica 1.14.15

Termatica 1.14.15 fixes the remaining Codex prompt cursor duplication and
highlight fragmentation, and adds direct compatibility proof for Herdr.

## Atomic Codex cursor

- The cursor is now composed inside the same immutable renderer snapshot as the
  prompt text and cell background.
- Cursor movement, blinking, focus changes, and Codex synchronized redraws can
  no longer expose an older independent cursor surface above the current prompt.
- A block cursor paints its cell and contrasting glyph together, keeping the
  text visually attached to its highlight.

## Seamless TUI highlights

- Metal batches adjacent selection, search, ANSI background, and inverse-video
  cells with the same color into one row quad.
- This removes fractional-pixel seams that could split a highlighted label into
  individual character cells.
- AppKit and Metal retain the application's ANSI and true-color choices while
  producing matching background and foreground semantics.

## Compatibility verification

The release gate now opens the actual interactive Codex prompt and isolated
Herdr 0.8.2 interfaces through real PTYs. Herdr is exercised on both AppKit and
Metal, alongside zsh, Vim, Neovim, tmux, less, man, top, htop, SSH, Claude,
Gemini, OpenCode, Pi, Nano, btop, and Yazi. Renderer parity also covers cursor
styles, Unicode, effects, tiled panes, history, images, and partial damage.
