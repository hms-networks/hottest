function helloworld_setup() {
    echo "Setting up test"
}
add_step_before_test_run test_setup

function helloworld_run() {
    # "helloworld_text" comes as a jenkins variable from the JSON definition
    dut_cmd echo "${helloworld_text}"
    test_case_set helloworld $?
}
add_step_to_test_run helloworld_run
declare_test_cases helloworld

function helloworld_teardown() {
    echo "Tearing down test"
}
add_step_after_test_run helloworld_teardown
