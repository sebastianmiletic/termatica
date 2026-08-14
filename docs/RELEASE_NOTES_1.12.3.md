# Termatica 1.12.3

Termatica 1.12.3 refreshes the terminal-native configuration experience and
removes competing sources of profile identity.

- Config names are the actual `.json` filenames shown in `t c`.
- The current profile is selected by an atomic `current` file; settings are
  loaded only from that selected profile and never merged with another config.
- New, select, rename, and delete operations handle the filename and selector
  together, with rollback where a multi-file operation cannot complete.
- Invalid JSON profiles are marked INVALID and cannot be selected.
- Settings are grouped by purpose, including AppKit/Metal under Performance and
  fonts, colours, transparency, blur, effects, and cursor styling under
  Appearance.
- Long profile and settings lists scroll within the terminal viewport.
- Config watching covers repeated atomic edits, profile changes, and direct
  edits to the selected file, then re-arms after every relevant filesystem
  event.
- Existing `config.json` installations migrate to schema version 2. A
  compatibility symlink continues to point existing editors and scripts at the
  selected profile.

The release regression suite covers interactive keyboard navigation, renderer
selection, profile isolation, partial and malformed JSON, direct edits,
transactional filename operations, migration, permissions, and repeated watcher
reloads. This release does not replace or restart a running installed app.
