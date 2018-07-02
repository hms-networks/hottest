# Class to interact with the hush (e.g. Uboot) shell

import time
import string

class HushError(Exception):
    pass

class HushWaitTimeout(HushError):
    def __init__(self):
        super(HushWaitTimeout, self).__init__(
            'shell: timeout while waiting the shell to be ready')

class HushTimeout(HushError):
    def __init__(self, command):
        super(HushTimeout, self).__init__(
            'shell: shell timeout when running command: "{}"'.format(command))

class HushCommandEchoMismatch(HushError):
    def __init__(self, command, rcvd):
        super(HushCommandEchoMismatch, self).__init__(
            'shell: shell echo mismatch for command: "{}". received: "{}"'
                .format(command, rcvd))

class HushUnknownCommand(HushError):
    def __init__(self, command):
        super(HushUnknownCommand, self).__init__(
            'shell: unknown command: "{}"'.format(command))

class HushCommandFailed(HushError):
    def __init__(self, command, error_code, output_line_list):
        self.error_code = error_code
        self.output_lines = output_line_list
        msg_str = 'shell: error when running command: "{}".'\
        'error code: {}. command output:\n{}'.format(
            command, error_code, '\n'.join(output_line_list))
        super (HushCommandFailed, self).__init__(msg_str)

class HushShellDelays():
    def __init__(
            self,
            cmd=0.1,
            abort=0.3,
            char=0.001):

        self.cmd   = float(cmd)
        self.char  = float(char)
        self.abort = float(abort)

class HushShell(object):
    ''' Interact with U-boot hushshell over a serial link '''
    # String to look for to determine return code of a U-boot command
    RETCODE_KEYWORD = 'RETCODE '
    # Minimum elapsed time (seconds) between each command invokation (enforced)

    def __init__(self, serial, logger, delays=HushShellDelays()):
        self.serial = serial
        self.last_cmd_timepoint = 0
        self.last_cmd = None
        self.log = logger
        self.delay = delays
        ''' It is essential that a serial port read() doesn't block too long,
        otherwise we might not be able to send CTRL+C during the (relatively)
        short window where it is possible to break into U-boot shell. '''
        self.serial.timeout = 0.5

    def set_delays(self, delays):
        self.delay = delays

    def _reset_serial_buffers(self):
        self.log.debug("shell: resetting buffers")
        self.serial.reset_output_buffer()
        self.serial.reset_input_buffer()

    def send_abort(self):
        self.log.debug("shell: send abort sequence")
        self.serial.write("\x03")
        self.serial.flush()
        time.sleep(self.delay.abort)

    def connect(self, timeout):
        ''' Clears the serial port buffers and waits until hush shell (uboot) is
        ready/responsive/operational. '''
        start = time.time()
        while True:
            self._reset_serial_buffers()
            self.send_abort()
            line = self.serial.readline()
            if '<INTERRUPT>' in line:
                self.log.debug('shell: operational')
                break
            elif time.time() - start > timeout:
                raise HushWaitTimeout()
        self.serial.write('\n')
        time.sleep(self.delay.abort * 2)
        self._reset_serial_buffers()

    def _write_command(self, cmd, will_parse=True, echo_timeout=4):
        if self.last_cmd:
            self.log.warning(
                'shell: possible bug, a command generating retcodes didn\'t have a subsequent call to "parse_output"')

        #Apply delay between commands, some shells require it
        last_cmd_elapsed_sec = time.time() - self.last_cmd_timepoint
        if last_cmd_elapsed_sec < self.delay.cmd:
            delay = float(self.delay.cmd - last_cmd_elapsed_sec)
            self.log.debug(
                'shell: %fs delay before issuing next command', delay)
            time.sleep(delay)

        start = time.time()
        self.connect(echo_timeout)

        if will_parse:
            sendcmd = cmd + " ; echo {}$?".format(self.RETCODE_KEYWORD)
        else:
            sendcmd = cmd

        # Send command string with inter-character delay to improve buggy
        # behavior on some ports
        for character in sendcmd + '\n':
            self.serial.write(character)
            if self.delay.char > 0:
                time.sleep(self.delay.char)

        self.last_cmd = None
        self.last_cmd_timepoint = time.time()

        self.log.debug('shell: write command: "%s"', cmd)
        remaining_time = echo_timeout - (time.time() - start)
        if remaining_time <= 0:
            raise HushTimeout(cmd)

        tmo = self.serial.timeout
        self.serial.timeout = remaining_time
        echo = self.serial.readline().rstrip()
        self.serial.timeout = tmo

        if not echo.endswith(sendcmd):
            printable_echo = "".join(
                [x for x in echo if x in string.printable])
            raise HushCommandEchoMismatch(cmd, printable_echo)

        self.log.debug('shell: successfully written command: "%s"', cmd)
        self.last_cmd = cmd if will_parse else None

    def _parse_output(self, timeout=4):
        if self.last_cmd is None:
            raise HushError(
                'shell: can\'t invoke "parse_output" without a previous successful invocation of "write_command"')

        cmd = self.last_cmd
        self.last_cmd = None
        self.log.debug('shell: parse command result of: "%s"', cmd)

        lines = []
        start = time.time()
        while True:
            line = self.serial.readline()
            now = time.time()

            if now - start >= timeout:
                self.log.debug('shell: no response in %f s', timeout)
                self.send_abort()
                raise HushTimeout('(parsing output of) {}'.format(cmd))

            if not line:
                continue

            line = line.strip()
            if line.startswith(self.RETCODE_KEYWORD):
                retcode = int(line[len(self.RETCODE_KEYWORD):])
                if retcode == 0:
                    break
                else:
                    raise HushCommandFailed(cmd, retcode, lines)
            elif line.upper().startswith('UNKNOWN COMMAND'):
                self.send_abort()
                raise HushUnknownCommand(cmd)
            else:
                self.log.debug('shell: <- "{}"'.format(line))
                lines.append(line)
        self.log.debug('shell: parse command successful: "{}"'.format (cmd))
        return lines

    def command(self, cmd, timeout=4):
        ''' Executes the given command and tries parse (and consumes) the output
        from the serial port. Cleans the serial port buffers before writing
        the command.

        Only returns when the command was successful. In such case it returns
        a list containing all the output lines.

        May throw:
        - HushWaitTimeout: No connection to Uboot shell.
        - HushTimeout: Timeout expired
        - HushCommandEchoMismatch: The echoed command on the shell didn't match
        - HushCommandFailed: The command failed. The exception contains the
            error code and output.
        - HushUnknownCommand: The command was unknown '''
        start = time.time()
        self._write_command(cmd, True, timeout)
        elapsed = time.time() - start
        remaining = timeout - elapsed
        return self._parse_output(remaining if remaining > 0 else 0)

    def command_raw(self, cmd, timeout=4):
        ''' Executes the given command without looking at the results or parsing
        the output. Cleans the serial port buffers before writing the command.

        May throw:
        - HushWaitTimeout: No connection to Uboot shell.
        - HushTimeout: Timeout expired
        - HushCommandEchoMismatch: The echoed command on the shell didn't match
        '''
        self._write_command(cmd, False, timeout)
