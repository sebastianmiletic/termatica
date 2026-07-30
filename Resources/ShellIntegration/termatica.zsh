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

  if [[ -n "${TERMATICA_HIDDEN_PATH:-}" && -r "${TERM_HP:-}" ]]; then
    _termatica_hidden_path_init() {
      source "$TERM_HP" on 2>/dev/null
      add-zsh-hook -d precmd _termatica_hidden_path_init
      unset -f _termatica_hidden_path_init
    }
    add-zsh-hook precmd _termatica_hidden_path_init
  fi

  add-zsh-hook precmd _termatica_precmd
  add-zsh-hook preexec _termatica_preexec

  # Option (Alt) keybindings for word movement and editing.
  # Termatica sends CSI 1;3 <final> for Option+arrows and ESC-prefixed chars for Option+printable.
  bindkey '\e[1;3C' forward-word      # Option+Right  - forward word
  bindkey '\e[1;3D' backward-word     # Option+Left   - backward word
  bindkey '\e[1;3A' up-line          # Option+Up     - up one line
  bindkey '\e[1;3B' down-line        # Option+Down   - down one line
  bindkey '\e[1;3H' beginning-of-line # Option+Home   - start of line
  bindkey '\e[1;3F' end-of-line       # Option+End    - end of line
  bindkey '\eb'     backward-word     # Option+B      - backward word
  bindkey '\ef'     forward-word      # Option+F      - forward word
  bindkey '\ed'     kill-word         # Option+D      - delete word forward
  bindkey '\e\x7f'  backward-kill-word # Option+Backspace - delete word backward
  bindkey '\e<'     beginning-of-buffer-or-history  # Option+<  - top of buffer
  bindkey '\e>'     end-of-buffer-or-history         # Option+>  - bottom of buffer
fi
