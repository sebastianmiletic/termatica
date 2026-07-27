if status is-interactive; and not set -q TERMATICA_SHELL_INTEGRATION_ACTIVE
    set -gx TERMATICA_SHELL_INTEGRATION_ACTIVE 1

    function _termatica_prompt --on-event fish_prompt
        set -l command_status $status
        printf '\e]133;D;%d\a\e]133;A\a\e]7;file://%s%s\a' \
            $command_status (hostname) $PWD
    end

    function _termatica_preexec --on-event fish_preexec
        printf '\e]133;C\a'
    end
end
