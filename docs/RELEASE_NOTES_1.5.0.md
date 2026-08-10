# Termatica 1.5.0

Termatica 1.5.0 adds a non-destructive benchmark inside the running app and hardens Unicode, image, newline, cursor, and input rendering.

## Rendering correctness and performance

- AppKit reuses cached regular and wide-cell text attributes instead of rebuilding font dictionaries and measuring glyph advances for every style run.
- Metal reuses uploaded textures for unchanged inline images, and animated Kitty images reuse retained frames instead of copying a `CGImage` on every tick.
- Fully transparent Kitty RGBA streams create and track a real cached transparent image; they are no longer treated as an image-free fast path.
- Explicit line feeds consume a pending right-margin wrap, preventing a second unintended line feed on the next character.
- Render snapshots clamp cursor coordinates to the visible grid, preventing an edge cursor rectangle outside the terminal cells.
- Native selection clicks below the last visible content row are ignored. Mouse-aware terminal programs still receive their opted-in mouse protocol events.

## Configured font across the app

The existing `fontName`, `fontSize`, and `fontFeatures` settings remain part of each independent named config. The configured family now also reaches search controls and native tab labels, in addition to terminal text and input-method composition.

## In-app benchmark

Run `termatica benchmark` or `t b` inside the Termatica instance being measured. It uses the running version and active config, reports version/build, renderer, font, display refresh, process footprint, parser/model throughput, and offscreen text/image paint timing, and does not close or replace any PTY, tab, process, scrollback buffer, or window.

## Measured boundary

On the release test machine, the focused AppKit experience benchmark's p50 paint time moved from 0.570 ms to 0.495 ms and p95 from 0.700 ms to 0.532 ms. A fresh three-repetition six-terminal protocol run still had competitor wins: Alacritty led parser Unicode, parser image stream, rendered Unicode, and rendered image stream; Kitty led parser long escapes; Rio led rendered ASCII and had the lowest five-launch shell-ready median. These protocol results are not equivalent to visual-quality or key-to-photon measurements.

The release remains a universal macOS 13+ application for Apple Silicon and Intel Macs.
