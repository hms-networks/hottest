# Communication functions for a board that communicates on the serial port.

#|board-require-env <DUT_TTY>
#|board-require-env <DUT_TTY_BAUDRATE>

# Serio requires bash, this is just documentation: doing the check itself
# requires the communication to be working, which it won't if the shell isn't
# bash (it actually may work, but it's untested).
add_required_dut_executables bash

function dut_cmd() {
    $__SERSH -T 0.12 -b $DUT_TTY_BAUDRATE "root@$DUT_TTY" "$@"
    local ret=$?
    sleep 0.03 # Serio isn't very stable
    return $ret
}

function dut_put() {
    # Putting files has no deps on the DUT
    #
    #  - Remote system shell built-ins or programs:
    #  file get --basic  :  cat, echo
    #  file get          :                uuencode
    #  file get --md5sum :  stat, md5sum, uuencode
    #  file put          :  [ -d ], echo, stty

    local dev=$(echo "$DUT_TTY" | sed "s|/dev/||g")
    $__SERCP -T 0.12 -b $DUT_TTY_BAUDRATE "$1" "dummyusr@$dev:$2"
}

function dut_get() {
    # Note that sercp has dependencies on the host when not run with "--basic".
    # As its output says:
    #
    #  - Remote system shell built-ins or programs:
    #  file get --basic  :  cat, echo
    #  file get          :                uuencode
    #  file get --md5sum :  stat, md5sum, uuencode
    #  file put          :  [ -d ], echo, stty
    #
    # As of now we autodetect. If this is slow this code will need to be
    # optimized

    local MODE="--basic"
    local UTILS=$(dut_cmd which stat md5sum uuencode)
    if [[ "$UTILS" =~ "uuencode" ]]; then
        MODE=""
        if [[ "$UTILS" =~ "stat" ]] && [[ "$UTILS" =~ "md5sum" ]]; then
            MODE="--md5sum"
        fi
    fi
    if [[ "$MODE" != "--md5sum" ]]; then
        errcho "WARNING: Copying files from this device is done unsafely. Safe copying requires stat, md5sum and uuencode."
    fi
    local dev=$(echo "$DUT_TTY" | sed "s|/dev/||g")
    $__SERCP $MODE -T 0.12 -b $DUT_TTY_BAUDRATE "dummyusr@$dev:$1" "$2"
    local ret=$?
    if [[ ret -ne 0 ]]; then
        return $ret
    fi
    if [[ $MODE = "--basic" ]]; then
        # At least on basic mode serio succeeds even if the file doesn't exist.
        # Workarounding.
        local dstfile=$2
        if [[ -d "$2" ]]; then
             dstfile="$2/$(basename $1)"
        fi
        if [[ ! -f "$dstfile" ]]; then
            errcho "dut_get: Unable to get \"$1\" to \"$2\". Do both paths exist?"
            return 1
        fi
    fi
    return $ret
}
