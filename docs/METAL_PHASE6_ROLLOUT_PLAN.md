# Metal Phase 6 rollout plan

Status: prepared. Start only after the Phase 5 release and its public artifacts
are verified.

## Objective

Collect field evidence from the opt-in Metal renderer, close the remaining
physical/manual coverage gaps, and make an evidence-based decision about
whether Metal should remain opt-in or become the default while always retaining
AppKit as a selectable fallback.

## Gates

1. Verify real multi-display movement across different scale and refresh-rate
   displays, clamshell transitions, display sleep/wake, and a physical macOS
   system sleep/wake cycle.
2. Complete VoiceOver navigation, IME, selection, clipboard, mouse, trackpad,
   and accessibility review with AppKit and Metal selected.
3. Run remote SSH sessions and long-lived Codex/OpenCode/tmux/editor workflows,
   including network interruption and reconnection behavior where the program
   supports it.
4. Gather crash, fallback, memory, and rendering reports from the Phase 5 public
   build across Apple Silicon and Intel Macs.
5. Repeat the complete release gate, 30-minute soak, and same-machine AppKit vs
   Metal benchmark on the final Phase 6 commit.

## Decision rule

Changing the default is a separate product decision, not an automatic result of
passing tests. It requires the physical/manual gates, acceptable field reports,
and explicit approval. If those conditions are not met, Metal remains opt-in.
