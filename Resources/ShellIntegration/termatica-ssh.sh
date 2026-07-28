# Termatica SSH integration
_termatica_ssh() {
    local term="${TERM:-xterm-256color}"
    local colorterm="${COLORTERM:-}"
    local term_program="${TERM_PROGRAM:-}"
    local ssh_env="TERM=$term"
    [ -n "$colorterm" ] && ssh_env="$ssh_env COLORTERM=$colorterm"
    [ -n "$term_program" ] && ssh_env="$ssh_env TERM_PROGRAM=$term_program"
    ssh -t "$@" "$ssh_env; exec \$SHELL -l"
}
_termatica_sudo() {
    sudo TERM="${TERM:-xterm-256color}" COLORTERM="${COLORTERM:-truecolor}" TERM_PROGRAM="${TERM_PROGRAM:-Termatica}" "$@"
}
command -v ssh >/dev/null 2>&1 && alias ssh='_termatica_ssh' 2>/dev/null
command -v sudo >/dev/null 2>&1 && alias sudo='_termatica_sudo' 2>/dev/null