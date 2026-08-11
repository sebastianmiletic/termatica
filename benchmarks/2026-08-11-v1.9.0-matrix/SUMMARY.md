# Termatica 1.9.0 six-terminal benchmark

Fresh run on 2026-08-11 using an Apple M4 Mac with 16 GB memory, Monaco 11
where configurable, three throughput repetitions, and five shell-ready
launches. Higher throughput is better; lower startup, memory, and allocation
are better.

| Terminal | 15-workload geo mean | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|---:|
| Termatica 1.9.0 | **232.2 MB/s** | 5.696 ms | **26.0 MiB** | **1,360 KiB** |
| Kitty 0.48.1 | 108.7 MB/s | 6.225 ms | 118.1 MiB | 160,080 KiB |
| Ghostty 1.3.1 | 87.3 MB/s | 6.536 ms | 79.4 MiB | 63,484 KiB |
| Alacritty 0.17.0 | 161.7 MB/s | 5.800 ms | 66.5 MiB | 14,328 KiB |
| WezTerm 20240203 | 63.3 MB/s | 5.910 ms | 42.4 MiB | 259,840 KiB |
| Rio 0.5.2 | 93.9 MB/s | **4.874 ms** | 38.0 MiB | 41,992 KiB |

The geometric mean covers six parser, six render-enabled, and three scrollback
workloads. Render mode permits asynchronous presentation and therefore reports
accepted throughput, not confirmed display completion. Image throughput does
not prove equivalent graphics-protocol support. Shell-ready time ends when a
child shell writes and syncs a marker, not at the first visible frame. Physical
footprint is one post-settle sample.

Every raw result, startup sample, memory sample, version, and Termatica internal
JSON result used for this summary is retained in this directory.
