typeset -g _termatica_original_zdotdir="${TERMATICA_ORIGINAL_ZDOTDIR:-$HOME}"
export ZDOTDIR="$_termatica_original_zdotdir"
if [[ -r "$ZDOTDIR/.zshenv" && "$ZDOTDIR/.zshenv" != "${(%):-%N}" ]]; then
  source "$ZDOTDIR/.zshenv"
fi
if [[ -r "$TERMATICA_SHELL_INTEGRATION" ]]; then
  source "$TERMATICA_SHELL_INTEGRATION"
fi
unset _termatica_original_zdotdir
