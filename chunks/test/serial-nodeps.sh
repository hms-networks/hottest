#|include <util/misc/locking>

function serial_nodeps_test_run() {
    # To be used for locking a shared-resource on the Tester(PC), e.g. a rs485
    # dongle or a rs232 serial port.
    if [[ ! -z "$tester_lock_name" ]]; then
        acquire_lock $tester_lock_name || { return 1; }
    fi
    #TODO: Send strings can be the output of "seq 1 $VALUE"
    echo -n "Sending a string to check" > ./send-data

    for rate in $test_baudrates ; do
        #RX
        stty -F $tester_dev $rate raw -echo -echoe -echok min 1 time 0
        # Receive for either SENDATA.length or 10 sec.
        dut_cmd "stty -F $dut_dev $rate raw -echo -echoe -echok min ${#send_data} time 100"
        dut_cmd "nohup cat $dut_dev > /tmp/received &"
        sleep 0.3
        cat ./send-data > $tester_dev
        sleep 0.3
        dut_cmd \"sync; killall cat\"
        local rcvdata=$(dut_cmd "cat /tmp/received")
        echo -n "$rcvdata" > ./received-dut-data
        diff -u ./send-data ./received-dut-data > /dev/null
        test_case_set "serial_rx_${rate}" $?

        #TX
        stty -F $tester_dev $rate raw -echo -echoe -echok min ${#send_data} time 100
        dut_cmd "stty -F $dut_dev $rate raw -echo -echoe -echok min 1 time 0"
        cat $tester_dev > ./received-tester-data &
        local cat_pid=$!
        sleep 0.3 # grace period
        dut_cmd "cat /tmp/received > $dut_dev"
        sleep 0.3 # grace period
        kill $cat_pid # in case the test failed
        diff -u ./send-data ./received-tester-data > /dev/null
        test_case_set "serial_tx_${rate}" $?
    done
}
for rate in $test_baudrates ; do
    declare_test_cases "serial_rx_${rate}" "serial_tx_${rate}"
done
add_step_to_test_run serial_nodeps_test_run

function serial_nodeps_test_teardown() {
    stty -F $tester_dev 115200 sane
}
add_step_after_test_run serial_nodeps_test_teardown

