# Utility functions and prevalidation

set -a # We are using GNU timeout, it runs in new subprocesses, so we want all
       # functions and variables exported. Be aware that variable modifications
       # on child processes will not be seen on the parent.

set -e # We don't allow failing on the global scope (ONLY). All user functions
       # haven't the -e enabled by default.

readonly __TEST_TOOLS=$JENKINS_HOME/hottest
readonly __PERSISTENT_JOB_DIR=$JENKINS_HOME/userContent/hottest/$JOB_NAME
readonly __SERSH=$__TEST_TOOLS/sersh
readonly __SERCP=$__TEST_TOOLS/sercp
readonly __UBOOT_BOOT_LOGIN=$__TEST_TOOLS/uboot-boot-and-login.py # TODO this SLP deploy tool has to be removed from the framework
readonly __LOG_PARSER=$__TEST_TOOLS/log-parser.py
readonly __LOG_PARSER_MSGS_FILE=log-parser-msgs

__TEST_SEQUENCE_STARTED=0

printf "\n1.On the script's local scope/definition time \n\n"

#### Framework functions for test usage. Stable API ####
function add_required_host_executables() {
    # Adds the requirement for some executables to be installed on the
    # Host/Server machine.
    #
    # This has to be called on the global scope before the testing starts.
    #
    # It allows documenting the binary dependencies on the host and failing
    # early before doing any operation with the DUT.
    #
    __check_globalscope_only add_required_host_executables || { exit 1; }
    __REQUIRED_HOST_EXECUTABLES="$__REQUIRED_HOST_EXECUTABLES $@"
}

function add_required_dut_executables() {
    # Adds the requirement for some executables to be installed on the
    # DUT machine.
    #
    # This has to be called on the global scope before the testing starts.
    #
    # It allows documenting the binary dependencies on the host and failing
    # early before doing any operation with the DUT.
    #
    # Note that this is just a convenience function, as it needs the machine
    # to be booted and with a connection to the console.

    __check_globalscope_only add_required_dut_executables || { exit 1; }
    __REQUIRED_DUT_EXECUTABLES="$__REQUIRED_DUT_EXECUTABLES $@"
}

function add_step_before_dut_power_on() {
    # Adds a function to run before powering on the device. Functions before
    # powering on the device can be used e.g. to compile files, fetch binaries
    # from the network etc.
    #
    # An optional timeout paremeter with GNU timeout format can be passed. If
    # the timeout is not passed the timeout value will be taken from the
    # "__step_timeouts" Jenkins build job variable, which supports adding
    # custom names.

    __add_user_func add_step_before_dut_power_on __BEFORE_DUT_POWER_ON_STEPS $1 $2
}

function add_step_after_dut_power_on() {
    # Adds a function to run after powering on the device. Functions after
    # powering on the device can be used e.g. flash bootloaders and operative
    # systems
    #
    # An optional timeout paremeter with GNU timeout format can be passed. If
    # the timeout is not passed the timeout value will be taken from the
    # "__step_timeouts" Jenkins build job variable, which supports adding
    # custom names.

    __add_user_func add_step_after_dut_power_on __AFTER_DUT_POWER_ON_STEPS $1 $2
}

function add_step_before_test_run() {
    # Adds a function to run before running the test; after the device has been
    # booted. This is useful to prepare test environments, validate, etc.
    #
    # An optional timeout paremeter with GNU timeout format can be passed. If
    # the timeout is not passed the timeout value will be taken from the
    # "__step_timeouts" Jenkins build job variable, which supports adding
    # custom names.

    __add_user_func add_step_before_test_run __BEFORE_TEST_RUN_STEPS $1 $2
}

function add_step_to_test_run() {
    # Adds a test function to run.
    #
    # An optional timeout paremeter with GNU timeout format can be passed. If
    # the timeout is not passed the timeout value will be taken from the
    # "__step_timeouts" Jenkins build job variable, which supports adding
    # custom names.

    __add_user_func add_step_to_test_run __TEST_RUN_STEPS $1 $2
}

function add_step_after_test_run() {
    # Adds a function to run after running the test. These functions run always
    # independently of the test result, which is passed to the function as the
    # first parameter.
    #
    # An optional timeout paremeter with GNU timeout format can be passed. If
    # the timeout is not passed the timeout value will be taken from the
    # "__step_timeouts" Jenkins build job variable, which supports adding
    # custom names.

    __add_user_func add_step_after_test_run __AFTER_TEST_RUN_STEPS $1 $2
}

function add_step_before_exit() {
    # Adds a function to run after power off. These functions run always before
    # exiting.
    #
    # An optional timeout paremeter with GNU timeout format can be passed. If
    # the timeout is not passed the timeout value will be taken from the
    # "__step_timeouts" Jenkins build job variable, which supports adding
    # custom names.

    __add_user_func add_step_before_exit __BEFORE_EXIT_STEPS $1 $2
}

__TEST_CASES=""
function declare_test_cases() {
    # Adds all string arguments as test cases.
    #
    # Testcases have to be declared before running, so in case the whole
    # Jenkins run blocks and times out the framework can know that a test
    # didn't run.
    #
    # Test case names need to have the same format than C variables.
    #
    # Test cases have to added on the global scope, outside of any function
    # launched by the framework (e.g. "test_setup" see footer.sh to see all
    # the test function launch sequence)
    #
    # You developer, don't try to deprecate this by autogenerating the
    # __TEST_CASES variable by detecting calls to "test_case_set" at
    # generation-time. The "declare_test_cases" arguments can be runtime
    # variables (See e.g. the "serial-bursts" and "serial-nodeps" chunks).

    __check_globalscope_only declare_test_cases || { exit 1; }
    for testcase in "$@"; do
        if ! is_testname_valid "$testcase"; then
            errcho "Invalid test case name: \"$testcase\""
            exit 1
        fi
        if echo "$__TEST_CASES" | grep "$testcase"; then
            errcho "Duplicated test name: $testcase"
            exit 1
        fi
        __TEST_CASES=$(echo "$__TEST_CASES $testcase" | xargs) #xargs for space trimming
    done
}

function test_case_set() {
    # Sets the test result as PASS/FAIL based on the numeric value of the second
    # parameter: O = PASS, nonzero = FAIL
    #
    # The third parameter is a comment to be used on failing tests.
    #
    if [[ $# -lt 2 ]]; then
        __test_case_set_raw "$1" "$2"
        return $?
    fi
    local ret
    [[ $2 -ne 0 ]] && ret=FAIL || ret=PASS
    __test_case_set_raw "$1" "$ret" "$3"
}

function test_case_set_not() {
    # Sets the test result as PASS/FAIL based on the numeric value of the second
    # parameter: O = FAIL, nonzero = PASS
    #
    # The third paramter is a comment to be used on failing tests.
    #
    if [[ $# -ne 2 ]]; then
        __test_case_set_raw "$1" "$2"
        return $?
    fi
    local ret
    [[ $2 -eq 0 ]] && ret=FAIL || ret=PASS
    __test_case_set_raw "$1" "$ret" "$3"
}

function test_measurement_add() {
    # Adds a measurement with a textual key and a float value
    local key=$1
    local val=$2
    if [[ $# -ne 2 ]]; then
        errcho "Measurements do need a string key and a numeric value."
        return 1
    fi
    if ! is_testname_valid "$key"; then
        errcho "Invalid measurement key name: \"$key\""
        return 1
    fi
    __emit_log_parser_msg SAMPLE $key $val
}

function get_step_timeout() {
    # Gets the configured timeout in GNU timeout format for the passed function.
    # It always returns the value in floating point format seconds without
    # units.
    #
    # A timeout of 0 means that there is no timeout, 0 is always returned on
    # fixed point format, so comparisons can be done just using shell operators.

    local function_name=$1
    local timeout;
    timeout=$(kvl_get_value_for_key "${__STEP_TIMEOUTS}" "^${function_name}\$")
    local ret=$?
    if [[ $ret -eq 2 ]]; then
        errcho "get_step_timeout: Invalid __STEP_TIMEOUTS. This was either a bug or the user manually tampering with __STEP_TIMEOUTS"
        return 1
    fi
    if [[ $ret -eq 1 ]]; then
        errcho "get_step_timeout: Unable to get timeout for unregistered function: $function_name"
        return 1
    fi
    local val=$(echo "$timeout == 0" | bc)
    if [[ "$val" -eq 1 ]]; then
        echo "0"
    else
        echo "$timeout"
    fi
}

#### Utility functions used by the header (Stable API)####
function is_func_defined() {
    # check for a bash function definition
    declare -f -F "$1" > /dev/null
}

function are_funcs_defined() {
    # check for many bash function definitions. Output missing funcs on stdout
    local undefined=""
    for func in $@; do
        if ! is_func_defined $func; then
            undefined="$func $undefined"
        fi
    done
    if [[ ! -z "$undefined" ]]; then
        echo "$undefined"
        return 1
    fi
}

function are_all_or_no_funcs_defined() {
    # check for many or no bash function definitions. Output missing funcs on
    # stdout
    local req=$@
    local missing; #Bash pitfall local/export sweeps the error code
    missing=$(are_funcs_defined $req)
    if [[ "$?" -ne 0 ]]; then
        if [[ $(echo "$req" | wc -w) -ne $(echo "$missing" | wc -w) ]]; then
            echo "$missing"
            return 1
        fi
    fi
}

function errcho() {
    # echo to stderr
    echo "$@" 1>&2
}

function is_testname_valid() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_\-]*$ ]]
}

function match_in_regex_list() {
    # matches a word in a list of regexes
    local list="$1"
    local word="$2"
    for regex in $list; do
        if [[ $word =~ $regex ]]; then
            return 0
        fi
    done
    return 1
}

function kvl_get_value_for_key() {
    # Tries to gets the value of a key contained on a space-separated
    # key-value list (kvl) where each kv element is separated by the equal
    # sign and prints it on stdout if found.
    #
    # Spaces aren't allowed either on the list keys or values or on the regex,
    # as they are used as separators
    #
    # The first parameter is the list. The second the key to search for.
    #
    # Returns 0: found, 1: not found, 2: parse error
    #
    # Example:
    #  > sskv_list_get_value_for_key "key1=value1 key2=value2" "^key2$"
    #  >> value2
    #
    local list=$(echo "$1" | xargs | tr " " "\n")
    local regex=$2

    for kv in $list; do
        if [[ "$(echo "$kv" | tr -cd '=' | wc -c)" -ne 1 ]]; then
            # '=' char was found either 0 or more than 1 times
            errcho "Invalid key-value pair on list: \"$kv\". List dump: \"$1\"."
            return 2
        fi
        local key=$(echo "$kv" | cut -d '=' -f 1)
        local val=$(echo "$kv" | cut -d '=' -f 2)
        if [[ -z "$val" ]]; then
            errcho "Empty value on list: \"$kv\". List dump: \"$1\"."
            return 2
        fi
        if [[ $key =~ $regex ]]; then
            echo "$val"
            return 0
        fi
    done
    return 1
}

#### Internal functions (unstable APIs)####
function __check_globalscope_only() {
    if [[ $__TEST_SEQUENCE_STARTED -ne 0 ]]; then
        errcho "ERROR: \"$1\" can only be used on the global scope."
        return 1
    fi
}

function __test_case_set_raw() {
    # Sets the test result as a RAW string. The tool that parses the logs will
    # need to understand what you write.
    if [[ $# -lt 2 ]]; then
        errcho "\"__test_case_set_raw\" needs the test name and the result passed as parameters"
        return 1
    fi
    if [[ $# -gt 3 ]]; then
        errcho "\"__test_case_set_raw\" received more than three parameters"
        return 1
    fi
    if ! echo "$__TEST_CASES" | tr " " "\n" | grep -q "^$1\$" ; then
        errcho "Test case was not declared: ${1}. Use \"declare_test_cases\" to declare it."
        return 1
    fi
    if [[ $__TEST_SEQUENCE_STARTED -eq 0 ]]; then
        errcho "WARNING: \"test_case_set*\" functions can't be called on the global scope. Ignored"
        return 1
    fi
    __emit_log_parser_msg "CASE" "$1" "$2" "$3"
}

function __check_test_cases() {
    if [[ $(echo "__TEST_CASES" | wc -w) -lt 1 ]]; then
        errcho "No test cases defined. Define your test cases with \"declare_test_cases\"."
        return 1
    fi
    __emit_log_parser_msg "CASE_ENUM" "$__TEST_CASES"
}

function __check_dut_funcs() {
    local funcs="dut_cmd dut_get dut_put"
    local missing; #Bash pitfall local/export sweeps the error code
    missing=$(are_funcs_defined $funcs)
    if [[ "$?" -ne 0 ]]; then
        errcho "Mandatory functions missing: $funcs"
        return 1
    fi

    funcs="dut_power_off dut_power_on dut_boot"
    missing=$(are_all_or_no_funcs_defined $funcs)
    if [[ "$?" -ne 0 ]]; then
        errcho "This function group needs to be defined all together: \"$funcs\". Missing: \"$missing\""
        return 1
    fi
}

function __run_def() {
    # Runs a test step that is known to be defined
    local func=$1
    local timeout=$2
    local bashflags=""

    if ! is_func_defined $func; then
        errcho "Function $func is not defined"
        return 1
    fi
    if match_in_regex_list "${__step_skip_filter}" $func; then
        echo "Step \"$func\" was present on \"__step_skip_filter\", skipping"
        return 0
    fi
    if [[ "$__verbose" -ne 0 ]]; then
        bashflags="-x"
    fi
    if [[ -z "$timeout" ]]; then
        timeout="0"
    fi
    echo "Running step: \"$func\". Timeout: $timeout seconds"
    # REMINDER ${@:3} passes all parameters except the first two
    timeout $timeout bash $bashflags -c "$func ${@:3}"
    local ret=$?
    if [[ "$ret" -eq 124 ]]; then
        errcho "Step \"$func\" timed out"
    fi
    return $ret
}

function __run_ifdef() {
    # Runs a test step if it's defined
    local func=$1
    local timeout=$2

    if is_func_defined $func; then
        __run_def $func $timeout
    else
        echo "Running step: $func -> Skipped. Not defined."
    fi
}

function __step_timeout_parse_wrap() {
    local run_call_type=$1
    local func=$2
    local timeout
    local ret
    timeout=$(get_step_timeout $func)
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    # REMINDER ${@:2} passes all parameters except the first two
    $run_call_type $func $timeout ${@:3}
}

function __add_user_func() {
    local caller=$1
    local storing_var=$2
    local user_func=$3
    local timeout=${4-unset}

    __check_globalscope_only $caller || { exit 1; }
    if ! is_func_defined $user_func; then
        errcho "WARNING: \"$caller\": Undefined function \"$user_func\"."
        exit 1
    fi
    # delimiting the func timeout kv by ";"
    eval $storing_var=\"\$$storing_var ${user_func}\;${timeout}\"
}

function __run_user_added_funcs() {
    local func_n_times="$1"
    local return_on_failure=$2

    for func_n_time in $func_n_times; do
        local func=$(echo "$func_n_time" | cut -d ';' -f 1)
        # REMINDER ${@:3} passes all parameters except the first and second
        __step_timeout_parse_wrap __run_def $func ${@:3}
        local ret=$?
        if [[ $ret -ne 0 ]] && [[ $return_on_failure -ne 0 ]]; then
            return $ret
        fi
    done
    return 0
}

__BEFORE_DUT_POWER_ON_STEPS=""
function __before_dut_power_on() {
    __run_user_added_funcs "$__BEFORE_DUT_POWER_ON_STEPS" 1 $@
}

__AFTER_DUT_POWER_ON_STEPS=""
function __after_dut_power_on() {
    __run_user_added_funcs "$__AFTER_DUT_POWER_ON_STEPS" 1 $@
}

__TEST_RUN_REACHED=0
__BEFORE_TEST_RUN_STEPS=""
function __before_test_run() {
    __run_user_added_funcs "$__BEFORE_TEST_RUN_STEPS" 1 $@
}

__TEST_RUN_STEPS=""
function __test_run() {
    __TEST_RUN_REACHED=1
    __run_user_added_funcs "$__TEST_RUN_STEPS" 0 $@
}

__AFTER_TEST_RUN_STEPS=""
function __after_test_run() {
    __run_user_added_funcs "$__AFTER_TEST_RUN_STEPS" 0 $@
}

__BEFORE_EXIT_STEPS=""
function __before_exit() {
    __run_user_added_funcs "$__BEFORE_EXIT_STEPS" 0 $@
}

function __check_host_test_funcs() {
    if [[ -z "$__TEST_RUN_STEPS" ]]; then
        errcho "No \"add_step_to_test_run\" call was made. Nothing to test."
        return 1
    fi
}

__REQUIRED_HOST_EXECUTABLES="timeout gnuplot $__SERSH $__SERCP $__UBOOT_BOOT_LOGIN"
function __check_host_executables() {
    if [[ -z "$__REQUIRED_HOST_EXECUTABLES" ]]; then
        errcho  "Corrupted (zeroed) __REQUIRED_HOST_EXECUTABLES environment variable"
        return 1
    fi
    local missing_execs=""
    for exec in $__REQUIRED_HOST_EXECUTABLES; do
        if ! type "$exec" > /dev/null; then
            missing_execs="$exec $missing_execs"
        fi
    done
    if [[ ! -z "$missing_execs" ]]; then
        errcho  "Missing required executables on the Tester(PC): $missing_execs"
        return 1
    fi
}

__REQUIRED_DUT_EXECUTABLES=""
function __check_dut_executables() {
    if [[ -z "$__REQUIRED_DUT_EXECUTABLES" ]]; then
        return 0
    fi
    local missing_execs=""
    for exec in $__REQUIRED_DUT_EXECUTABLES; do
        if ! dut_cmd "type $exec" > /dev/null; then
            missing_execs="$exec $missing_execs"
        fi
    done
    if [[ ! -z "$missing_execs" ]]; then
        errcho  "Missing required executables on the DUT: $missing_execs"
        return 1
    fi
}

function __clear_jenkins_workspace() {
    echo "erasing workspace containing:"
    ls $WORKSPACE
    rm -rf $WORKSPACE/*
}

function __emit_log_parser_msg() {
    # parser that has to extract the results.
    #
    # This is printed both to the raw output and to a file called
    #"log-parser-msgs". The output parser can process either from the RAW
    # Jenkins log or from the "log-parser-msgs" file if required.
    echo "||--> LOG_PARSER_MSG: $@ <--||" | tee -a $__LOG_PARSER_MSGS_FILE
}

function __from_gnu_timeout_to_sec() {
    local mul="1."
    local t="$1"

    if [[ "$timeout" == *s ]]; then
        t=$(echo $timeout | tr -d 's')
    elif [[ "$timeout" == *m ]]; then
        t=$(echo $timeout | tr -d 'm')
        mul="60."
    elif [[ "$timeout" == *h ]]; then
        t=$(echo $timeout | tr -d 'h')
        mul="3600."
    elif [[ "$timeout" == *d ]]; then
        t=$(echo $timeout | tr -d 'd')
        mul="86400."
    fi
    t=$(echo "$t * $mul" | bc)
    if [[ -z "$t" ]]; then
        return 1
    fi
    printf "$t"
}

function __add_timeouts_value() {
    local funcname="$1"
    local timeout="$2"
    local sec;
    sec=$(__from_gnu_timeout_to_sec $timeout)
    if [[ $? -ne 0 ]]; then
        errcho "Invalid timeout format for \"$funcname\": \"$timeout\""
        return 1
    fi
    __STEP_TIMEOUTS="$__STEP_TIMEOUTS $funcname=$sec"
}

function __add_timeouts_step() {
    local steps="$1"
    local group_name="$2"
    local global_timeout="$3"
    local group_timeout;

    group_timeout=$(kvl_get_value_for_key "$__step_timeouts" "^${group_name}\$")
    if [[ $? -eq 2 ]]; then
        return 1
    fi
    for ft in $steps; do
        local funcname=$(echo $ft | cut -d ';' -f 1)
        # Checking if the user set an explicit timeout
        local timeout;
        local sec;
        timeout=$(kvl_get_value_for_key "$__step_timeouts" "^${func_name}\$")
        local err=$?
        if [[ $err -eq 0 ]]; then
            __add_timeouts_value "$funcname" "$timeout" || { return 1; }
            continue
        fi
        if [[ $err -eq 2 ]]; then
            return 1
        fi
        # Checking if the function writer did set a default timeout.
        timeout=$(echo $ft | cut -d ';' -f 2)
        if [[ "$timeout" != "unset" ]]; then
            __add_timeouts_value "$funcname" "$timeout" || { return 1; }
            continue
        fi
        # Checking if there is a group timeout
        if [[ ! -z "$group_timeout" ]]; then
            __add_timeouts_value "$funcname" "$group_timeout" || { return 1; }
            continue
        fi
        # Checking if there is a default timeout
        if [[ ! -z "$global_timeout" ]]; then
            __add_timeouts_value "$funcname" "$global_timeout" || { return 1; }
            continue
        fi
        __add_timeouts_value "$funcname" 0
    done
}

__STEP_TIMEOUTS=""
function __build_step_timeouts() {
    local default;
    default=$(kvl_get_value_for_key "$__step_timeouts" "^default\$")
    if [[ $? -eq 2 ]]; then
        return 1
    fi
    local powerfuncs="dut_power_on;unset dut_power_off;unset dut_boot;unset"
    __add_timeouts_step "$powerfuncs" "a^" "$default" || { return 1; }
    __add_timeouts_step "$__BEFORE_DUT_POWER_ON_STEPS" ^before_dut_power_on "$default" || { return 1; }
    __add_timeouts_step "$__AFTER_DUT_POWER_ON_STEPS" ^after_dut_power_on "$default" || { return 1; }
    __add_timeouts_step "$__BEFORE_TEST_RUN_STEPS" ^before_test_run "$default" || { return 1; }
    __add_timeouts_step "$__TEST_RUN_STEPS" ^test_run "$default" || { return 1; }
    __add_timeouts_step "$__AFTER_TEST_RUN_STEPS" after_test_run "$default" || { return 1; }
    __add_timeouts_step "$__BEFORE_EXIT_STEPS" before_exit "$default" || { return 1; }
}

function __build_plot() {
    local script="set term png; set output \"$2\";"
    script="$script set xlabel \"build number\";"
    script="$script set ylabel \"$3\";"
    script="$script  plot \"$1\" with linespoints notitle;"
    gnuplot -e "$script"
}

function __process_measurements() {
    local callparser="$1"
    local measfile=$BUILD_NUMBER.measurements.hottest.txt
    local lastbuildfile=$__PERSISTENT_JOB_DIR/last-build
    $callparser -t meas > "$measfile"
    if [[ ! -f "$measfile" ]]; then
        return 0
    fi
    mkdir -p $__PERSISTENT_JOB_DIR
    local lastbuild=0
    if [[ -f "$lastbuildfile" ]]; then
        lastbuild=$(cat "$lastbuildfile")
    fi
    echo "$BUILD_NUMBER" > "$lastbuildfile"
    if [[ "$BUILD_NUMBER" -le $lastbuild ]]; then
        # Jobs were removed and regenerated, backup old data.
        local olddatname="measurement-backup_$(date +%Y-%m-%d.%Hh-%Mm-%Ss)"
        cd "$__PERSISTENT_JOB_DIR"
        mkdir -p "$olddatname"
        mv *.dat *.png "$olddatname"
        tar cvzf "${olddatname}.tar.gz" "$olddatname"
        rm -rf "$olddatname"
        cd -
    fi
    for kv in $(cat "$measfile"); do
        local k=$(echo "$kv" | cut -d = -f 1)
        local v=$(echo "$kv" | cut -d = -f 2)

        local base="$__PERSISTENT_JOB_DIR/${k}"
        local alldat="${base}.all.dat"
        local allpng="${base}.all.graph.png"

        if [[ "$k" == "jenkins_build_number" ]]; then
            # This is a comment added on the log and not real data, skipping
            continue
        fi
        echo -e "${BUILD_NUMBER}\t${v}" >> "$alldat"
        __build_plot "$alldat" "$allpng" "$k"

        local alldatsz=$(stat --printf="%s" $alldat)
        local extra="60 365"

        for count in $extra; do
            local dat="${base}.${count}-last.dat"
            local png="${base}.${count}-last.graph.png"
            tail -n "$count" "$alldat" > "$dat"
            if [[ "$alldatsz" ==  $(stat --printf="%s" "$dat") ]]; then
                #No changes
                rm "$dat"
                continue
            fi
            __build_plot "$dat" "$png" "$k"
        done
    done
    for file in $(find $__PERSISTENT_JOB_DIR -name '*.graph.png'); do
        cp -f "$file" "$WORKSPACE"
    done
}

function __process_test_results() {
    local callparser="$1"
    echo "Test results:"
    $callparser -t human
    $callparser -t xunit > $BUILD_NUMBER.results.xunit
    # The return code of the script to Jenkins is only based on the number
    # of tests thad did run.
    $callparser -t stats | grep 'failed: 0, not run: 0' > /dev/null
}

# Header runtime
function __on_exit() {
    printf "\nEXIT HANDLER\n"
    if [[ $__TEST_SEQUENCE_STARTED -ne 1 ]]; then
        errcho "Test failed on the global scope before defining all test cases."
        errcho "No junit will be generated. Premature exit calls? To debug this"
        errcho "add \"set +x\" on the Jenkins script."
        errcho ""
        return 1
    fi
    # Back off functions.
    if [[ $__TEST_RUN_REACHED -eq 1 ]]; then
        __after_test_run "$1"
    fi
    __step_timeout_parse_wrap __run_ifdef dut_power_off
    local callparser="$__LOG_PARSER -f $__LOG_PARSER_MSGS_FILE -n $JOB_NAME"
    __process_measurements "$callparser"
    __process_test_results "$callparser"
    __before_exit "$1"
    exit $?
}
trap __on_exit EXIT

if [[ "$__verbose" -ne 0 ]]; then
    (set -o posix ; set | grep -v ^_) # Print env vars. (No functions)
fi
