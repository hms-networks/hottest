# "test_result" is a Jenkins job parameter defined on the JSON file. Note that
# we can't validate it on the global scope and just exit prematurely, otherwise
# the framework won't be able to know which test cases failed.
function validate_jenkins_variables() {
    if [[ "${test_result}" -ne 0 ]] && [[ "${test_result}" -ne 1 ]]; then
        errcho "The \"test_tesult\" parameter can only be either 0 (success) or 1 (failure)"
        return 1
    fi
}
add_step_before_dut_power_on validate_jenkins_variables

# We require an executable on the DUT (device under test). The test will bail
# out and a message will be printed if "cc" is not present. Note that this
# function can only be used on the Global scope (before test steps (functions)
# start running)
add_required_host_executables cc

# We add a task to do before the test even starts (before powering on), which is
# compiling a dummy helloworld application. Notice that the crosscompile module
# (util/crosscompilation/crosscompile) isn't used because this dummy example is
# going to run on the local host.
function crosscompile_localhost_helloworld() {
    printf "#include <stdio.h>\nint main(void) { printf (\"${echo_str}\\\n\"); return 0; }\n" > hello.c
    cc hello.c -o hello
}
add_step_before_dut_power_on crosscompile_localhost_helloworld

# We transfer the helloworld app that we "crosscompiled" above to the device
# once we know it's booted.
function transfer_localhost_helloworld() {
    dut_put "hello" "/bin"
}
add_step_before_test_run transfer_localhost_helloworld

# We add a dummy validation function before running the test itself, so we don't
# clutter the test function with validation. This is just cosmetic.
function dummy_test_validation() {
    echo "Dummy test validation"
    if ! dut_cmd "which hello" > /dev/null; then
        errcho "Dummy dut copying failed"
        return 1
    fi
}
add_step_before_test_run dummy_test_validation

# We declare the test cases that this test contains
#
# Test case pre-declaration on the global scope is required. This is verbose
# but done by design:
#
# 1. As the Jenkins job only succeeds when all the tests PASS, It allows to
#    return from any function at any point without caring about return codes
#    while still generating a valid test report with all cases marked as
#   "not run".
# 2. The framework can also generate reports in the presence of breaks/signals.
# 3. This could be done on the preprocessing utility that generates tests
#    (gen/sync), but then it wouldn't allow bash substitutions on test
#    names (test with variable test case counts, as e.g. the serial port
#    tests, takes the baudrates to test as parameters).
declare_test_cases "hello_from_c" "dummy_echo" "some_test" "sleep"

function dummy_test_run() {
    # Testing the DUT (device under test) filesystem.
    dut_cmd hello # dut_cmd runs a shell command on the DUT
    test_case_set hello_from_c $?

    # "echo_str" comes as a jenkins build job paramter on the .json part of
    # this chunk.
    dut_cmd echo "${echo_str}" # dut_cmd runs a shell command on the DUT
    test_case_set dummy_echo $?

    local MSG=""
    if [[ ${some_test_result} -ne 0 ]]; then
        MSG="Failed by passed parameter: \"${some_test_result}\""
    fi
    # "some_test_result" comes as a jenkins build job paramter on the .json part
    # of this chunk.
    test_case_set some_test ${some_test_result} "$MSG"

    sleep ${sleep_seconds_fp}
    test_case_set sleep $?

    # Some random measurements. These generate some graphs on the artifacts.
    test_measurement_add "measurement-1" $((1 + RANDOM % 50))
    test_measurement_add "measurement-2" $((1 + RANDOM % 50))
}
# "test_run": Functions are understood as actual tests (e.g. returning nonzero
# from them don't interrupt the test job). We add dymmy_test_run.
add_step_to_test_run dummy_test_run

function dummy_test_teardown() {
    echo "Cleaning up. \"dummy_test_run\" return code was: $1"
}
# "after_test_run" functions run only if the test run independently of the
# test result as they are cleanup functions.
add_step_after_test_run dummy_test_teardown
