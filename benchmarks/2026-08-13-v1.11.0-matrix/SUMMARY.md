# Termatica 1.11.0 six-terminal benchmark

Fresh run on 2026-08-13 using an Apple M4 Mac with 16 GB memory, Monaco 11
where configurable, three throughput repetitions, and five shell-ready
launches. The Mac was on battery power and the one-minute load average was 2.80
when inspected. Higher throughput is better; lower startup, memory, and
allocation are better.

| Terminal | 15-workload geo mean | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|---:|
| Termatica 1.11.0 | **116.5 MB/s** | 17.377 ms | **26.3 MiB** | **1,392 KiB** |
| Kitty 0.48.1 | 44.0 MB/s | 23.044 ms | 120.5 MiB | 160,080 KiB |
| Ghostty 1.3.1 | 25.8 MB/s | 17.195 ms | 87.0 MiB | 63,484 KiB |
| Alacritty 0.17.0 | 56.4 MB/s | 41.767 ms | 68.6 MiB | 14,328 KiB |
| WezTerm 20240203 | 20.8 MB/s | **11.729 ms** | 46.5 MiB | 259,840 KiB |
| Rio 0.5.2 | 33.6 MB/s | 20.461 ms | 44.3 MiB | 41,992 KiB |

The geometric mean covers six parser, six render-enabled, and three scrollback
workloads. Render mode permits asynchronous presentation and therefore reports
accepted throughput, not confirmed display completion. Image throughput does
not prove equivalent graphics-protocol support. Shell-ready time ends when a
child shell writes and syncs a marker, not at the first visible frame. Physical
footprint is one post-settle sample. Absolute values must not be compared with
a differently loaded or powered run.

Every raw result, startup sample, memory sample, version, and Termatica internal
JSON result used for this summary is retained in this directory.
