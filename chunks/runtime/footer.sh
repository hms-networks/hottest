set -a # We are using GNU timeout, it runs in new subprocesses, so we want all
       # functions and variables exported. Be aware that variable modifications
       # on child processes will not be seen on the parent.

printf "\n2.Validating/preparing the environment\n\n"

__STEP_TIMEOUTS=""
__build_step_timeouts     || { exit 1; }
readonly __STEP_TIMEOUTS="$__STEP_TIMEOUTS"
__clear_jenkins_workspace || { exit 1; }
__check_test_cases        || { exit 1; }
__check_dut_funcs         || { exit 1; }
__check_host_test_funcs   || { exit 1; }
__check_host_executables  || { exit 1; }
printf "\n3.Starting test sequence\n\n"
# Unused, but just to have the logs always contain the build number in case
# the graphs are generated offline.
test_measurement_add jenkins_build_number $BUILD_NUMBER

set +e # Tests decide themselves if they want to abort on failed commands.

readonly __TEST_SEQUENCE_STARTED=1
__step_timeout_parse_wrap __run_ifdef dut_power_off || { exit 1; }
__before_dut_power_on                               || { exit 1; }
__step_timeout_parse_wrap __run_ifdef dut_power_on  || { exit 1; }
__after_dut_power_on                                || { exit 1; }
__step_timeout_parse_wrap __run_ifdef dut_boot      || { exit 1; }
__check_dut_executables                             || { exit 1; }
__before_test_run                                   || { exit 1; }
__test_run
