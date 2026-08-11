# Metal Phase 5 reliability and rollout plan

Status: implemented and locally verified for the automated and available
real-PTY gates described below. Public release verification remains a separate
release step.

## Objective

Prove that the opt-in Metal renderer survives real terminal workflows and
system lifecycle changes without corrupting terminal state, losing input or
output, leaking renderer resources, or preventing automatic AppKit recovery.

## Test matrix

1. Run the complete gate with AppKit selected, Metal selected, forced Metal
   initialization failure, forced command-buffer failure, and Metal unavailable.
2. Exercise login shells plus Codex, OpenCode, Vim/Neovim, Emacs, tmux, less,
   man, top, htop, SSH, and representative full-screen alternate-screen TUIs.
3. Verify keyboard protocols, IME composition, selection, copy/paste, mouse
   reporting, wheel/trackpad history, synchronized output, prompt navigation,
   and resize during sustained PTY output.
4. Exercise tabs, arbitrary splits, Hyprland tiling, font/config reloads,
   backing-scale changes, multiple displays, display sleep/wake, system
   sleep/wake, and rapid window occlusion/reappearance.
5. Exercise Sixel, Kitty graphics, iTerm2 images, transparency, animated images,
   color emoji, fallback fonts, effects, and memory-pressure cache recovery.
6. Verify VoiceOver output and AppKit fallback without resetting the shell,
   terminal grid, scrollback, working directory, or active configuration.

## Reliability gates

- No crash, sanitizer finding, generation reversal, unbounded pending work, or
  in-flight count above two.
- The newest accepted snapshot is eventually presented or the backend falls
  back to AppKit with terminal state preserved.
- Thirty-minute mixed Unicode/image and sustained-output soaks remain within
  documented cache and process-memory bounds.
- AppKit and Metal parity, cache, scheduler, switching, terminal, decoder,
  package, signature, updater, and benchmark-artifact gates all pass from the
  final release commit.
- Real interactive tests record what was exercised and distinguish automated,
  visual, and manual evidence.

## Default-renderer decision

Metal remains opt-in during Phase 5. Making it the default requires completed
reliability evidence plus explicit approval after reviewing field reports and
fresh AppKit/Metal results. AppKit remains available regardless of that decision.

## Implemented reliability behavior

- Cursor visibility is owned only by the active terminal. Changing focus
  invalidates both the previous and next pane, including their submitted render
  snapshots, so a stale cursor cannot remain after Command-T or split focus.
- Backing-scale, display, window occlusion/reappearance, screen wake, and system
  wake events use one state-preserving presentation recovery path. The renderer
  is reconfigured and fully redrawn without recreating the terminal or PTY.
- Metal resource pressure, initialization failure, and command-buffer failure
  continue to recover through bounded cache purge or automatic AppKit fallback.

## Automated evidence on the Phase 5 release host

| Gate | Result |
|---|---|
| AppKit and Metal cursor/lifecycle reliability | Pass: 3 panes, 240 focus switches, 72 recoveries |
| Cursor ownership | Pass: exactly one active, snapshot, and submitted cursor after every switch |
| Resize and font reload | Pass during sustained focus cycling |
| Pane state after lifecycle changes | Pass for all 3 panes |
| Forced Metal initialization and command failure | Pass with AppKit fallback and preserved content |
| Snapshot scheduler | Pass: pending <= 1, in flight <= 2, generation reversals 0 |
| Glyph/image cache pressure and purge recovery | Pass: image cache <= 32 MiB |
| AppKit/Metal semantic and pixel corpus | Pass for ASCII, Unicode, graphemes, cursor styles, images, effects, and tiled rendering |
| Real PTY applications | Pass: zsh, Vim, Neovim, tmux, less, man, top, htop, SSH client, Codex, OpenCode |
| Emacs | Not run: executable is not installed on the release host |

The real-PTY gate launches the actual installed executables inside Termatica's
PTY model and Metal renderer path. Vim, Neovim, tmux, less, man, and htop are
driven through their interactive screens. Codex and OpenCode exercise their
launch and help-output paths, not a networked agent conversation. The SSH row
exercises the local OpenSSH client and version/terminal output path; it does not
claim a remote network-session test.
Physical movement between two monitors, a real system sleep cycle, VoiceOver
interaction by a human user, and field behavior on other Macs remain manual or
external evidence and are not represented as automated passes.

## Long soak

`--phase5-soak 1800` exercises sustained Unicode, complex graphemes, ANSI
styles, inline image residency, scrolling, immutable snapshots, and native
Metal presentation for thirty minutes. It rejects process memory above 256 MiB,
image cache use above 32 MiB, more than one pending snapshot, more than two
in-flight frames, any generation reversal, renderer fallback, or frame timeout.
On the Apple M4 release host, the completed run measured 1,800.0 seconds,
77,234 presented frames, and 1,206.5 MiB of mixed input. Physical footprint
started at 8.4 MiB, peaked at 152.0 MiB, and ended at 137.0 MiB. Metal cache
use ended at 5,242,884 bytes, maximum in-flight work was one frame, and
generation reversals were zero. These are measurements from this host and run,
not universal memory or frame-rate guarantees.

## Fresh post-soak renderer measurements

Five fresh 240-frame native Metal runs used the Phase 4 methodology. The median
run values were 0.911 ms p50, 5.028 ms p95, and 5.569 ms p99 renderer work, with
zero frames above the 60 Hz or 120 Hz work budgets and 27 frames above the
synthetic 240 Hz work budget. The observed five-run ranges were 0.880-0.929 ms
p50, 4.823-5.266 ms p95, 5.486-6.133 ms p99, and 19-29 synthetic 240 Hz
overshoots. Maximum in-flight work was one frame and generation reversals were
zero in every run.

The equal-content renderer comparison measured AppKit work at 7.436 ms p50 and
7.698 ms p95, versus Metal at 2.175 ms p50 and 4.509 ms p95. This measures the
documented offscreen AppKit paint path against Metal snapshot, CPU encoding, and
GPU execution work; it is not physical key-to-photon or display scanout latency.
Metal therefore remains opt-in despite the lower median work in this run.
