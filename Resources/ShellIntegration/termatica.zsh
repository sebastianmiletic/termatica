if [[ -o interactive && -z "${TERMATICA_SHELL_INTEGRATION_ACTIVE:-}" ]]; then
  typeset -g TERMATICA_SHELL_INTEGRATION_ACTIVE=1
  autoload -Uz add-zsh-hook

  _termatica_precmd() {
    local command_status=$?
    printf '\e]133;D;%d\a\e]133;A\a\e]7;file://%s%s\a' \
      "$command_status" "${HOST:-localhost}" "$PWD"
  }

  _termatica_preexec() {
    printf '\e]133;C\a'
  }

  add-zsh-hook precmd _termatica_precmd
  add-zsh-hook preexec _termatica_preexec
fi
