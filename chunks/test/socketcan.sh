# Test for SocketCAN. Deliberately assumes a dedicated silent bus.
#
# This test requires the PC to have a SocketCAN capable CAN dongle. The writer
# of this used an IXXAT USB-to-CAN v2 compact.
#
# This test requires the Jenkins user to be able to bring the local CAN network
# interface up and down. Unfortunately the permission rules for the network
# subsystem apply, so permissions can't be set from a fine grained per-device
# udev rule.
#
# The next easiest alternative that didn't require too coarse permissions or
# clever setups was to just require adding "ip link set <CANDEV>" to
# sudoers.
#
# On the DUT it is assumed that the running user has rights for configuring the
# interface.
#

#|include <util/c-utils/hexseq>
#|include <util/misc/misc>
#|include <util/misc/locking>

function socketcan_nic_cfg() {
    local wrapper=$1
    local nic=$2
    local rate=$3
    $wrapper ip link set $nic down
    $wrapper ip link set $nic type can bitrate $rate
    $wrapper ip link set $nic up
}

function socketcan_test_run() {
    set -e
    # To be used for locking a shared-resource on the Tester(PC), e.g. a CAN
    # dongle
    if [[ ! -z "$can_lock_name" ]]; then
        acquire_lock $can_lock_name || { return 1; }
    fi
    local canid="42A"
    local last=$((${can_frame_count} - 1))

    # Generating the expected output of the third column on candump.
    ./hexseq -buw 16 0 $last | sed "s|\(.*\)|$canid#\1|g" > expected

    for rate in $can_test_baudrates ; do
        echo "Testing ${rate}bps. ${can_frame_count} frames."

        socketcan_nic_cfg onsudoers_cmd $can_tester_nic $rate
        socketcan_nic_cfg dut_cmd $can_dut_nic $rate

        echo "Testing RX"
        rm -f candump*.log got
        dut_cmd 'rm -f candump*.log'
        (sleep 0.3; cangen ${can_tester_nic} -I $canid -D i -L 8 -g 1 -n ${can_frame_count}) &
        local childpid=$!
        dut_cmd "candump ${can_dut_nic} -ln ${can_frame_count} -T 2500 > /dev/null"
        local log
        log=$(dut_cmd 'ls candump*.log')
        dut_get $log .
        cat $log | grep "${can_dut_nic} $canid" | awk '{print $3}' > got
        local return_value;
        noabort return_value diff -u expected got
        test_case_set "socketcan_rx_${rate}" $return_value
        wait $childpid

        echo "Testing TX"
        rm -f candump*.log got
        (sleep 0.3; dut_cmd "cangen ${can_dut_nic} -I $canid -D i -L 8 -g 1 -n ${can_frame_count}") &
        childpid=$!
        candump ${can_tester_nic} -ln ${can_frame_count} -T 2500 > /dev/null
        log=$(ls candump*.log)
        cat $log | grep "${can_tester_nic} $canid" | awk '{print $3}' > got
        noabort return_value diff -u expected got
        test_case_set "socketcan_tx_${rate}" $return_value
        wait $childpid
    done
}
for rate in $can_test_baudrates ; do
    declare_test_cases "socketcan_rx_${rate}" "socketcan_tx_${rate}"
done
add_step_to_test_run socketcan_test_run

function socketcan_interfacedown() {
    onsudoers_cmd ip link set $can_tester_nic down
}
add_step_before_exit socketcan_interfacedown
