# Metal Phase 7 production hardening

Status: implemented and locally verified for the automated and release-host
scope. AppKit remains the default renderer and Metal remains an explicit config
choice.

## Objective

Harden the post-rollout failure path so a Metal initialization or runtime
failure cannot create a repeated retry/reconfiguration loop during display,
backing-scale, visibility, or wake lifecycle changes. Preserve terminal state,
make recovery behavior observable without collecting terminal content, and
retain an explicit user-controlled retry path.

## Implemented behavior

- A failed Metal pane enters a session-local quarantine and immediately uses
  AppKit. Lifecycle recoveries reconfigure the existing AppKit backend rather
  than repeatedly initializing Metal or replacing AppKit.
- Metal is retried only after the user explicitly selects AppKit and then Metal
  again. The selected config is not silently rewritten after fallback.
- Initialization and runtime failures are categorized separately. The renderer
  report includes requested and actual renderer, quarantine state, retry
  policy, failure count, failure stage, failure age, and the number of renderer
  reconfiguration attempts safely bypassed while quarantined.
- AppKit fallback clears stale Metal layer contents and restores the correct
  layer policy before presenting the preserved terminal snapshot.
- Renderer-report schema 2 includes the factual rollout policy: AppKit is the
  default, Metal is opt-in, AppKit remains available, and changing the default
  is blocked while physical and multi-machine field gates remain open.

## Deterministic gate

`--phase7-production-self-test` forces Metal initialization failure, verifies
one fallback, then runs 64 lifecycle recoveries and requires exactly one Metal
failure with preserved Unicode terminal content. It explicitly reselects
AppKit and Metal, verifies successful Metal presentation where available,
forces a runtime command-buffer failure, and runs another 32 lifecycle
recoveries without a retry loop. It also validates report schema 2 and the
rollout-policy fields.

On the Apple M4 release host, the native gate reported:

```text
phase7-production-self-test ok initialization-failures=1 quarantine-recoveries=64 runtime-metal-active=1 runtime-recoveries=32 retry=explicit-reselect state-preserved=yes default=appkit report-schema=2
```

CI runs the deterministic initialization-failure, quarantine, explicit-reset,
state-preservation, and report-policy portions without requiring a drawable.

## Verification

| Gate | Result |
|---|---|
| Complete `make check` | Pass |
| Phase 7 native production gate | Pass; initialization and runtime fallback |
| AddressSanitizer | Pass: terminal, reliability, Phase 6, and Phase 7 gates |
| UndefinedBehaviorSanitizer | Pass: terminal, reliability, Phase 6, and Phase 7 gates |
| Clang static analyzer | Pass for all three Objective-C translation units |
| Real PTY compatibility | Pass for zsh, Vim, Neovim, tmux, less, man, top, htop, SSH client, Codex, and OpenCode; Emacs unavailable |
| Fresh six-terminal matrix | Termatica 232.2 MB/s geo mean; Rio fastest startup at 4.874 ms |
| Equal-content renderer work | AppKit 4.105/4.519 ms p50/p95; Metal 2.494/3.605 ms p50/p95 |
| Release-length Metal soak | Pass: 83,102 frames, 1,298.2 MiB, 150.7 MiB peak, zero reversals |

The renderer timings measure documented software/GPU work, not physical
key-to-photon latency or visual correctness. The six-terminal render rows
measure accepted input and can complete before display presentation.

The final 30-minute native Metal soak presented 83,102 frames while processing
1,298.2 MiB. Physical footprint started at 64.0 MiB, peaked at 150.7 MiB under
the 256 MiB limit, and ended at 125.5 MiB. Renderer cache use ended at
5,242,884 bytes, maximum in-flight work was one frame, and generation
reversals were zero.

## Default-renderer boundary

Phase 7 does not make Metal the default. The release host still cannot supply
physical multi-display, clamshell, real sleep/wake, human VoiceOver, Intel
runtime, or broad multi-machine field evidence. AppKit remains the default,
and both AppKit and Metal remain selectable through `appearance.renderer`.
