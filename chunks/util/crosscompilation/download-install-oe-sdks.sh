# Downloads and installs OpenEmbedded toolchains from a remote file server and
# installs them locally.

add_required_host_executables wget

download_install_oe_sdks() {
    if [[ -z "$(echo ${install_oe_sdks} | xargs)" ]]; then
        errcho "download_install_oe_sdks: Nothing to download. Is this what you intended?"
        return 1
    fi
    local downloads=""
    for kv in ${install_oe_sdks}; do
        downloads="$(echo "$kv" | cut -d "=" -f 2-) $downloads"
    done
    echo "Downloding OpenEmbedded SDKs..."
    echo "$downloads" | xargs -n 1 -P 32 wget -nv
    local ret=$?
    if [[ $ret -ne 0 ]]; then
        errcho "download_install_oe_sdks: download error: $ret"
        return $ret
    fi
    for kv in ${install_oe_sdks}; do
        local dstdir="$(echo "$kv" | cut -d "=" -f 1)"
        local oe_sdk_installer="$(basename $(echo "$kv" | cut -d "=" -f 2-))"
        chmod +x $oe_sdk_installer
        if [[ $? -ne 0 ]]; then
            errcho "download_install_oe_sdks: Unable to chmod \"$oe_sdk_installer\""
            return 1
        fi
        echo "Installing SDK: \"$oe_sdk_installer\""
        ./$oe_sdk_installer -yd "$dstdir"
        if [[ $? -ne 0 ]]; then
            errcho "download_install_oe_sdks:  \"$oe_sdk_installer\" failed"
            return 1
        fi
    done
}
