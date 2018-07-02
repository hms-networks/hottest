# This file adds the "add_step_to_crosscompile" function to the framework.
#
# It will execute the passed functions to "add_step_to_crosscompile" on a shell
# with a sourced crosscompile environment that has the CC, LD and AR environment
# variables available.
#
# For doing that the test job needs to provide the "dut_source_cross_toolchain"
# function, whose goal is to define those variables.
#
# In the case of an OpenEmbedded toolchain it suffices with including
# the "oe_crosscompile" chunk on this folder instead of this one.
#
# For other toolchains I guess that you need to point to the executable and to
# provide extra flags on the CC variable (e.g. --sysroot).
#

#|include <util/misc/misc>

function validate_crosscompile_impl() {
    dut_source_cross_toolchain || { return 1; }
    local tools="CC LD AR" #mininal set for now
    for tool in $tools; do
        if ! eval "\$$tool --help" > /dev/null; then
            errcho "ERROR: dut_source_cross_toolchain: \"$tool\": failed validation."
            return 1
        fi
    done
}

CROSS_COMPILE_ENV_VALIDATED="no"
function validate_crosscompile_env() {
    if [[ ! "$CROSS_COMPILE_ENV_VALIDATED" = "no" ]]; then
        return $CROSS_COMPILE_ENV_VALIDATED
    fi
    CROSS_COMPILE_ENV_VALIDATED=1
    # Subshell to avoid sourcing the parent.
    (validate_crosscompile_impl) || { return 1; }
    CROSS_COMPILE_ENV_VALIDATED=0
    return 0
}

function add_step_to_crosscompile() {
    # It's the same as "add_step_before_dut_power_on", but it runs the
    # passed function within a sourced crosscompile environment.
    #
    # The crosscompile environment requires the test to implement
    # "dut_source_cross_toolchain"
    #
    if ! is_func_defined $1; then
        errcho "ERROR: \"add_step_to_crosscompile\": Undefined function \"$1\"."
        exit 1
    fi
    if ! is_func_defined dut_source_cross_toolchain; then
        errcho "ERROR: \"add_step_to_crosscompile\" requires \"dut_source_cross_toolchain\" to be implemented."
        exit 1
    fi
    validate_crosscompile_env || { exit 1; }
    local crossfunc;
    heredoc_define crossfunc << EOF
    function $1_crosswrapper(){
        dut_source_cross_toolchain
        $1
    }
EOF
    eval "$crossfunc"
    add_step_before_dut_power_on $1_crosswrapper $2
}
