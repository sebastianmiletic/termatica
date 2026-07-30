# Termatica 1.2.3

## Terminal layout

- Anchored the prompt to the top of the terminal window. Content no longer
  reserves the title-bar safe area as empty space, so the command line sits at
  the top where it belongs.

## Icon

- Restored the black icon and GitHub repository logo (white wordmark on a
  black background) with rounded corners. Bundle size is back under 1 MiB.

## Shell integration

- Added Option (Alt) keybindings for word movement and editing in zsh and
  bash: Option+Left/Right (word jump), Option+Up/Down (line/history),
  Option+Home/End (line start/end), Option+B/F (word back/forward),
  Option+D (delete word forward), and Option+Backspace (delete word backward).

## Code cleanup

- Removed dead code: the unused `code` CLI, the `configs` CLI, and the
  interactive module browser.

## Scope

- No theme or behavior changes beyond the prompt anchoring and shell
  keybindings.