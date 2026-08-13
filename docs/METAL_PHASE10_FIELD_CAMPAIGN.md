# Metal rollout Phase 10 field campaign

Termatica 1.12.0 adds a cross-machine collection layer above the Phase 9
current-session report. AppKit remains the default and Metal remains optional.

## Export

Run `t rc export report.json` while the updated Termatica app is running. The
file is written atomically with mode `0600`. Omitting the path prints JSON to
standard output.

The export contains the Termatica version/build, an ephemeral identifier for
the running app session, architecture and Rosetta state, and numeric
display/lifecycle/Metal evidence. It excludes terminal content, commands,
working directories, config paths, environment variables, display names, and
persistent machine identifiers.

The envelope includes a SHA-256 digest of canonical sorted-key JSON. That
detects modification after export; it is not a digital signature and does not
authenticate a Mac or operator. A shared signing secret embedded in the app
would be extractable and would provide a false security claim.

## Aggregate

Run `t rc aggregate apple.json intel.json display.json`. Aggregation:

- validates the envelope, digest, schema, privacy declaration, and observed
  runtime evidence source;
- rejects modified, malformed, synthetic-source, or unsupported reports;
- accepts only one report per ephemeral app session, including re-exports whose
  timestamps or counters changed;
- combines coverage for healthy Metal sessions, native Apple Silicon and Intel,
  multi-display, display-count change, scale, screen, refresh, and wake events;
- lists every open gate and always requires operator review.

The session identifier is random, exists only for one running app process, and
is not stored as a durable machine identity. It prevents one session from being
counted repeatedly but cannot prove that two reports came from two physical
Macs. Aggregation therefore reports integrity and collected coverage, not
hardware or human authenticity.

## Physical boundary

Software cannot determine whether a person inspected every resulting frame for
clipping, mirroring, stale cells, black squares, color errors, or animation
glitches. `physicalVisualInspectionConfirmed` therefore remains false in
automatic output. Even when every observable field category is present,
`defaultRendererChangeEligible` remains false and AppKit remains the default.

## Deterministic gate

`--phase10-campaign-self-test` validates two-architecture aggregation, exact and
same-session deduplication, digest tamper rejection, synthetic-source rejection,
privacy, complete software evidence, mandatory operator review, and the AppKit
default boundary. Its architecture/display events are fixtures, not physical
field evidence.

## Release-candidate evidence

- Complete `make check`: pass, including native Metal parity, switching,
  scheduling, reliability, Phases 6-10, and real-PTY compatibility.
- AddressSanitizer and UndefinedBehaviorSanitizer: pass for terminal,
  reliability, recovery, field qualification, campaign, and decoder gates.
- Clang static analyzer: zero diagnostics across all three Objective-C files.
- Five-minute native Metal soak: 12,829 frames, 200.4 MiB processed, 161.7 MiB
  peak footprint against a 256 MiB limit, 5,242,884 cache bytes, one maximum
  frame in flight, and zero generation reversals.
- Fresh same-machine six-terminal matrix: Termatica led the 15-workload
  geometric mean at 237.5 MB/s; Rio led shell-ready median at 4.687 ms and
  Ghostty was also lower than Termatica at 5.029 versus 5.170 ms.
