#!/usr/bin/env python

from xml.etree import ElementTree as ET
from xml.dom.minidom import parseString as dom_parse_str
from argparse  import ArgumentParser
from os import path
import sys
import re

from _cli_common import *

def thisfile_dirname_join(name):
    return path.join (path.dirname (path.realpath (__file__)), name)

class GenParseException(Exception):
    def __init__(self, file, line, msg=''):
        self.msg = '{}, line {}: {}'.format(file, line, msg)
        super(GenParseException, self).__init__(self.msg)
    def __str__(self):
        return repr(self.msg)

class GenException(Exception):
    def __init__(self, msg=''):
        self.msg = msg
        super(GenException, self).__init__(self.msg)
    def __str__(self):
        return repr(self.msg)

JENKINS_NODE_CMD = 'hottest/noderun.sh' # This is our launch script

class ParsedBoard(object):
    '''Intermediate representation of a Jenkins node (board)'''
    def __init__(self, name):
        self.name    = name
        self.envvars = {}
        self.labels  = {}
        self.labels[name] = True
        self.fs_path = None
        self.description = ''

    def __str__(self):
        s  =     '[name       ] {}\n'.format (self.name)
        s +=     '[description] {}\n'.format (self.description)
        s +=     '[fspath     ] {}\n'.format (self.fs_path)
        s +=     '[labels     ] {}\n'.format (len (self.labels))
        for name, _ in self.labels.items():
            s += '[label      ] {}\n'.format (name)
        s +=     '[envvars    ] {}\n'.format (len (self.envvars))
        for name, val in self.envvars.items():
            s += '[envvar     ] [{}] {}\n'.format (name, val)
        return s

class JenkinsNodeXml(object):
    '''Jenkins test Node xml generator'''
    def __init__(self):
        # Taken from a configured node.
        root = ET.Element('slave')

        ET.SubElement(root, 'name')

        ET.SubElement(root, 'description')

        ET.SubElement(root, 'remoteFS')

        numExecutors = ET.SubElement(root, 'numExecutors')
        numExecutors.text = '1'

        mode = ET.SubElement(root, 'mode')
        mode.text = 'EXCLUSIVE'

        retentionStrategy = ET.SubElement(root, 'retentionStrategy')
        retentionStrategy.attrib['class'] = 'hudson.slaves.RetentionStrategy$Always'

        launcher = ET.SubElement(root, 'launcher')
        launcher.attrib['class'] = 'hudson.slaves.CommandLauncher'
        launcher.attrib['plugin'] = 'command-launcher@1.2'
        agentCommand = ET.SubElement(launcher, 'agentCommand')
        agentCommand.text = JENKINS_NODE_CMD

        label = ET.SubElement(root, 'label')
        label.text = ''

        nodeProperties = ET.SubElement(root, 'nodeProperties')
        EnvironmentVariables = ET.SubElement(
            nodeProperties, 'hudson.slaves.EnvironmentVariablesNodeProperty')
        envVars = ET.SubElement(EnvironmentVariables, 'envVars')
        envVars.attrib['serialization'] = 'custom'
        ET.SubElement(envVars, 'unserializable-parents')
        treemap = ET.SubElement(envVars, 'tree-map')
        default = ET.SubElement(treemap, 'default')
        comparator = ET.SubElement(default, 'comparator')
        comparator.attrib['class'] = 'hudson.util.CaseInsensitiveComparator'
        int_ = ET.SubElement(treemap, 'int')
        int_.text = '0' #defaulting to no env vars. use add_envar

        self.root = root

    def _append_envvar(self, name, value):
        treemap_path = 'nodeProperties/hudson.slaves.EnvironmentVariablesNodeProperty/envVars/tree-map'
        treemap = self.root.find(treemap_path)
        count = self.root.find(treemap_path + '/int')

        k = ET.SubElement(treemap, 'string')
        k.text = name
        v = ET.SubElement(treemap, 'string')
        v.text = value
        count.text = str(int(count.text) + 1)

    def add_board(self, parsedboard):
        name = self.root.find('name')
        name.text = parsedboard.name

        desc = self.root.find('description')
        desc.text = parsedboard.description

        rfs = self.root.find('remoteFS')
        rfs.text = parsedboard.fs_path
        if not rfs.text:
            rfs.text = './' + name.text

        label = self.root.find('label')
        for lbl in parsedboard.labels:
            label.text += lbl + ' '
        label.text = label.text.strip()

        for name, val in sorted (parsedboard.envvars.items()):
            self._append_envvar(name, val)

    def __str__(self):
        return dom_parse_str(
            ET.tostring (self.root, encoding='utf8', method='xml')
                ).toprettyxml()

class BoardData(ParsedBoard):
    '''Board data generator, just adds methods to ParsedBoard.'''
    def __init__(self, name, includedirs, board_chunk, param_files):
        super (BoardData, self).__init__(name)

        cpath = try_find_chunk_fullpath (includedirs, board_chunk)
        if cpath is None:
            raise GenException(
                'Could not find chunk files for board root. (json, sh or both): {}'
                    .format(board_chunk))

        self.labels[path.splitext (path.basename(board_chunk))[0]] = True

        pboard = parse_json(
            cpath + '.json', thisfile_dirname_join ('_schema_chunk_board.json'))

        self.fs_path = pboard.get('fs-path') # Not exposed on JSON schema
        self.description = from_strlist (pboard.get('description'))

        for label in pboard.get ('node-labels') or []:
            self.labels[label.strip()] = True

        for vname, value in (pboard.get('environment-variables') or {}).items():
            self.envvars[vname] = from_strlist (value).strip()

        for file in param_files:
            bp = parse_json(file, thisfile_dirname_join ('_schema_param_board.json'))
            self.add_parametrization (bp, board_chunk)

    def add_parametrization (self, board_params, board_chunk_name):
        for label in board_params.get('extra-node-labels') or []:
            self.labels[label] = True

        overrides = board_params.get('environment-variable-overrides') or {}
        for name, value in overrides.items():
            if not self.envvars.get(name):
                raise GenException(
                    '{}: board parametization environment variable "{}" doesn\'t exist on base board'
                        .format (board_chunk_name, name))
            self.envvars[name] = from_strlist (value)


    def get_jenkins_xml(self):
        xmlbuild = JenkinsNodeXml()
        xmlbuild.add_board(self)
        return str(xmlbuild)

class ParsedTest(object):
    '''Intermediate representation of a Jenkins test Job'''
    def __init__(self, name):
        self.name = name
        self.description = ''
        self.required_board_envvars = {}
        self.parameters = {}
        self.labels = {}
        self.script = "#!/bin/bash\n"
        self.parameter_overrides = {}

    def __str__(self):
        s  =     '[name       ] {}\n'.format (self.name)
        s +=     '[description] {}\n'.format (self.description)
        #s +=     '[script     ] {}\n'.format (self.script)
        s +=     '[labels     ] {}\n'.format (len (self.labels))
        for name, _ in self.labels.items():
            s += '[label      ] {}\n'.format (name)
        s +=     '[parameters ] {}\n'.format (len (self.parameters))
        for p, v in self.parameters.items():
            # omit "self.parameters[p].get('description'))" for now
            s += '[parameter  ] [{}] {}\n'.format(
                p, v.get('default'))
        return s

class JenkinsJobXml(object):
    '''Jenkins test Job xml generator'''
    def __init__(self):
        # Taken from a configured job.
        root = ET.Element('project')

        ET.SubElement(root, 'actions')

        ET.SubElement(root, 'description')

        keepDependencies = ET.SubElement(root, 'keepDependencies')
        keepDependencies.text = 'false'

        properties = ET.SubElement(root, 'properties')
        pdp = ET.SubElement(properties, 'hudson.model.ParametersDefinitionProperty')
        ET.SubElement(pdp, 'parameterDefinitions')

        scm = ET.SubElement(root, 'scm')
        scm.attrib['class'] = 'hudson.scm.NullSCM'

        ET.SubElement(root, 'assignedNode')

        canRoam = ET.SubElement(root, 'canRoam')
        canRoam.text = 'false'

        disabled = ET.SubElement(root, 'disabled')
        disabled.text = 'false'

        bbdb = ET.SubElement(root, 'blockBuildWhenDownstreamBuilding')
        bbdb.text = 'false'

        bbub = ET.SubElement(root, 'blockBuildWhenUpstreamBuilding')
        bbub.text = 'false'

        ET.SubElement(root, 'triggers')

        concurrentBuild = ET.SubElement(root, 'concurrentBuild')
        concurrentBuild.text = 'false'

        builders = ET.SubElement(root, 'builders')
        hts = ET.SubElement(builders, 'hudson.tasks.Shell')
        ET.SubElement(hts, 'command')

        pub = ET.SubElement(root, 'publishers')

        junit = ET.SubElement(pub, 'hudson.tasks.junit.JUnitResultArchiver')
        junit.attrib['plugin'] = 'junit@1.26.1'
        tr = ET.SubElement(junit, 'testResults')
        tr.text = '*.xunit'
        klstdio = ET.SubElement(junit, 'keepLongStdio')
        klstdio.text = 'false'
        hsfactor = ET.SubElement(junit, 'healthScaleFactor')
        hsfactor.text = '1.0'
        allow_empty = ET.SubElement(junit, 'allowEmptyResults')
        allow_empty.text = 'false'

        artifactarch = ET.SubElement(pub, 'hudson.tasks.ArtifactArchiver')
        artifacts = ET.SubElement(artifactarch, 'artifacts')
        artifacts.text = '*.graph.png'
        allowemptya = ET.SubElement(artifactarch, 'allowEmptyArchive')
        allowemptya.text = 'true'
        onlyifsuccessful = ET.SubElement(artifactarch, 'onlyIfSuccessful')
        onlyifsuccessful.text = 'false'
        fingerprint = ET.SubElement(artifactarch, 'fingerprint')
        fingerprint.text = 'false'
        defaultexcludes = ET.SubElement(artifactarch, 'defaultExcludes')
        defaultexcludes.text = 'true'
        casesensitive = ET.SubElement(artifactarch, 'caseSensitive')
        casesensitive.text = 'true'

        ET.SubElement(root, 'buildWrappers')

        self.root = root

    def _add_param(self, name, description, default):
        pardefs = self.root.find(
            'properties/hudson.model.ParametersDefinitionProperty/parameterDefinitions')

        strparam = ET.SubElement(
            pardefs, 'hudson.model.StringParameterDefinition')

        pname = ET.SubElement(strparam, 'name')
        pname.text = name

        if description is not None:
            pdesc = ET.SubElement(strparam, 'description')
            pdesc.text = description

        if default is not None:
            pdefault = ET.SubElement(strparam, 'defaultValue')
            pdefault.text = default

        trim = ET.SubElement(strparam, 'trim')
        trim.text = 'true'

    def add_job(self, parsedtest):
        cmd = self.root.find('builders/hudson.tasks.Shell/command')
        cmd.text = parsedtest.script

        desc = self.root.find('description')
        desc.text = parsedtest.description

        an = self.root.find('assignedNode')
        an.text = ''
        for label in parsedtest.labels:
            an.text += label + '&&'
        if an.text.endswith('&&'):
            an.text = an.text[:-2]

        for param, v in sorted (parsedtest.parameters.items()):
            desc = v.get('description')
            default = v.get('default')
            self._add_param (param, desc, default)

    def __str__(self):
        return dom_parse_str(
            ET.tostring (self.root, encoding='utf8', method='xml')
                ).toprettyxml()

class TestScript(object):
    '''Iterates test chunks, stores the script and accumulates labels and
    parameters'''
    def __init__(self, parsedtest, includedirs):
        self.parsedtest = parsedtest
        self.includedirs = includedirs
        self.included = {}

    def add_chunk(self, chunk_path, schema_name, lvl = 0):
        '''Adds a chunk and updates the results on parsedtest'''
        lvl += 1
        if lvl == 1:
            # Only root chunks are passed to this function without full paths,
            # as they are unknown, so we try a match on the include directories.
            old_path   = chunk_path
            chunk_path = try_find_chunk_fullpath (self.includedirs, chunk_path)
            if chunk_path is None:
                raise GenException(
                    'Could not find chunk files for root. (json, sh or both): {}'
                        .format(old_path))
        # Parsing the standard "json" part of a regular chunk: the "test-labels" and
        # "parameters" properties.
        fdata = parse_json(
            chunk_path + '.json', thisfile_dirname_join (schema_name))

        for label in fdata.get('test-labels') or []:
            self.parsedtest.labels[label] = True

        for name, param in (fdata.get('parameters') or {}).items():
            if name in self.parsedtest.parameters:
                raise GenException(
                    '{}: Duplicated parameter on Jenkins job: \"{}\"'
                        .format (chunk_path + '.json', name) )
            self.parsedtest.parameters[name] = {
                'description' : from_strlist (param.get('description') or ''),
                'default'     : from_strlist (param.get('default') or '')
            }

        # Preprocessing the ".sh" part of the chunk. This can lead to recursion
        # through the "#|include <file>" directive.
        fname  = chunk_path + '.sh'
        lvlstr = '#' * lvl
        self.parsedtest.script += '\n{} File contents of: {} {}\n'.format(
            lvlstr, fname, lvlstr)
        with open(fname) as f:
            for idx, line in enumerate (f.readlines(), 1):
                sline = line.strip()
                included_chunk_path = None

                if sline.startswith('#|board-require-env'):
                    match = re.match(
                        r'^#\|board-require-env +<([A-Za-z_][A-Za-z0-9_]*)>$',
                        sline)
                    try:
                        envvar = match.group(1)
                    except:
                        raise GenParseException(
                            fname, idx, 'Invalid #|require-board directive: {}'
                                .format (sline))

                    self.parsedtest.required_board_envvars[envvar] = True
                    continue

                if sline.startswith('#|include'):
                    match = re.match(
                        r'^#\|include +<([A-Za-z0-9/_\-\.]*)>$', sline)
                    try:
                        ichunk = match.group(1)
                    except:
                        raise GenParseException(
                            fname,
                            idx,
                            'Invalid #|include directive: {}'.format (sline))

                    ichunk_path = try_find_chunk_fullpath(
                        self.includedirs, ichunk)

                    if ichunk_path is None:
                        raise GenParseException(
                            fname,
                            idx,
                            'Could not find chunk files for #include directive. (json, sh or both)')

                    if ichunk_path not in self.included:
                        self.add_chunk(
                            ichunk_path, '_schema_chunk_test.json', lvl)
                        self.included[ichunk_path] = True
                    else:
                        self.parsedtest.script += '{}gen.py: #|include <{}> was guarded\n'.format(
                            lvlstr, ichunk)
                    continue

                if sline.startswith('#|parameter-default-override'):
                    match = re.match(
                        r'^#\|parameter-default-override +<([A-Za-z_][A-Za-z0-9_]*) +(.*)>$',
                        sline)
                    try:
                        var   = match.group (1)
                        value = match.group (2)
                    except:
                        raise GenParseException(
                            fname,
                            idx,
                            'Invalid #|parameter-default-override directive: {}'
                                .format (sline))
                    if (value.startswith('"') and value.endswith('"') or
                            value.startswith("'") and value.endswith("'")):

                        value = value[1:-1]

                    self.parsedtest.parameter_overrides[var] = value
                    continue

                if not line.endswith('\n'): # Append trailing file '\n'
                    line += '\n'
                self.parsedtest.script += line

class TestData(ParsedTest):
    '''Test data generator, just adds methods to ParserTest.'''
    def __init__(
            self,
            includedirs,
            board_chunk,
            test_chunk,
            extra_labels,
            param_files):

        name = path.basename(test_chunk) + '-' + path.basename(board_chunk)
        super (TestData, self).__init__(name)

        # Fill ParsedTest (self) using the TestScript generator.
        ts = TestScript (self, includedirs)
        ts.add_chunk ('runtime/header', '_schema_chunk_test.json')
        ts.add_chunk (board_chunk, '_schema_chunk_board.json')
        ts.add_chunk (test_chunk, '_schema_chunk_test.json')
        ts.add_chunk ('runtime/footer', '_schema_chunk_test.json')

        # Process the parameter-default-override directive
        for p, v in self.parameter_overrides.items():
            if not p in self.parameters:
                raise GenException(
                    'Unknown parameter on "#|parameter-default-override": {} (override value is: "{}")'
                        .format(p, v))
            self.parameters[p]['default'] = v

        # Append job specific properties (decription as of now).
        # "test_chunk_path" won't be None if TestScript didn't bail out
        test_chunk_path = try_find_chunk_fullpath (includedirs, test_chunk)
        jsprops = parse_json(
            test_chunk_path + '.json',
            thisfile_dirname_join ('_schema_chunk_test.json'))
        desc = from_strlist (jsprops.get ('description') or '')

        # Add labels
        for label in extra_labels:
            self.labels[label] = True

        # Verify environment variables
        bd = BoardData ('dummyname', includedirs, board_chunk, [])
        for ev in self.required_board_envvars:
            if not ev in bd.envvars:
                raise GenException(
                    'Board "{}" is missing a required environment variable: {}'
                        .format(board_chunk, ev))

        # Parametrize
        for file in param_files:
            tp = parse_json (file, thisfile_dirname_join ('_schema_param_test.json'))
            self.add_parametrization (tp, file)

    def add_parametrization (self, test_params, from_file):
        for label in test_params.get('test-labels-extra') or []:
            self.labels[label] = True

        overrides = test_params.get('parameter-default-overrides') or {}
        for name, default in (overrides).items():
            if not self.parameters.get (name):
                raise GenException(
                    '{}: test parametization parameter "{}" doesn\'t exist on the test'
                        .format(from_file, name))
            self.parameters[name]['default'] = from_strlist (default)

    def get_jenkins_xml(self):
        xmlbuild = JenkinsJobXml()
        xmlbuild.add_job(self)
        return str(xmlbuild)

class PipelineTest(object):
    def __init__(self):
        self.params = {}

class ParsedPipeline(object):
    def __init__(self):
        self.timer_expr = ''
        self.tests = {}
        self.serial_seqs = {}
        self.execution = []
        self.script = ''

    def _add_test_if_new(self, name):
        if name not in self.tests:
            self.tests[name] = PipelineTest()

    def __str__(self):
        s  =         '[timer_expr ] {}\n'.format (self.timer_expr)
        #s +=         '[script     ] {}\n'.format (self.script)
        s +=         '[tests      ] {}\n'.format (len (self.tests))
        for t, v in self.tests.items():
            s +=     '[testname   ] {}\n'.format (t)
            s +=     '[testparams ] {}\n'.format (len (v.params))
            for p, v in v.params.items():
                s += '[testparam  ] [{}] {}\n'.format (p, v)
        s +=         '[serial_seqs] {}\n'.format (len (self.serial_seqs))
        for n, v in self.serial_seqs.items():
            s +=     '[serial_seq ] [{}] {}\n'.format (n, len (v))
            for t in v:
                s += '[serial_seq ] [{}] {}\n'.format (n, t)

        s +=         '[executions ] {}\n'.format (len (self.execution))
        for n, v in enumerate(self.execution):
            s +=     '[execution  ] [{}] {}\n'.format (n, len (v))
            for t in v:
                s += '[execution  ] [{}] {}\n'.format (n, t)
        return s

class JenkinsPipelineXml(object):
    '''Jenkins pipeline xml generator'''
    def __init__(self, parsed_pipeline):
        # Taken from a configured node.
        root = ET.Element('flow-definition')
        root.attrib['plugin'] = 'workflow-job@2.22'

        ET.SubElement(root, 'actions')

        ET.SubElement(root, 'description')

        keepDependencies = ET.SubElement(root, 'keepDependencies')
        keepDependencies.text = 'false'

        properties = ET.SubElement(root, 'properties')
        timerexpr = parsed_pipeline.timer_expr
        if timerexpr is not None and timerexpr != '':
            ptjp = ET.SubElement(
                properties,
                'org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>')
            triggers = ET.SubElement(ptjp, 'triggers')
            timer_trigger = ET.SubElement(triggers, 'hudson.triggers.TimerTrigger')
            spec = ET.SubElement(timer_trigger, 'spec')
            spec.text = timerexpr

        definition = ET.SubElement(root, 'definition')
        definition.attrib['class'] = 'org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition'
        definition.attrib['plugin'] = 'workflow-cps@2.54'

        script = ET.SubElement(definition, 'script')
        script.text = parsed_pipeline.script

        sandbox = ET.SubElement(definition, 'sandbox')
        sandbox.text = 'true'

        ET.SubElement(root, 'triggers')

        disabled = ET.SubElement(root, 'disabled')
        disabled.text = 'false'

        self.root = root

    def __str__(self):
        return dom_parse_str(
            ET.tostring (self.root, encoding='utf8', method='xml')
                ).toprettyxml()

class PipelineData(ParsedPipeline):
    '''Pipeline data generator, just adds methods to ParsedPipeline.'''
    def __init__(self, pipeline_file, root_folder):
        super (PipelineData, self).__init__()

        pljson = parse_json(
           pipeline_file, thisfile_dirname_join('_schema_pipeline.json'))

        # Parse json
        self.timer_expr = pljson.get("jenkins-cron-expression") or ''

        # Substitute all parameters on parametrized-tests
        for test, par in (pljson.get("parametrized-tests") or {}).items():
            t = PipelineTest()
            t.params = par
            test = jenkins_path_join (root_folder, test)
            self.tests[test] = t

        # Iterate both execution sequences registering all the tests names found
        # so they can be validated later.
        for name, tests in (pljson.get("serial-execution-sequences") or {}).items():
            self.serial_seqs[name] = []
            for test in tests:
                test = jenkins_path_join (root_folder, test)
                self._add_test_if_new (test)
                self.serial_seqs[name].append (test)

        for seq_item in pljson["main-execution-sequence"]:
            if not isinstance (seq_item, list):
                seq_item = [ seq_item ]

            with_root_folder = []
            for item in seq_item:
                if item not in self.serial_seqs:
                    # Item is a test
                    item = jenkins_path_join (root_folder, item)
                    self._add_test_if_new (item)
                with_root_folder.append (item)

            self.execution.append(with_root_folder)

        self._build_groovy_script()

    def _build_groovy_script(self):
        # As of now PipeLines can't be configured to fail individual stages and
        # continue while showing a clear report on the "stage view". Either a
        # build failure breaks the or propagate: false is set and and everything
        # always succeeds.
        #
        # We set propagate:false and handle the build status and (primitive)
        # reporting ourselves. This means that the "stage view" on the pipeline
        # job will be useless, as it will show all jobs failing or succeeding.
        #
        # This workaround is to be removed in the future Jenkins versions allow
        # it.
        # See https://issues.jenkins-ci.org/browse/JENKINS-26522

        def nl(txt, join='\n'):
            self.script += txt + join

        nl('jobs    = [:]')
        nl('failed  = [:]')
        nl('def add_to_jobs(name, params=[]) {')
        nl('  jobs[name] = {')
        nl('    stage(name) {')
        nl('      def ret = ')
        nl('        build job: name,')
        nl('        parameters: params,')
        nl('        propagate: false')
        nl('      if (ret.getResult() != "SUCCESS") {')
        nl('        currentBuild.result = "FAILURE"')
        nl('        failed[name] = "${ret.getResult()}. URL: ${ret.getAbsoluteUrl()}"')
        nl('      }')
        nl('      return ret')
        nl('    }')
        nl('  }')
        nl('}')

        for name, v in self.tests.items():
            if name.startswith('/'):
                raise GenException(
                    'Invalid test name: "{}". pipeline test names can\'t start with "/"'
                        .format (name))

            if len(v.params) == 0:
                nl('add_to_jobs ("{}")'.format (name))
            else:
                nl('add_to_jobs(')
                nl('  "{}", ['.format (name))
                for p, v in v.params.items():
                    nl('    string(name: "{}", value: "{}"),'.format(p, v))
                nl('  ])')
        nl('')

        nl('def seqs = [:]')
        for seq, vals in self.serial_seqs.items():
            nl('seqs["{}"] = {{'.format (seq))
            nl('  stage("{}"){{'.format (seq))
            for test in vals:
                nl('    jobs["{}"]()'.format (test))
            nl('  }')
            nl('}\n')

        nl('def steps')
        nl('node {')
        idx = 0
        for exec_step in self.execution:
            nl ('  steps = [:]')
            last = len(exec_step) - 1
            for step in exec_step:
                if step not in self.serial_seqs:
                    step = 'jobs["{}"]'.format(step)
                else:
                    step = 'seqs["{}"]'.format(step)
                nl('  steps["{}"] = {{ {}() }}'.format (idx, step))
                idx += 1
            nl ('  parallel steps\n')
        nl('}\n')

        nl('for (def v in failed) {')
        nl('  println "${v.key}: ${v.value}"')
        nl('}\n')

    def get_jenkins_xml (self):
        pxml = JenkinsPipelineXml (self)
        return str (pxml)

class ParsedFolder(object):
    def __str__(self):
        s = '[folder ]'
        return s

class JenkinsFolderXml(object):
    def __str__(self):
        # Folders are totally static, no XML generation.
        return '''\
<?xml version='1.1' encoding='UTF-8'?>
<com.cloudbees.hudson.plugins.folder.Folder plugin="cloudbees-folder@6.6">
  <actions/>
  <description></description>
  <properties>
    <org.jenkinsci.plugins.pipeline.modeldefinition.config.FolderConfig plugin="pipeline-model-definition@1.3.2">
      <dockerLabel></dockerLabel>
      <registry plugin="docker-commons@1.13"/>
    </org.jenkinsci.plugins.pipeline.modeldefinition.config.FolderConfig>
  </properties>
  <folderViews class="com.cloudbees.hudson.plugins.folder.views.DefaultFolderViewHolder">
    <views>
      <hudson.model.AllView>
        <owner class="com.cloudbees.hudson.plugins.folder.Folder" reference="../../../.."/>
        <name>All</name>
        <filterExecutors>false</filterExecutors>
        <filterQueue>false</filterQueue>
        <properties class="hudson.model.View$PropertyList"/>
      </hudson.model.AllView>
    </views>
    <tabBar class="hudson.views.DefaultViewsTabBar"/>
  </folderViews>
  <healthMetrics>
    <com.cloudbees.hudson.plugins.folder.health.WorstChildHealthMetric>
      <nonRecursive>false</nonRecursive>
    </com.cloudbees.hudson.plugins.folder.health.WorstChildHealthMetric>
  </healthMetrics>
  <icon class="com.cloudbees.hudson.plugins.folder.icons.StockFolderIcon"/>
</com.cloudbees.hudson.plugins.folder.Folder>'''

class FolderData(ParsedFolder):
    def get_jenkins_xml (self):
        fxml = JenkinsFolderXml()
        return str (fxml)

# CLI from here below
def dump(dataobj, outtype):
    if outtype == 'script':
        print dataobj.script
    elif outtype == 'xml':
        print dataobj.get_jenkins_xml()
    elif outtype == 'metadata':
        print str(dataobj)

def get_job(args, outtype):
    cdirs = get_common_parser_args (args)
    td = TestData(
        cdirs,
        args.board_chunk,
        args.test_chunk,
        args.extra_label,
        args.param_file)
    dump (td, outtype)

def get_node(args, outtype):
    cdirs = get_common_parser_args (args)
    bd    = BoardData (args.node_name, cdirs, args.board_chunk, args.param_file)
    dump (bd, outtype)

def get_pipeline(args, outtype):
    pd = PipelineData(args.pipeline_file, args.root_folder)
    dump (pd, outtype)

def get_folder(args):
    fd = FolderData()
    print (fd.get_jenkins_xml())

def add_common_chunk_parser_fields(parser):
    parser.add_argument(
        '-c', '--chunk-include',
        action='append',
        required=True,
        help='Adds a chunk include directory. This flag can be repeated.')
    parser.add_argument(
        '-b', '--board-chunk',
        action='store',
        required=True,
        help='Board chunk prefix (no .json or .sh extension)')
    parser.add_argument(
        '-p', '--param-file',
        action='append',
        default=[],
        required=False,
        help='Adds a parametrization file. This flag can be repeated.')

def get_common_parser_args(args):
    cdirs = args.chunk_include
    for cdir in cdirs:
        if not path.exists(cdir):
            sys.stderr.write(
                'Non existant chunk include dir: {}\n'.format(cdir))
            sys.exit(1)

    return cdirs

def add_job_parser(subparsers, cmdname, fn):
    p = subparsers.add_parser(cmdname, help=cmdname + ' help')
    add_common_chunk_parser_fields(p)
    p.add_argument(
        '-t', '--test-chunk',
        action='store',
        required=True,
        help='Board chunk prefix (no .json or .sh extension)')
    p.add_argument(
        '-l', '--extra-label',
        action='append',
        default=[],
        required=False,
        help='Adds an addittional label to include on the resulting job XML. At least a device type label is required (e.g. slsmall, gwen, nb3xx, etc). This flag can be repeated.')
    p.set_defaults(func=fn)

def add_node_parser(subparsers, cmdname, fn):
    p = subparsers.add_parser(cmdname, help=cmdname + ' help')
    add_common_chunk_parser_fields(p)
    p.add_argument(
        '-n', '--node-name',
        action='store',
        required=True,
        help='Jenkins node name')
    p.set_defaults(func=fn)

def add_pipeline_parser(subparsers, cmdname, fn):
    p = subparsers.add_parser(cmdname, help=cmdname + ' help')
    p.add_argument(
        '-p', '--pipeline-file',
        action='store',
        required=True,
        help='JSON pipeline definition file')
    p.add_argument(
        '--root-folder',
        action='store',
        required=False,
        default='',
        help='Folder with which all the referenced jobs on the pipeline file will be prefixed.')
    p.set_defaults(func=fn)

def add_folder_parser(subparsers, cmdname, fn):
    p = subparsers.add_parser(cmdname, help=cmdname + ' help')
    p.set_defaults(func=fn)

def main():
    p = ArgumentParser(
        description='"Hottest" tool to generate Jenkins files')
    subp = p.add_subparsers(help='command help')

    add_job_parser(
        subp, "get-job-script", lambda args: get_job (args, 'script'))
    add_job_parser(
        subp, "get-job-xml", lambda args: get_job (args, 'xml'))
    add_job_parser(
        subp, "get-job-metadata", lambda args: get_job (args, 'metadata'))

    add_node_parser(
        subp, "get-node-xml", lambda args: get_node (args, 'xml'))
    add_node_parser(
        subp, "get-node-metadata", lambda args: get_node (args, 'metadata'))

    add_pipeline_parser(
        subp, "get-pipeline-script", lambda args: get_pipeline (args, 'script'))
    add_pipeline_parser(
        subp, "get-pipeline-xml", lambda args: get_pipeline (args, 'xml'))
    add_pipeline_parser(
        subp,
        "get-pipeline-metadata",
        lambda args: get_pipeline (args, 'metadata'))

    add_folder_parser (subp, "get-folder-xml", get_folder)

    args = p.parse_args()
    args.func (args)

if __name__ == '__main__':
    main()
