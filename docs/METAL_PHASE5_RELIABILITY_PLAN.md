# Metal Phase 5 reliability and rollout plan

Status: prepared, not started. Phase 5 begins only after the Phase 4 release is
published and independently verified.

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
