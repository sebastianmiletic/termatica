# Termatica 1.3.2

## Fix

- Fixed `termatica bench` closing Termatica but not running the benchmark.
- The helper script is now launched in a new macOS Terminal window via
  `osascript` (AppleScript `do script`) instead of `open -a Terminal.app`,
  which failed to execute the script and silently exited.
- Added a "Continue?" confirmation after the first-run helper install, so
  the benchmark does not start immediately without the user opting in.

## Scope

- No other changes from 1.3.1. Bundle under 1.03 MiB.