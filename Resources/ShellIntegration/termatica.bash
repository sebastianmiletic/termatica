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
fi
