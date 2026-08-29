# Terminal-native automation

Termatica 1.14.10 exposes one local automation model through the `termatica`
CLI, its owner-only Unix datagram socket, and the native macOS AppleScript
dictionary. It controls windows, tabs, splits, focus, commands, literal input,
named keys, and explicitly launched SSH layouts.

## CLI

```sh
t a status
t a new-tab --cwd ~/Coding --command 'nvim .'
t a new-window --cwd /tmp
t a split horizontal --command 'btop'
t a split vertical
t a close pane
t a close tab
t a close window
t a focus tab 2
t a focus pane 1
t a focus next
t a send 'literal text without Return'
t a run 'git status'
t a key ctrl-c
t a activate
```

`status` returns JSON describing window, tab, pane, and focus topology. It does
not expose terminal text, scrollback, or command history. Text and commands are
bounded to 4,096 characters. `--cwd` must resolve to an existing directory.
Supported named keys are `enter`, `return`, `escape`, `tab`, arrows, `home`,
`end`, `page-up`, `page-down`, `ctrl-c`, and `ctrl-d`.

`close` accepts `pane`, `tab`, or `window`. It refuses to close the final
terminal, which prevents an unattended automation sequence from terminating
the app.

## Named SSH launch recipes

Recipes contain only a layout direction and the names of 1–9 existing
password-free SSH profiles:

```sh
t ssh add app app.example.com --user deploy
t ssh add logs logs.example.com --user deploy
t a recipe save production --vertical app logs
t a recipe list
t a recipe show production
t a recipe run production
t a recipe remove production
```

They are stored in `~/.config/termatica/launch-recipes.json` with mode `0600`.
Profiles remain in `ssh-hosts.json`; recipes do not copy credentials or terminal
state. A recipe runs only after an explicit CLI or AppleScript request.

## AppleScript

The app bundle includes a native scripting dictionary. Examples:

```applescript
tell application "Termatica"
  termaticastatus
  newterminaltab "nvim ."
  splitterminal "btop"
  splitterminalvertically
  focusterminal "pane 2"
  sendterminaltext "literal input"
  pressterminalkey "enter"
  runterminalcommand "git status"
  launchsshrecipe "production"
end tell
```

AppleScript commands use the same validation and app-side implementation as the
CLI socket. macOS may ask the controlling app for Automation permission.

## Socket protocol and security

The CLI discovers the socket from the active config directory. The pathname is
derived from the current user ID and a hash of that directory. Termatica
refuses to replace a socket it does not own, binds an `AF_UNIX` datagram socket,
and sets mode `0600`. There is no TCP listener or network remote control.

Requests are JSON objects with `"command":"automation"` and an `action` such
as `status`, `new-tab`, `new-window`, `close`, `split`, `focus`, `send`, `run`,
`key`, `activate`, or `recipe`. The CLI creates a private reply socket for every public
automation request, so success and validation failures are observable.

## Fresh-start boundary

Automation is deliberately operational, not restorative. Termatica never saves
or automatically restores terminal contents, scrollback, processes, tabs,
splits, working directories, recipes, or window state. Named recipes are inert
data until explicitly launched and create fresh shells and fresh SSH processes.
