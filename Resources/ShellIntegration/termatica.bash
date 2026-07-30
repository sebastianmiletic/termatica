if [[ $- == *i* && -z "${TERMATICA_SHELL_INTEGRATION_ACTIVE:-}" ]]; then
  TERMATICA_SHELL_INTEGRATION_ACTIVE=1
  _termatica_prompt_command() {
    local command_status=$?
    printf '\e]133;D;%d\a\e]133;A\a\e]7;file://%s%s\a' \
      "$command_status" "${HOSTNAME:-localhost}" "$PWD"
  }
  if [[ -n "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND="_termatica_prompt_command;${PROMPT_COMMAND}"
  else
    PROMPT_COMMAND="_termatica_prompt_command"
  fi
  if [[ -n "${TERMATICA_HIDDEN_PATH:-}" && -r "${TERM_HP:-}" ]]; then
    _termatica_hidden_path_init() {
      source "$TERM_HP" on 2>/dev/null
      unset -f _termatica_hidden_path_init
      unset -f _termatica_hidden_path_prompt_command
    }
    _termatica_hidden_path_prompt_command() {
      _termatica_hidden_path_init
      _termatica_prompt_command
    }
    PROMPT_COMMAND="_termatica_hidden_path_prompt_command;${PROMPT_COMMAND#_termatica_prompt_command;}"
  fi
  trap 'printf "\\e]133;C\\a"' DEBUG

  # Option (Alt) keybindings for word movement (readline).
  # Termatica sends CSI 1;3 <final> for Option+arrows and ESC-prefixed chars for Option+printable.
  bind '"\e[1;3C": forward-word'      # Option+Right  - forward word
  bind '"\e[1;3D": backward-word'     # Option+Left   - backward word
  bind '"\e[1;3A": previous-history' # Option+Up     - previous command
  bind '"\e[1;3B": next-history'     # Option+Down   - next command
  bind '"\e[1;3H": beginning-of-line' # Option+Home  - start of line
  bind '"\e[1;3F": end-of-line'       # Option+End   - end of line
  bind '"\eb": backward-word'         # Option+B     - backward word
  bind '"\ef": forward-word'         # Option+F     - forward word
  bind '"\ed": kill-word'             # Option+D     - delete word forward
  bind '"\e\x7f": backward-kill-word' # Option+Backspace - delete word backward
fi
