#!/usr/bin/env python

# Copyright (C) 2018 HMS Industrial Networks AB
#
# This program is the property of HMS Industrial Networks AB.
# It may not be reproduced, distributed, or used without permission
# of an authorized company official.

'''
This program reads a raw log of a test run and extracts test reports in xunit
format.
'''

import sys
import xunitgen
import tempfile
import shutil

from os       import path
from enum     import Enum
from argparse import ArgumentParser

class CaseCode (Enum):
    PASS = 1
    FAIL = 2
    NOTRUN = 3

class CaseResult (object):
    def __init__(self, code=CaseCode.NOTRUN, msg=''):
        self.code = code
        self.msg  = msg

result_convert = { "PASS":  CaseCode.PASS, "FAIL": CaseCode.FAIL }

OPEN_MSG = '||--> LOG_PARSER_MSG: '
CLOSE_MSG = ' <--||'

class TestResults (object):
    def __init__(self):
        self.success_count = 0
        self.failure_count = 0
        self.notrun_count = 0
        self.total_count = 0
        self.test_order = []
        self.cases = {}
        self.measurements = {}
        self.measurements_x_axis = "0"

class JenkinsLogParseException (Exception):
    pass

def parse_results (jenkins_output_log_str):
    on_multiline_msg = False
    msgs = []

    #Filter entries
    for line in jenkins_output_log_str.splitlines():
        if not on_multiline_msg:
            if line.startswith (OPEN_MSG):
                line = line[len (OPEN_MSG):]

                if line.endswith (CLOSE_MSG):
                    line = line[:-len (CLOSE_MSG)]
                else:
                    on_multiline_msg = True

                msgs.append (line)
        else:
            if line.endswith (CLOSE_MSG):
                on_multiline_msg = False
                line = line[:-len (CLOSE_MSG)]

            msgs[-1] = msgs[-1] + line

    if on_multiline_msg and len (msgs) > 0:
        raise JenkinsLogParseException ('End of file reached without finding closing for message: \"{}\".'.format(msgs[-1]))

    if len (msgs) == 0:
        raise JenkinsLogParseException ('This log contains no messages.')

    if len (msgs) == 2:
        raise JenkinsLogParseException ('Each log has to contain a case enumeration and a build number.')

    res = TestResults()

    testcases = msgs[0].split()
    if len (testcases) == 0 or testcases[0] != 'CASE_ENUM':
        raise JenkinsLogParseException(
            'The first expected message tag in the log should be CASE_ENUM. Found: "{}"'
                .format (testcases[0]))

    testcases        = testcases[1:]
    res.total_count  = len(testcases)
    res.notrun_count = res.total_count
    for testcase in testcases:
        res.cases[testcase] = CaseResult (CaseCode.NOTRUN)

    for msg in msgs[1:]:
        tokens = msg.split (' ', 3)

        if tokens[0] == 'SAMPLE':
            if len(tokens) != 3:
                raise JenkinsLogParseException(
                    'Malformed SAMPLE message: "{}"'.format (msg))
            try:
                res.measurements[tokens[1]] = float (tokens[2])
            except ValueError:
                raise JenkinsLogParseException(
                    'Invalid SAMPLE value, expected a float. Found: "{}"'
                        .format (tokens[2]))
            continue

        elif tokens[0] != 'CASE':
            raise JenkinsLogParseException(
                'Expected message of type CASE. Found: "{}"'
                    .format (tokens[0]))

        if len(tokens) < 3:
            raise JenkinsLogParseException(
                'Malformed CASE message: "{}"'.format (msg))

        previous_result = res.cases.get (tokens[1])
        if previous_result is None:
            raise JenkinsLogParseException(
                'Test case was not previously declared: "{}"'
                    .format (tokens[1]))

        # Just PASS/FAIL for now
        casecode = result_convert.get (tokens[2])
        if casecode is None:
            raise JenkinsLogParseException(
                'Unknown type of result for test "{}": "{}"'
                    .format (tokens[1], tokens[2]))

        if previous_result.code == CaseCode.NOTRUN:
            res.test_order.append(tokens[1])
            res.notrun_count -=1
        elif previous_result.code == CaseCode.PASS:
            #setting same test twice. WARN? ALLOWED?
            res.success_count.code -=1
        elif previous_result == CaseCode.FAIL:
            #setting same test twice. WARN? ALLOWED?
            res.failure_count -=1

        resmsg = '' if len(tokens) != 4 else tokens[3]
        res.cases[tokens[1]] = CaseResult (casecode, resmsg)

        if casecode == CaseCode.PASS:
            res.success_count +=1
        elif casecode == CaseCode.FAIL:
            res.failure_count +=1

    return res

def generate_xunit (results, suite_name):
    tmpdir = tempfile.mkdtemp()
    dst    = xunitgen.XunitDestination(tmpdir)

    with xunitgen.Recorder (dst, suite_name) as recorder:
        for test in results.test_order:
            with recorder.step (test) as step:
                result = results.cases[test]
                if result.code == CaseCode.FAIL:
                    step.error (result.msg)

        if results.notrun_count > 0:
            for test, result in results.cases.iteritems():
                if result.code == CaseCode.NOTRUN:
                    with recorder.step (test) as step:
                        step.error ('This test did never run.')

    with open (path.join (tmpdir, suite_name + '.xml'), 'r') as xmlfile:
        retxml = xmlfile.read()

    shutil.rmtree (tmpdir)
    return retxml

def generate_human (results, suite_name):
    res = '[SUITE   ] {}\n'.format(suite_name)

    for test in results.test_order:
        result = results.cases[test]
        if result.code == CaseCode.FAIL:
            res += ' [FAILED ] {}\n'.format (test)
            if result.msg != '':
                res += '           {}\n'.format (result.msg)
        else:
            res += ' [SUCCESS] {}\n'.format (test)

    if results.notrun_count > 0:
        for test, result in results.cases.iteritems():
            if result.code == CaseCode.NOTRUN:
                res += ' [NOT RUN] {}\n'.format (test)

    return res

def generate_stats (results, suite_name):
    res = 'Total: {}, succeeded: {}, failed: {}, not run: {}'.format(
        results.total_count,
        results.success_count,
        results.failure_count,
        results.notrun_count)
    return res

def generate_measurements (results, suite_name):
    res = ''
    for k, v in results.measurements.items():
        res += '{}={}\t'.format (k, v)
    return res.rstrip() + '\n'

format_converters = {
    'xunit' : generate_xunit,
    'human' : generate_human,
    'stats' : generate_stats,
    'meas'  : generate_measurements,
}

def main():
    parser = ArgumentParser(
        description='Parses test results from the Jenkins output logs of a hottest run to standard formats')

    parser.add_argument(
        '-f', '--log-file',
        action='store',
        required=False,
        default=None,
        help='File to parse, otherwise reads from stdin')

    parser.add_argument(
        '-n', '--suite-name',
        action='store',
        required=True,
        default=None,
        help='Name of the test suite.')

    parser.add_argument(
        '-t', '--output-type-format',
        required=False,
        action='store',
        default='human',
        choices=format_converters.keys(),
        help='Format type to output. One of {}'
            .format (' '.join (format_converters.keys())))

    args = parser.parse_args()

    if args.log_file is None:
        logdata = sys.stdin.read()
    else:
        with open (args.log_file, 'r') as logfile:
            logdata = logfile.read()

    res = parse_results (logdata)

    ret = format_converters[args.output_type_format] (res, args.suite_name)
    print ret

if __name__ == '__main__':
    main()
