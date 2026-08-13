# Termatica 1.12.0 six-terminal benchmark

Fresh run on 2026-08-13 using an Apple M4 Mac with 16 GB memory, Monaco 11
where configurable, three throughput repetitions, and five shell-ready
launches. The Mac was on AC power and the one-minute load average was 1.75 when
inspected. Higher throughput is better; lower startup, memory, and allocation
are better.

| Terminal | 15-workload geo mean | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|---:|
| Termatica 1.12.0 | **237.5 MB/s** | 5.170 ms | **26.0 MiB** | **1,408 KiB** |
| Kitty 0.48.1 | 108.1 MB/s | 7.473 ms | 118.2 MiB | 160,080 KiB |
| Ghostty 1.3.1 | 87.1 MB/s | 5.029 ms | 135.7 MiB | 63,484 KiB |
| Alacritty 0.17.0 | 154.6 MB/s | 6.972 ms | 142.6 MiB | 14,328 KiB |
| WezTerm 20240203 | 63.8 MB/s | 5.425 ms | 48.9 MiB | 259,840 KiB |
| Rio 0.5.2 | 95.8 MB/s | **4.687 ms** | 88.4 MiB | 41,992 KiB |

The geometric mean covers six parser, six render-enabled, and three scrollback
workloads. Render mode permits asynchronous presentation and therefore reports
accepted throughput, not confirmed display completion. Image throughput does
not prove equivalent graphics-protocol support. Shell-ready time ends when a
child shell writes and syncs a marker, not at the first visible frame. Physical
footprint is one post-settle sample. Absolute values must not be compared with
a differently loaded or powered run.

Every raw result, startup sample, memory sample, version, and Termatica internal
JSON result used for this summary is retained in this directory.
