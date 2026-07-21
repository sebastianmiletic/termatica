# Contributing

Termatica keeps its native core deliberately small. Changes should preserve fast startup, keyboard-first operation, terminal-native workflows, and the 1 MB release bundle target.

## Development

Requirements: macOS 13 or later and Apple Command Line Tools.

```sh
make release
make check
open build/Termatica.app
```

Before opening a pull request:

1. Build both Apple Silicon and Intel slices with `make release`.
2. Run `make check`.
3. Keep plugins and external runtimes outside the app bundle.
4. Document user-facing commands or protocol changes.
5. Include the exact manual terminal behavior you verified.

Bug reports should include the macOS version, CPU architecture, shell, command, expected behavior, and actual behavior. Set `TERMATICA_VERBOSE=1` before launching the app when diagnostic output is useful.
