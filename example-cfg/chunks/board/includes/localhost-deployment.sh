#|board-require-env <DUMMY_BOARD_ADDRESS>

# We add a required executable on the host (wget) for demo purposes. If wget
# is not installed on the test machine this test will bail out before starting.
add_required_host_executables "wget"

# Adding some dummy tasks emulating a board's deployment.
function download_board_artifacts() {
    echo "Downloading booloader with wget: $dummy_bootloader on $DUMMY_BOARD_ADDRESS"
    echo "Downloading image artifact with wget: $dummy_img on $DUMMY_BOARD_ADDRESS"
}
add_step_before_dut_power_on download_board_artifacts "1.0m"

function flash_board() {
    echo "Deploying bootloader: $dummy_bootloader on $DUMMY_BOARD_ADDRESS"
    echo "Deploying os: $dummy_img on $DUMMY_BOARD_ADDRESS"
}
add_step_after_dut_power_on flash_board "3.0m"
