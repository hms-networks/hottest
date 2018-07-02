#|include <board/includes/localhost-board>
#|include <board/includes/localhost-deployment>

# Normally boards make more use of the "include" directive than tests, as code
# is more hardware-specific and can be shared, e.g. a test LAB will usually have
# one type of relay board, so "dut_power_on" and "dut_power_off" may be
# implemented on a chunk and reused between all the boards.
#
# We have just split all the demo "dut_*" function implementations in two files
# just for demo purposes. Everything could perfectly be defined here.
