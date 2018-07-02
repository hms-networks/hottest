# A file including hard to categorize small functions.

function noabort() {
    # run command without +e set. Assumes that set -e was set before. The result
    # is placed on the variable name passed on the first parameter.
    set +e
    ${@:2}
    eval $1=$?
    set -e
}

function onsudoers_cmd() {
    # Runs a command that is assumed to be configured as passwordless on sudoers.
    local ret
    local f=$(mktemp)
    # Reminder:
    # "2>" : redirects stderr
    # >(): Redirects to a FIFO attached to a process's stdin.
    # >&2: tee itself outputs to stdout. Redirect all output to stderr.
    if ! sudo -n "$@" 2> >(tee $f >&2); then
        ret=${PIPESTATUS[0]} # Otherwise we get the exit code of tee (last).
        if cat $f | grep -q '^sudo.*password'; then
            local program;
            program=$(which $(echo "$@" | cut -d ' ' -f 1))
            if [[ $? -eq 0 ]]; then
                 errcho "\"$@\" wasn't passwordless configured. A sample rule for this on sudoers: $USER ALL=(ALL) NOPASSWD:$program *"
            else
                 errcho "\"$@\": Unknown executable."
            fi
        fi
    else
        ret=0
    fi
    rm -f $f
    return $ret
}

function heredoc_define() {
    # use to define heredoc to variables. E.g:
    #
    #   heredoc_define DSTVAR << 'EOF'
    #   contents
    #   EOF
    IFS='\n' read -rd '' $1 || true;
}
