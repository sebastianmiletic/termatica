# Termatica 1.1.1

## Fixed

- Makes the Metal renderer failure-path test deterministic in headless GitHub
  Actions by presenting an explicit frame before waiting for AppKit fallback.
- Restores green CI and release packaging verification for the Phase 10 Metal
  renderer introduced in 1.1.0.

## Included

- Contains the complete opt-in Metal renderer, AppKit fallback, inline-image
  rendering, resize stress coverage, and performance work from 1.1.0.
