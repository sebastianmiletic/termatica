# Termatica 1.2.5

## Prompt

- Removed zsh's bare default prompt character (`%`). When the user has not
  customized their prompt, Termatica now shows a clean directory prompt
  (`<directory> ❯`) instead of the bare `%`.
- Users with a custom `PROMPT`/`PS1` in their shell config are unaffected.

## Cumulative updates in 1.2.x

- In-terminal benchmark (`termatica bench` / `t b`) with warning, parser/render/
  scrollback workloads, results table vs the six-terminal reference, and
  automatic app reopen.
- Black rounded-corner icon for the app and GitHub repository logo.
- Option (Alt) keybindings for word movement and editing in zsh and bash.
- Dead code removed (module browser, `code`/`configs` CLIs).
- Prompt anchored to the top of the terminal window.
- Bundle under 1 MiB (1011.7 KiB). No theme changes.