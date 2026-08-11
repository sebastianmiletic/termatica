# Termatica 1.8.0 six-terminal benchmark

Fresh run on 2026-08-11 using an Apple M4 Mac with 16 GB memory, Monaco 11
where configurable, three throughput repetitions, and five shell-ready
launches. Higher throughput is better; lower startup, memory, and allocation
are better.

| Terminal | 15-workload geo mean | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|---:|
| Termatica 1.8.0 | **234.9 MB/s** | 5.532 ms | **29.9 MiB** | **1,360 KiB** |
| Kitty 0.48.1 | 101.5 MB/s | 8.365 ms | 72.0 MiB | 160,080 KiB |
| Ghostty 1.3.1 | 86.0 MB/s | 5.695 ms | 90.2 MiB | 63,484 KiB |
| Alacritty 0.17.0 | 152.8 MB/s | 5.859 ms | 63.5 MiB | 14,328 KiB |
| WezTerm 20240203 | 63.0 MB/s | 5.409 ms | 44.3 MiB | 259,840 KiB |
| Rio 0.5.2 | 92.2 MB/s | **5.216 ms** | 88.5 MiB | 41,992 KiB |

The geometric mean covers six parser, six render-enabled, and three scrollback
workloads. Render mode permits asynchronous presentation and therefore reports
accepted throughput, not confirmed display completion. Image throughput does
not prove equivalent graphics-protocol support. Shell-ready time ends when a
child shell writes and syncs a marker, not at the first visible frame. Physical
footprint is one post-settle sample.

Every raw result, startup sample, memory sample, version, and Termatica internal
JSON result used for this summary is retained in this directory.
