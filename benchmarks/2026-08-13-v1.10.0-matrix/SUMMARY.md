# Termatica 1.10.0 six-terminal benchmark

Fresh run on 2026-08-13 using an Apple M4 Mac with 16 GB memory, Monaco 11
where configurable, three throughput repetitions, and five shell-ready
launches. The Mac was on battery power and the one-minute load average was 7.17
when inspected. Higher throughput is better; lower startup, memory, and
allocation are better.

| Terminal | 15-workload geo mean | Shell-ready median | Physical footprint | App allocation |
|---|---:|---:|---:|---:|
| Termatica 1.10.0 | **75.5 MB/s** | 34.403 ms | **30.3 MiB** | **1,376 KiB** |
| Kitty 0.48.1 | 41.6 MB/s | 61.062 ms | 118.1 MiB | 160,080 KiB |
| Ghostty 1.3.1 | 13.4 MB/s | 30.436 ms | 97.4 MiB | 63,484 KiB |
| Alacritty 0.17.0 | 35.4 MB/s | 50.551 ms | 147.7 MiB | 14,328 KiB |
| WezTerm 20240203 | 16.4 MB/s | **27.897 ms** | 47.8 MiB | 259,840 KiB |
| Rio 0.5.2 | 32.0 MB/s | 31.319 ms | 50.0 MiB | 41,992 KiB |

The geometric mean covers six parser, six render-enabled, and three scrollback
workloads. Render mode permits asynchronous presentation and therefore reports
accepted throughput, not confirmed display completion. Image throughput does
not prove equivalent graphics-protocol support. Shell-ready time ends when a
child shell writes and syncs a marker, not at the first visible frame. Physical
footprint is one post-settle sample. Absolute values must not be compared with
a differently loaded or powered run.

Every raw result, startup sample, memory sample, version, and Termatica internal
JSON result used for this summary is retained in this directory.
