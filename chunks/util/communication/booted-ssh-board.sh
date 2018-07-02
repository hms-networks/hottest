# Communication functions for a board that communicates through SSH.
#
# "dut_ssh_user", "dut_ssh_extra_args" and "dut_ssh_scp_extra_args" and
# "dut_ssh_sshpass_args" are test parameteters becase they might change
# between firmware versions.

# DUT_SSH_HOSTNAME is a board parameter because it's independent on the loaded
# firmware. It just depends on the testing setup.

#|board-require-env <DUT_SSH_HOSTNAME>

add_required_host_executables ssh scp sshpass

readonly DUT_SSH_HOSTUSER="${dut_ssh_user}@${DUT_SSH_HOSTNAME}"
readonly DUT_SSH_SCP="scp ${dut_ssh_scp_extra_args}"
readonly DUT_SSH_SSH="ssh ${dut_ssh_ssh_extra_args}"

function dut_ssh_run_command() {
    local cmd="$1"
    if [[ "$cmd" =~ [[:space:]]-i[[:space:]] ]]; then
        # command has -i (pubkey)
        $cmd
    else
        sshpass ${dut_ssh_sshpass_args} $cmd
    fi
}

function dut_cmd() {
    dut_ssh_run_command "$DUT_SSH_SSH ${DUT_SSH_HOSTUSER} $@"
}

function dut_put() {
    dut_ssh_run_command "$DUT_SSH_SCP \"$1\" ${DUT_SSH_HOSTUSER}:\"$2\""
}

function dut_get() {
    dut_ssh_run_command "$DUT_SSH_SCP ${DUT_SSH_HOSTUSER}:\"$1\" \"$2\""
}
