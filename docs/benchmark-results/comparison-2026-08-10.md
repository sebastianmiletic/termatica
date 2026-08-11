# Comparison snapshot — 2026-08-10

Source: `/tmp/termatica-all-categories-clean-20260810` on the test machine. Methodology and
limitations are in [../BENCHMARKS.md](../BENCHMARKS.md).

| Result where Termatica did not lead | Winner | Winner | Termatica |
|---|---|---:|---:|
| Fresh shell-ready median | Alacritty | 4.658 ms | 5.837 ms |
| Parser long escapes | Kitty | 327.9 MB/s | 287.9 MB/s |
| Parser image stream | Alacritty | 418.9 MB/s | 296.4 MB/s |
| Render Unicode | Alacritty | 208.4 MB/s | 205.7 MB/s |
| Render image stream | Alacritty | 443.9 MB/s | 349.3 MB/s |

The image-stream number does not prove equivalent image presentation; a
terminal may reject or discard a graphics protocol faster than another terminal
decodes and stores it.

## Updated Termatica vtebench result

This is a supplied-reference-to-after comparison within the upstream vtebench
method, not a cross-terminal rendering-quality result. Lower is better.

| Workload | Supplied reference | Updated Termatica | Reduction |
|---|---:|---:|---:|
| dense_cells | 15.35 ms | 9.21 ms | 40.0% |
| medium_cells | 16.37 ms | 7.92 ms | 51.6% |
| scrolling | 113.39 ms | 60.66 ms | 46.5% |
| scrolling_bottom_region | 40.30 ms | 24.01 ms | 40.4% |
| scrolling_bottom_small_region | 43.93 ms | 23.87 ms | 45.7% |
| scrolling_fullscreen | 232.68 ms | 104.99 ms | 54.9% |
| scrolling_top_region | 393.33 ms | 24.24 ms | 93.8% |
| scrolling_top_small_region | 42.37 ms | 23.95 ms | 43.5% |
| sync_medium_cells | 12.00 ms | 8.06 ms | 32.8% |
| unicode | 10.11 ms | 6.85 ms | 32.2% |

Raw updated data: `/tmp/termatica-vte-final-20260810a.dat`. vtebench measures
PTY acceptance time and does not prove completed display presentation.
