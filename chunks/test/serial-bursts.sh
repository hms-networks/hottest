# This test uses a small C tool ("char-dev-rw") that is compiled both for the
# DUT and the host, to send arbitrary amounts of data in configurable burst.
#
# This test requires cross-compiling the C tool (char-dev-rw), so it requires a
# working toolchain on the device. For that the Jenkins job has to provide
# the "dut_source_cross_toolchain" function.

#|include <util/c-utils/char-dev-rw>
#|include <util/misc/locking>

function sb_get_stty_raw_mode_args() {
    # Convert from strings like "8N1" to stty arguments
    local port_mode="$1"
    local charbits="${port_mode:0:1}"
    local parity="${port_mode:1:1}"
    local stopbits="${port_mode:2:1}"
    local args=""

    if [[ $charbits -lt 5 ]] || [[ $charbits -gt 8 ]]; then
        errcho "Invalid character bits on testport_mode: $charbits"
        return 1
    fi
    args="cs${charbits}"
    case $parity in
        n)
            ;& # fallthrough bash-ism
        N)
            args="$args -parenb"
            ;;
        e)
            ;& # fallthrough bash-ism
        E)
            args="$args parenb -parodd"
            ;;
        o)
            ;& # fallthrough bash-ism
        O)
            args="$args parenb parodd"
            ;;
        *)
            errcho "Invalid parity on testport_mode: $parity"
            return 1
            ;;
    esac
    if [[ $stopbits -lt 1 ]] || [[ $stopbits -gt 2 ]]; then
        errcho "Invalid stop bits on testport_mode: $stopbits"
        return 1
    fi
    if [[ $stopbits -eq 1 ]]; then
        args="$args -cstopb"
    else
        args="$args cstopb"
    fi
    printf "raw -echo -echoe -echok $args min 0 time 1"
    return 0
}

function sb_get_receiver_timeout_us() {
    # Adding an extra 15% headroom on the minimum theoretical time and extra
    # 1.2 sec seconds for synchronization/run delays.
    local fp_seconds=$1
    echo "((($seconds * 1.15) + 1.2) * 1000000.) / 1" | bc
}

function sb_validate_timeout() {
    local timeout;
    timeout=$(get_step_timeout serial_bursts_test_run)
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    if [[ "$timeout" == 0 ]]; then
        return 0 # No timeout
    fi
    local total="2." # Assuming some time is spent outside the main loop.
    for rate in $serial_baudrates ; do
        local seconds;
        seconds=$(./char-dev-rw -c ${rate}:${serial_port_mode} ${serial_bursts})
        if [[ $? -ne 0 ]]; then
            return 1
        fi
        seconds=$(echo "$seconds" | grep "seconds" | sed "s|[^0-9\.]||g")
        local useconds=$(sb_get_receiver_timeout_us $seconds)
        # Adding two extra seconds for each loop run to account for script
        # run time.
        total=$(echo "(2 * ($useconds / 1000000.)) + $total + 2."| bc)
    done
    val=$(echo "$timeout <= $total" | bc)
    if [[ $val -eq 1 ]]; then
        errcho "ERROR: The configured timeout for \"test_run\" ($timeout sec) is less than the estimated time to complete the test based on the amount of data and speeds configured ($total sec). Failing early."
        return 1
    fi
    return 0
}

function serial_bursts_parameter_validation() {
    sb_get_stty_raw_mode_args ${serial_port_mode} > /dev/null || { return 1; }
    sb_validate_timeout || { return 1; }
}
add_step_before_dut_power_on serial_bursts_parameter_validation

function serial_bursts_test_run() {
    local stty_args=$(sb_get_stty_raw_mode_args ${serial_port_mode})
    # To be used for locking a shared-resource on the Tester(PC), e.g. a rs485
    # dongle or a rs232 serial port.
    if [[ ! -z "$tester_lock_name" ]]; then
        acquire_lock $serial_lock_name || { return 1; }
    fi

    for rate in $serial_baudrates ; do
        local stats=$(./char-dev-rw -c ${rate}:${serial_port_mode} ${serial_bursts})
        local seconds=$(echo "$stats" | grep "seconds" | sed "s|[^0-9\.]||g" )
        local bytes=$(echo "$stats" | grep "bytes" | sed "s|[^0-9\.]||g" )
        local micros=$(sb_get_receiver_timeout_us $seconds)

        echo "Testing ${rate}bps. ${micros} usec timeout."
        stty -F $serial_tester_dev $rate $stty_args
        dut_cmd "stty -F $serial_dut_dev $rate $stty_args"

        echo "Testing RX"
        (sleep 0.3; ./char-dev-rw -F $serial_tester_dev ${serial_bursts}) &
        local childpid=$!
        dut_cmd "./char-dev-rw -F $serial_dut_dev -r $bytes $micros"
        test_case_set "serial_burst_rx_${rate}" $?
        wait $childpid

        echo "Testing TX"
        (sleep 0.3; dut_cmd "./char-dev-rw -F $serial_dut_dev ${serial_bursts}") &
        childpid=$!
        ./char-dev-rw -F $serial_tester_dev -r $bytes $micros
        test_case_set "serial_burst_tx_${rate}" $?
        wait $childpid
    done
}
for rate in $serial_baudrates ; do
    declare_test_cases "serial_burst_rx_${rate}" "serial_burst_tx_${rate}"
done
add_step_to_test_run serial_bursts_test_run

function serial_bursts_test_teardown() {
    stty -F $serial_tester_dev 115200 sane
}
add_step_after_test_run serial_bursts_test_teardown
