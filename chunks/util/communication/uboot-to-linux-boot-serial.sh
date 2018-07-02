# Boot functions for a board that has both UBoot and Linux terminals on the
# (same) serial port.
#
# TODO: Ability to specify user and password/detect prompt. Now is a
# passwordless root.

#|board-require-env <DUT_TTY>
#|board-require-env <DUT_TTY_BAUDRATE>

function dut_boot() {
    $__UBOOT_BOOT_LOGIN -s $DUT_TTY -b $DUT_TTY_BAUDRATE -l "${login_prompt_match_text}" --boot-cmd "reset"
    local ret=$?
    if [[ $ret -eq 0 ]]; then
        sleep 1 # There is a delay before the prompt is available.
    fi
    return $ret
}
