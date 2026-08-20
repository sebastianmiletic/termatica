# Termatica 1.13.2

Termatica 1.13.2 completes native and application mouse handling and fixes
scrollback selection anchoring.

## Stable native selection

- Selections are stored against document rows rather than viewport positions.
- Scrolling moves the visible highlight with its original text, while copying
  returns the same cells regardless of the current scroll position.
- Incoming output and bounded history eviction preserve valid selections and
  clear only content that has actually been discarded or rearranged.

## Complete application mouse paths

- Option-forwarded application input supports left, middle, right, and extended
  buttons, press/release, button-motion, all-motion, and wheel events.
- X10, normal, UTF-8, SGR, urxvt, and SGR pixel-coordinate modes are handled,
  including correct legacy release codes and SGR release terminators.
- Duplicate motion reports within one cell, or one pixel in pixel mode, are
  suppressed. Ordinary clicks remain native selection and ordinary right-click
  retains the context menu.

The release gate covers universal Apple Silicon and Intel compilation, the full
`make check` suite, document-anchored selection while scrolling, every mouse
button and tracking mode, AddressSanitizer, UndefinedBehaviorSanitizer, static
analysis, packaging, signatures, and updater safety.
