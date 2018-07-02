# Busybox test.
#
# Copyright (C) 2012, Linaro Limited.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# Author: Senthil Kumaran <senthil.kumaran@linaro.org>
# Adapded by Alexander Kuzmich <alku@hms.se> and Rafael Gago <rgc@hms.se>
#

add_required_dut_executables /bin/busybox

function busybox_run_wrapper() {
    local case_name="busybox_$1"
    if echo "${busybox_command_blacklist}" | tr ' ' '\n' | xargs | grep -q "^$1\$"; then
        return 0
    fi
    if [[ $BUSYBOX_RUN_DECLARE_TEST_CASES_ONLY -eq 1 ]]; then
        declare_test_cases $case_name
    else
        dut_cmd "/bin/busybox $@"
        test_case_set $case_name $?
    fi
}

function busybox_test_declare_or_run() {
    if [[ $1 == "declare_test_cases" ]]; then
        BUSYBOX_RUN_DECLARE_TEST_CASES_ONLY=1
    fi
    busybox_run_wrapper mkdir ${tgt_dir}/busybox
    busybox_run_wrapper dd if=/dev/zero of=/dev/null bs=1K count=1
    busybox_run_wrapper touch ${tgt_dir}/busybox/test.txt
    busybox_run_wrapper echo "LAVA"
    busybox_run_wrapper cat /proc/cpuinfo
    busybox_run_wrapper grep "model" /proc/cpuinfo
    busybox_run_wrapper ls ${tgt_dir}/busybox/test.txt
    busybox_run_wrapper ps
    busybox_run_wrapper whoami
    busybox_run_wrapper which busybox
    busybox_run_wrapper basename ${tgt_dir}/busybox/test.txt
    busybox_run_wrapper cp ${tgt_dir}/busybox/test.txt ${tgt_dir}/busybox/test2.txt
    busybox_run_wrapper rm ${tgt_dir}/busybox/test2.txt
    busybox_run_wrapper dmesg
    busybox_run_wrapper ifconfig eth0
    busybox_run_wrapper mount

    if [[ $1 == "declare_test_cases" ]]; then
        readonly BUSYBOX_RUN_DECLARE_TEST_CASES_ONLY=0
    fi
}
busybox_test_declare_or_run "declare_test_cases"

function busybox_test_run() {
    local tgt_dir="/tmp"
    dut_cmd "rm -r ${tgt_dir}/busybox 1>/dev/null 2>/dev/null"
    busybox_test_declare_or_run "run_test_cases"
}

add_step_to_test_run busybox_test_run
