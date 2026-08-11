# Termatica 1.5.1

Termatica 1.5.1 improves Unicode and escape throughput, repairs the in-app
benchmark results presentation, and prevents isolated benchmarks from touching
the caller's protected working directory.

## Unicode and escapes

- Valid contiguous UTF-8 is decoded directly into a larger batched codepoint
  buffer while preserving fragmented and invalid-sequence behavior.
- Common Greek narrow scalars bypass unnecessary width and grapheme checks.
- Common two-scalar graphemes are interned without intermediate strings.
- CSI parsing clears only parameters that are actually reached.

On the release test machine, released v1.5.0 and v1.5.1 were each measured in
three independent runs with the same active user config, SF Mono 11, and five
repetitions per workload. Median parser Unicode improved from 112.8 to 121.4
MiB/s, unique graphemes from 87.2 to 93.3 MiB/s, and long escapes from 215.8 to
219.1 MiB/s. Median render-enabled Unicode improved from 109.3 to 145.9 MiB/s,
unique graphemes from 84.1 to 92.1 MiB/s, and long escapes from 193.4 to 210.3
MiB/s. These values measure accepted Kitty benchmark throughput, not
displayed-frame completion. All run-level artifacts are retained rather than
selecting one favorable sample.

## Benchmark results window

- `t b` freshly measures Termatica and shows all parser, render-enabled, and
  aggregate values in compact adaptive-width tables.
- Winners are bold, rows never wrap, and longer values scroll without breaking
  alignment.
- `t b a` freshly measures every installed comparison terminal; `t b` labels
  competitor values as saved, fresh, or unavailable rather than fabricating
  them.
- Isolated benchmark processes start in a private temporary directory instead
  of inheriting Desktop, Documents, Downloads, or another protected folder.

The release remains a universal macOS 13+ application for Apple Silicon and
Intel Macs.
