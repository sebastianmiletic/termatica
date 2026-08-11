# Termatica 1.7.0

Termatica 1.7.0 completes Metal Phase 5 reliability work while keeping AppKit
the default and Metal opt-in through `appearance.renderer`.

## Fixed

- Command-T, tab selection, and split focus changes now leave exactly one
  visible terminal cursor. Previously submitted frames for inactive panes are
  invalidated so cursor ghosts cannot remain beside old prompts.
- Renderer presentation now recovers after backing-scale, display, occlusion,
  screen-wake, and system-wake changes without replacing the shell or terminal
  state.

## Verification

- AppKit/Metal focus and lifecycle stress: 3 panes, 240 focus switches, 72
  recovery events, repeated resize and font reload, with pane state preserved.
- Real PTY execution passed for zsh, Vim, Neovim, tmux, less, man, top, htop,
  the OpenSSH client, Codex, and OpenCode on the release host. Emacs was not
  installed and is explicitly recorded as not run.
- Existing renderer fallback, switching, parity, cache, scheduler, decoder,
  sanitizer, package, signature, updater, and benchmark-artifact gates remain
  release blockers.
- The 30-minute Metal Unicode/image soak presented 77,234 frames while parsing
  1,206.5 MiB, peaked at 152.0 MiB physical footprint, retained a 5.24 MiB
  renderer cache, used at most one in-flight frame, and recorded zero generation
  reversals on the release host.

The release does not replace a running installed app. Download or update only
after the GitHub release and its assets have been published and verified.
