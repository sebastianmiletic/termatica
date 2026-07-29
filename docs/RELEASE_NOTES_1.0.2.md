# Termatica 1.0.2

## Performance

- Separates PTY transport locking from screen-model locking so reads continue
  while parser batches mutate the terminal grid.
- Drains queued PTY slabs continuously and increases Unicode scalar batching.
- Adds direct CJK, emoji-width, grapheme-pair, and alternate-screen ring-scroll
  fast paths.
- Leads Kitty 0.48.1 and Ghostty 1.3.1 in all six ten-repetition official
  `kitten __benchmark__` parser/render cases on the measured Apple M4 system.
- Retains zero overshoots across 240 warmed AppKit viewport paints at 60 Hz,
  120 Hz, and 240 Hz.

## Reliability

- Prevents alternate-screen output from entering persistent scrollback.
- Implements REP as terminal output instead of incorrectly writing repeated
  characters back to the child PTY.
- Corrects CSI 2026 and BSU/ESU synchronized-update state transitions.
- Keeps underline styles aligned through ring scrolling, insert/delete/erase
  operations, and alternate-screen restoration.
- Adds rasterized ASCII, Unicode, emoji, combining-text, true-color, and
  underline validation to `make check`.

## Phase 10

- Preserves the immutable `TRenderSnapshot` and `TRenderBackend` boundary.
- Keeps the AppKit renderer complete and verified as the Metal fallback.
