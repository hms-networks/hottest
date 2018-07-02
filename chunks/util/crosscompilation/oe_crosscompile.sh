# Provides all the crosscompilation functions for an OE (OpenEmbedded)
# toolchain. It assumes that the OE toolchain is installed on the host.

#|include <util/crosscompilation/crosscompile>

function dut_source_cross_toolchain() {
    # Just sourcing the OE toolchain as-is.
    if [[ ! -f "${oe_sdk_envsetup_script}" ]]; then
        errcho "dut_source_cross_toolchain: ${oe_sdk_envsetup_script} doesn't exist."
        return 1
    fi
    . ${oe_sdk_envsetup_script}
}
