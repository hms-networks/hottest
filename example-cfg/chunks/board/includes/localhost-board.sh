#|board-require-env <DUMMY_BOARD_ADDRESS>

# The previous "#|board-require-env" directive will trigger a generation time
# check that the board running this has a "DUMMY_BOARD_ADDRESS" environment
# variable defined.

# This "mktemp "statement runs before all the test functions are launched by,
# the framework, be aware that each of the functions will be called on its own
# process. Modifications on variables on the global scope aren't seen by the
# other test functions.
readonly LOCALHOST_BOARD_FILESYSTEM=$(mktemp -d)
readonly LASTDIR_FILE=$LOCALHOST_BOARD_FILESYSTEM/etc/dut_lastdir

# Adding a fake function to create a dummy fs on the tempfolder.
function setup_fake_fs() {
    mkdir -p $LOCALHOST_BOARD_FILESYSTEM/etc
    mkdir -p $LOCALHOST_BOARD_FILESYSTEM/bin
    mkdir -p $LOCALHOST_BOARD_FILESYSTEM/var
    mkdir -p $LOCALHOST_BOARD_FILESYSTEM/opt
    mkdir -p $LOCALHOST_BOARD_FILESYSTEM/home/root
    echo "$LOCALHOST_BOARD_FILESYSTEM/home/root" > $LASTDIR_FILE
    echo "Fake filesystem on: $LOCALHOST_BOARD_FILESYSTEM"
    if which tree > /dev/null; then
        tree $LOCALHOST_BOARD_FILESYSTEM
    fi
}
add_step_before_dut_power_on setup_fake_fs

# Always removing our fake filesystem
function remove_fake_fs() {
    rm -rf $LOCALHOST_BOARD_FILESYSTEM
}
add_step_before_exit remove_fake_fs #will always run no matter what

# "dut_power_on", "dut_power_off" and "dut_boot" are optional functions
# for the test to provide.
#
# If they aren't defined the framework just assumes that the DUT is already
# booted and logged in (being logged in is important for serial communications,
# but not for ssh).

function dut_power_on() {
    echo "Powering on: $DUMMY_BOARD_ADDRESS"
}

function dut_power_off() {
    echo "Powering off: $DUMMY_BOARD_ADDRESS"
}

function dut_boot() {
    # Real implementations of this function have to return when the device
    # is ready to take commands. E.g.:
    #
    # -serial connections: The device is booted and logged in.
    # -ssh connections: The device responds to ssh commands.
    echo "Booting device: $DUMMY_BOARD_ADDRESS"
}

# "dut_cmd", "dut_put" and "dut_get" are mandatory to be implemented on
# all boards: no testing is possible without being able to run commands and copy
# files.
#
# Note that these transports may be provided by the framework for the user to
# be included, so e,g. you would do "#|include <board/booted-serial-board>"
#
function dut_cmd() {
    # This implementation should run commands on the remote device. As we are
    # running on the local PC we just run the command here.
    #
    # Notice that functions run in a sandboxed bash environment (subprocess), so
    # the modifications are only local and it's impossible to share shell state.

    PATH="$PATH:$LOCALHOST_BOARD_FILESYSTEM/bin" # sandboxed env! No side effects outside
    pushd . > /dev/null
    cd $(cat $LASTDIR_FILE) # sandboxed env! using the filesystem...
    $@
    local ret=$?
    local dut_dir="$PWD"
    popd > /dev/null
    echo "$dut_dir" > $LASTDIR_FILE # sandboxed env! using the filesystem...
    return $ret
}

function dut_put() {
    local DST=$(echo "$LOCALHOST_BOARD_FILESYSTEM/$2" | sed 's|/\+|/|g' )
    cp "$1" "$DST"
}

function dut_get() {
    local SRC=$(echo "$LOCALHOST_BOARD_FILESYSTEM/$1" | sed 's|/\+|/|g' )
    cp "$SRC" "$2"
}
