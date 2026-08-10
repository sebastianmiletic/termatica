# Comparison snapshot — 2026-08-10

Source: `/tmp/termatica-render-fixes-final-20260810` on the test machine. Methodology and
limitations are in [../BENCHMARKS.md](../BENCHMARKS.md).

| Result where Termatica did not lead | Winner | Winner | Termatica |
|---|---|---:|---:|
| Fresh shell-ready median | Rio | 3.513 ms | 4.307 ms |
| Parser Unicode | Alacritty | 186.2 MB/s | 169.7 MB/s |
| Parser long escapes | Kitty | 327.6 MB/s | 226.0 MB/s |
| Parser image stream | Alacritty | 417.9 MB/s | 261.9 MB/s |
| Render ASCII | Rio | 167.3 MB/s | 158.6 MB/s |
| Render Unicode | Alacritty | 203.7 MB/s | 160.3 MB/s |
| Render image stream | Alacritty | 447.4 MB/s | 332.0 MB/s |

The image-stream number does not prove equivalent image presentation; a
terminal may reject or discard a graphics protocol faster than another terminal
decodes and stores it.
