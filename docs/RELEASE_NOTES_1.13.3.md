# Termatica 1.13.3

Termatica 1.13.3 makes the built-in command guide easier to scan.

- Bare `t` and `termatica` now divide commands into Remote & System,
  Configuration, Tools, and Maintenance sections.
- Related commands remain together, with a blank line between sections.
- The guide still omits duplicated quick aliases and internal renderer
  diagnostics. Those aliases remain available and documented in the README.
- Regression coverage verifies all four headings, the complete public command
  surface, and identical output from `t` and `termatica`.
