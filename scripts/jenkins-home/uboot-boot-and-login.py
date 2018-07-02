#!/usr/bin/env python

# Copyright (C) 2018 HMS Industrial Networks AB
#
# This program is the property of HMS Industrial Networks AB.
# It may not be reproduced, distributed, or used without permission
# of an authorized company official.

'''
This program attaches to the console early in U-Boot to be able to print the
Kernel boot log on stdout. It stops when either a string is matched (e.g.
"login: ") or times out.
'''
import sys
import logging
import time
import serial
from argparse   import ArgumentParser
from contextlib import closing

from hush_shell import HushShell

def parse_and_validate_args():
    ''' Parse and sanity check command line arguments.'''
    parser = ArgumentParser(
        description=
            'Attaches to U-boot, boots and retrieves the Kernel console output and logs in')
    parser.add_argument(
        '-s',
        '--serial-dev',
        action='store',
        required=True,
        help='Serial port path (e.g /dev/ttyS0 or COM1)')
    parser.add_argument(
        '-b',
        '--baudrate',
        action='store',
        required=False,
        type=int,
        default=115200,
        help='Serial port baudrate')
    parser.add_argument(
        '-c',
        '--boot-cmd',
        action='store',
        required=False,
        default='boot',
        help='Boot command')
    parser.add_argument(
        '-l',
        '--login-match',
        action='store',
        required=True,
        help='Login text to match')
    parser.add_argument(
        '-u',
        '--user',
        action='store',
        default='root',
        help='Passwordless user to log in')
    parser.add_argument(
        '-t',
        '--timeout',
        action='store',
        default=120,
        type=int,
        help='Returns an error code after this time has passed with no successful boot after issuing the boot command (seconds)')
    parser.add_argument(
        '--uboot-connect-timeout',
        action='store',
        default=20,
        type=int,
        help='Returns an error code after this time has passed without being able to access the uboot shell')
    args = parser.parse_args()
    return args

def main():
    ''' Main function '''
    args  = parse_and_validate_args()

    ser          = serial.Serial()
    ser.port     = args.serial_dev
    ser.parity   = serial.PARITY_NONE
    ser.bytesize = serial.EIGHTBITS
    ser.stopbits = serial.STOPBITS_ONE
    ser.timeout  = 0.5
    ser.xonxoff  = 0
    ser.rtscts   = 0
    ser.dsrdtr   = 0
    ser.baudrate = args.baudrate

    ser.open()
    with (closing (ser)):
        shell = HushShell(ser, logging.getLogger(__name__))
        print('waiting for U-boot shell')
        shell.connect(args.uboot_connect_timeout)
        print ('running boot command: "{}"'.format(args.boot_cmd))
        ser.write('\n') # Terminal cleanup
        shell.command_raw(args.boot_cmd)

        start   = time.time()
        cmpbuff = ''
        while time.time() - start < args.timeout:
            data = ser.read()
            sys.stdout.write(data)
            sys.stdout.flush()
            cmpbuff += data
            if args.login_match in cmpbuff:
                sys.stdout.write('\n')
                ser.write(args.user + '\n')
                ser.flushInput()
                ser.write('\n')
                ser.flushInput()
                return 0
            cmpbuff = cmpbuff[-len(args.login_match):]

        print('\nTimed out while trying to match: \"{}\"'.format(
            args.login_match))
        return 1

if __name__ == '__main__':
    try:
        sys.exit (main())
    except KeyboardInterrupt:
        pass
