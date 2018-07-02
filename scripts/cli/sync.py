#!/usr/bin/env python

import jenkins
import fnmatch
import re
from os import path, makedirs, walk
from datetime import datetime
from argparse import ArgumentParser

from _cli_common import *
import gen

class JenkinsWrapper(jenkins.Jenkins):
    ''' Just wraps calls to jenkins.Jenkins, but the calls take objects that
    implement  "get_jenkins_xml()" instead of xml strings, so we are able to
    implement diferent types of output'''
    def __init__(self, *args, **kwargs):
        super (JenkinsWrapper, self).__init__(*args, **kwargs)

    def create_node (self, *args, **kwargs):
        super (JenkinsWrapper, self).create_node(*args, **kwargs)

    def reconfig_node (self, name, board_data):
        super (JenkinsWrapper, self).reconfig_node(
            name, board_data.get_jenkins_xml())

    def reconfig_job (self, name, job_data):
        super (JenkinsWrapper, self).reconfig_job(
            name, job_data.get_jenkins_xml())

    def create_job (self, name, job_data):
        super (JenkinsWrapper, self).create_job(
            name, job_data.get_jenkins_xml())

class DryRunJenkins(jenkins.Jenkins):
    ''' A Jenkins instance with patched interface functions resulting in a
    do-nothing Jenkins instance'''
    def __init__(self, *args, **kwargs):
        super (DryRunJenkins, self).__init__(*args, **kwargs)
        self.dump_type = ''

    def create_node (self, *args, **kwargs):
        pass

    def reconfig_node (self, name, data):
        self._dump_data (name, data)

    def reconfig_job (self, name, data):
        self._dump_data (name, data)

    def create_job (self, name, data):
        self._dump_data (name, data)

    def _dump_data(self, name, data):
        if self.dump_type == 'xml':
            print ('---XML dump for: "{}"'.format(name) + ("-") * 20)
            print(data.get_jenkins_xml())
        elif self.dump_type == 'metadata':
            print ('---Metadata for: "{}"'.format(name) + ("-") * 20)
            print (str (data))

def thisfile_dirname_join(name):
    return path.join (path.dirname (path.realpath (__file__)), name)

class SyncException(Exception):
    def __init__(self, msg=''):
        self.msg = msg
        super(SyncException, self).__init__(self.msg)
    def __str__(self):
        return repr(self.msg)

def is_in_whitelist(name, whitelist):
    if len (whitelist)==0:
        return True
    for regex in whitelist:
        try:
            if re.search (regex, name):
                return True
        except Exception as e:
            raise type(e) ('On whitelist filter with regex "{}": {}'
                .format (regex, e.message))
    return False

class GenGetJobDataArgs(object):
    '''Collection of arguments for "gen.get_job_data" call'''
    def __init__(self):
        self.extra_labels = []
        self.param_files = []
        self.name = None
        self.board_chunk = None
        self.test_chunk = None
        self.inline_parametrization = None

class GenGetPipelineDataArgs(object):
    '''Collection of arguments for "gen.get_pipeline_data" call'''
    def __init__(self):
        self.name        = None
        self.file        = None
        self.root_folder = ''

class GenGetNodeDataArgs(object):
    '''Collection of arguments for "gen.get_node_data" call'''
    def __init__(self):
        self.param_files = []
        self.name = None
        self.board_chunk = None
        self.inline_parametrization = None

def try_find_suffix_in_dirs(suffix, param_dirs):
    for d in param_dirs:
        f = path.join (d, suffix)
        if path.exists (f):
            return f
    return None

def build_job_arglists(syncjson, root_folder, chunk_dirs, param_dirs):
    '''Builds an array of GenGetJobDataArgs from the tests of a given sync
    file.'''
    arglist = []
    tests = syncjson.get ('tests')
    if tests is None:
        return arglist

    for name, data in tests.items():
        name = jenkins_path_join (name) # canonicalization
        args = GenGetJobDataArgs()
        args.name = jenkins_path_join (root_folder, name)
        args.board_chunk = data['board-chunk']
        args.test_chunk = data['test-chunk']
        args.extra_labels = data.get ('extra-labels') or []
        for fsuffix in data.get ('parametrization-files') or []:
            pf = try_find_suffix_in_dirs (fsuffix, param_dirs)
            if pf is None:
                raise SyncException(
                    'on test {}. unable to find parametrization file with suffix: {}'
                        .format (name, fsuffix))
            args.param_files.append(pf)
        args.inline_parametrization = data.get ('parametrization-inline') or {}
        arglist.append(args)

    return arglist

def build_pipeline_arglists(syncjson, root_folder, pipeline_dirs):
    '''Builds an array of GenGetPipelineDataArgs from the pipelines of a given
    sync file.'''
    arglist = []
    pipelines = syncjson.get ('pipelines')
    if pipelines is None:
        return arglist

    for name, data in pipelines.items():
        name = jenkins_path_join (name) # canonicalizations
        args = GenGetPipelineDataArgs()
        args.name = jenkins_path_join (root_folder, name)
        fsuffix = data['file']
        args.file = try_find_suffix_in_dirs (fsuffix, pipeline_dirs)
        args.root_folder = jenkins_path_join (root_folder) #canonicalization
        if args.file is None:
            raise SyncException(
                'on pipeline {}. unable to find pipeline file with suffix: {}'
                    .format(name, fsuffix))
        arglist.append(args)

    return arglist

def build_node_arglists(syncjson, chunk_dirs, param_dirs):
    '''Builds an array of GenGetNodeDataArgs from the pipelines of a given
    sync file.'''
    arglist = []
    nodes = syncjson.get ('nodes')
    if nodes is None:
        return arglist

    for name, data in nodes.items():
        args = GenGetNodeDataArgs()
        args.name = name
        args.board_chunk = data['board-chunk']
        for fsuffix in data.get ('parametrization-files') or []:
            pf = try_find_suffix_in_dirs (fsuffix, param_dirs)
            if pf is None:
                raise SyncException(
                    'on node {}. unable to find parametrization file with suffix: {}'
                        .format (name, fsuffix))
            args.param_files.append(pf)
        args.inline_parametrization = data.get ('parametrization-inline') or {}
        arglist.append(args)

    return arglist

class JenkinsSync(object):
    def __init__(self, name, data):
        self.name = name
        self.data = data

JENKINS_TEST_CLASS = 'hudson.model.FreeStyleProject'
JENKINS_PIPELINE_CLASS = 'org.jenkinsci.plugins.workflow.job.WorkflowJob'
JENKINS_FOLDER_CLASS = 'com.cloudbees.hudson.plugins.folder.Folder'

def srv_add_folder(srv, paths_set, folder):
    folder = jenkins_path_join (folder) # canonicalization
    if folder == '' or folder in paths_set:
        return False

    current = '/'
    for new in folder.split('/'):
        current = jenkins_path_join (current, new)
        if current not in paths_set:
            srv.create_job (current, gen.FolderData())
            # Add to the set, so next calls don't try to create the same folder.
            paths_set[current] = True
    return True

def srv_sync_jobs(srv, syncjobs, jobclass, full_jobset, validation_fn=None):
    '''syncs already generated Jenkins jobs (syncjobs) on a Jenkins instance
    (src). Notice that pipelines are jobs from the Jenkins point of view'''
    jjobs = srv.get_jobs()
    srvjobs = {
        JENKINS_TEST_CLASS : {},
        JENKINS_PIPELINE_CLASS : {},
        JENKINS_FOLDER_CLASS : {},
    }
    def iterate_jobs(folder, jobs):
        for job in jobs:
            name = jenkins_path_join (folder, job['name'])
            srvjobs[job['_class']][name] = False

            if job['_class'] == JENKINS_FOLDER_CLASS:
                iterate_jobs (name , job['jobs'])
                continue

    iterate_jobs ('/', jjobs)

    for job in syncjobs:
        name = job.name

        if validation_fn:
            if not validation_fn (job, srvjobs):
                print('job "{}": failed validation. Skipping'.format (name))
                continue

        dirsplit = name.rsplit ('/', 1)
        if len (dirsplit) == 2:
            if srv_add_folder (srv, srvjobs[JENKINS_FOLDER_CLASS], dirsplit[0]):
                print ('job "{}": added non-existent Jenkins folder: "{}"'
                    .format (name, dirsplit[0]))

        if name in (srvjobs.get (jobclass) or {}):
            srvjobs[jobclass][name] = True
            print('job "{}": updating'.format(name))
            srv.reconfig_job (name, job.data)
        else:
            print('job "{}": creating'.format(name))
            srv.create_job (name, job.data)

    for job, was_updated in (srvjobs.get (jobclass) or {}).items():
        # TODO force remove flag?
        if not was_updated and job not in full_jobset:
            print(
                'WARNING. Unreferenced job "{}" exists on server'.format (job))

def gen_and_sync_tests(
        srv, syncjson, root_folder, chunk_dirs, param_dirs, whitelist):

    jobdata_arglist = build_job_arglists(
        syncjson, root_folder, chunk_dirs, param_dirs)

    if len(jobdata_arglist) == 0:
        print ("sync definition file contains no jobs")

    full_jobset = {}

    syncjobs = []
    for args in jobdata_arglist:
        name = args.name
        full_jobset[name] = True

        if not is_in_whitelist (name, whitelist):
            continue

        print('job "{}": generating'.format(name))

        td = gen.TestData(
            chunk_dirs,
            args.board_chunk,
            args.test_chunk,
            args.extra_labels,
            args.param_files)

        td.add_parametrization(
            args.inline_parametrization,
            'sync\'s "parametrization-inline" for "{}"'.format (name))

        syncjobs.append (JenkinsSync (name, td))

    srv_sync_jobs (srv, syncjobs, JENKINS_TEST_CLASS, full_jobset)

def get_job_params(srv, jobname):
    defs = {}
    for pr in srv.get_job_info (jobname)['property']:
        if pr['_class'] == 'hudson.model.ParametersDefinitionProperty':
            for pd in pr['parameterDefinitions']:
                defs[pd['name']] = True
            break

    return defs

def pipeline_validation(job, jobset, srv, pipelinedata_dict):
    name = job.name
    for tname, v in pipelinedata_dict[name].tests.items():
        if tname not in (jobset.get(JENKINS_TEST_CLASS) or {}):
            print(
                'WARNING: On pipeline "{}". Non-existant job in server or serial branch: "{}". This WARNING can be ignored on a dry-run.'
                    .format(name, tname))
        else:
            paramdefs = get_job_params (srv, tname)
            for param, val in v.params.items():
                if param not in paramdefs:
                    print(
                        'WARNING: pipeline "{}". Non-existant parameter in test "{}": "{}"'
                            .format (name, tname, param))
    return True # Always succeed, just show warnings

def gen_and_sync_pipelines(
        srv, syncjson, root_folder, pipeline_dirs, whitelist):

    pipelinedata_arglist = build_pipeline_arglists(
        syncjson, root_folder, pipeline_dirs)

    if len(pipelinedata_arglist) == 0:
        print ("sync definition file contains no pipelines")

    pddict = {}
    full_jobset = {}
    syncpipelines = []

    for args in pipelinedata_arglist:
        name = args.name
        full_jobset[name] = True
        if not is_in_whitelist (name, whitelist):
            continue

        print('pipeline "{}": generating'.format(name))
        pd = gen.PipelineData (args.file, args.root_folder)
        pddict[name] = pd
        syncpipelines.append (JenkinsSync (name, pd))

    srv_sync_jobs(
        srv,
        syncpipelines,
        JENKINS_PIPELINE_CLASS,
        full_jobset,
        lambda name, jobset: pipeline_validation (name, jobset, srv, pddict))

def srv_sync_nodes(srv, syncnodes, whitelist):
    '''syncs already generated Jenkins nodes (syncnodes)on a Jenkins instance
    (srv).'''
    jnodes = srv.get_nodes()
    node_updated = {}

    for node in jnodes:
        name = node['name']
        if name == 'master' or not is_in_whitelist (name, whitelist):
            continue
        node_updated[name] = False

    for node in syncnodes:

        name = node.name
        if not is_in_whitelist (name, whitelist):
            continue

        if name in node_updated:
            node_updated[name] = True
            print('node "{}": updating'.format(name))
        else:
            print('node "{}": creating'.format(name))
            # Transient state, this interface doesn't allow to create nodes
            # directly from XML that e.g. you saved before. Workarounding it.
            srv.create_node(
                name,
                remoteFS='/tmp/nodecreate',
                exclusive=True,
                launcher=jenkins.LAUNCHER_COMMAND,
                launcher_params = { "command": gen.JENKINS_NODE_CMD }
                )

        srv.reconfig_node (name, node.data)

    for node, updated in node_updated.items():
        # TODO force remove flag?
        if not updated:
            print(
                'WARNING. Unreferenced node "{}" exists on server'.format(node))

def gen_and_sync_nodes(srv, syncjson, chunk_dirs, param_dirs, whitelist):
    nodedata_arglist = build_node_arglists (syncjson, chunk_dirs, param_dirs)
    if len(nodedata_arglist) == 0:
        print ("sync definition file contains no nodes")

    syncnodes = []
    for args in nodedata_arglist:
        name = args.name
        if name == 'master':
            raise SyncException ('node name "master" is reserved')

        if not is_in_whitelist (name, whitelist):
            continue

        print('node "{}": generating'.format(name))
        bd = gen.BoardData(
            name, chunk_dirs, args.board_chunk, args.param_files)
        bd.add_parametrization(
            args.inline_parametrization,
            'sync\'s "parametrization-inline" for "{}"'.format (name))
        syncnodes.append (JenkinsSync (name, bd))

    srv_sync_nodes (srv, syncnodes, whitelist)

def build_backup(srv, syncfile, whitelist):
    '''builds a backup of the current server\'s jobs and nodes'''
    folder = 'hottest.bak/{}-{}'.format(
        path.basename (syncfile), datetime.now().strftime('%Y-%m-%d_%H-%M-%S'))

    jobfolder = path.join (folder, 'jobs')
    nodefolder = path.join (folder, 'nodes')
    pipelinefolder = path.join (folder, 'pipelines')

    makedirs (jobfolder)
    makedirs (nodefolder)
    makedirs (pipelinefolder)

    print ('backing up server state to folder: "{}"'.format (folder))

    jjobs = srv.get_jobs()

    def iterate_jobs(rootfolder, jobs):
        for job in jobs:
            name = jenkins_path_join (rootfolder, job['name'])

            if job['_class'] == JENKINS_FOLDER_CLASS:
                iterate_jobs (name, job['jobs'])
                continue

            if not is_in_whitelist (name, whitelist):
                continue

            dstbase = jobfolder
            if job['_class'] == JENKINS_PIPELINE_CLASS:
                dstbase = pipelinefolder

            dstfolder = path.join (dstbase, path.dirname (name))
            if not path.exists (dstfolder):
                makedirs(dstfolder)

            xml = srv.get_job_config (name)
            with open (path.join(dstbase, name + '.xml'), "w") as f:
                f.write(xml)

    iterate_jobs('', jjobs)

    jnodes = srv.get_nodes()
    for node in jnodes:
        name = node['name']
        if name == 'master' or not is_in_whitelist (name, whitelist):
            continue
        xml  = srv.get_node_config(name)
        with open(path.join(nodefolder, name + '.xml'), "w") as f:
            f.write(xml)

    print ("backup done")

def build_jenkins_sync(rpath, basedir, filterexpr):
    '''builds a list of "JenkinsSync" operations by globing the files present
    on a directory (e.g. backup)'''

    sync = []
    startpath = path.join (path.abspath (rpath), basedir)
    for root, dirs, files in walk (startpath):
        for file in fnmatch.filter (files, filterexpr):
            name = path.splitext (file)[0]
            jenkinspath = root[len (startpath) + 1:]

            if jenkinspath != '' and jenkinspath != '/':
                name = jenkinspath + '/' + name

            with open (path.join (root, file), 'r') as f:
                sync.append (JenkinsSync (name, f.read()))
    return sync

def revert_from_backup(srv, rpath):
    nodes = build_jenkins_sync (rpath, 'nodes', '*.xml')
    jobs  = build_jenkins_sync (rpath, 'jobs', '*.xml')
    pipelines = build_jenkins_sync (rpath, 'pipelines', '*.xml')

    if len (nodes) == 0 and len (jobs) == 0 and len (pipelines) == 0:
        print(
            'No .xml files found under the "nodes", "jobs" or "pipelines" subdirectories of "{}"'
                .format(rpath, rpath))
        return

    srv_sync_nodes (srv, nodes, [])
    srv_sync_jobs (srv, jobs, [], JENKINS_TEST_CLASS)
    srv_sync_jobs (srv, pipelines, [], JENKINS_PIPELINE_CLASS)

def jenkins_sync(
        srv,
        syncfile,
        root_folder,
        chunk_dirs,
        param_dirs,
        pipeline_dirs,
        mode,
        whitelist):

    sync = parse_json(syncfile, thisfile_dirname_join('_schema_sync.json'))
    if 'b' in mode:
        build_backup (srv, syncfile, whitelist)
    if 'n' in mode:
        gen_and_sync_nodes (srv, sync, chunk_dirs, param_dirs, whitelist)
    if 't' in mode:
        gen_and_sync_tests(
            srv, sync, root_folder, chunk_dirs, param_dirs, whitelist)
    if 'p' in mode:
        gen_and_sync_pipelines(
            srv, sync, root_folder, pipeline_dirs, whitelist)

def append_subdirs(dirlist, subdir):
    dirs = []
    for d in dirlist:
        if not path.isdir (d):
            raise SyncException ("Path is not a directory: \"{}\"".format (d))
        dirs.append (path.join (d, subdir))
    return dirs

def run_sync(args):
    if args.dry_run or args.dry_run_xml or args.dry_run_metadata:
        srvtype = DryRunJenkins
        args.mode = args.mode.replace ('b','') # don't backup on dry runs
    else:
        srvtype = JenkinsWrapper

    srv = srvtype(
        args.jenkins_url, username=args.jenkins_user, password=args.jenkins_pwd)

    if args.dry_run_xml:
        srv.dump_type = 'xml'

    if args.dry_run_metadata:
        srv.dump_type = 'metadata'

    cki = args.chunk_include
    pri = args.parametrization_include
    ppi = args.pipeline_include

    cki += append_subdirs (args.include, 'chunks')
    pri += append_subdirs (args.include, 'parametrization')
    ppi += append_subdirs (args.include, 'pipelines')

    if len (cki) == 0:
        raise SyncException ('No chunk include dir was passed.')

    jenkins_sync(
        srv,
        args.sync_file,
        args.root_folder,
        cki,
        pri,
        ppi,
        args.mode,
        args.item_whitelist)

    if args.dry_run or args.dry_run_xml:
        print('\nWARNING: "dry-run" was enabled. No modifications were done.')

def run_revert(args):
    srv = jenkins.Jenkins(
        args.jenkins_url, username=args.jenkins_user, password=args.jenkins_pwd)
    revert_from_backup (srv, args.backup_path)

def main():
    p = ArgumentParser('syncs with a Jenkins server')

    p.add_argument(
        'jenkins_url', # Positional argument
        action='store',
        help='Jenkins URL, e.g.: ')

    p.add_argument(
        'jenkins_user', # Positional argument
        action='store',
        help='Jenkins User')

    p.add_argument(
        'jenkins_pwd', # Positional argument
        action='store',
        help='Jenkins Password or Authentication token')

    subp  = p.add_subparsers(help='command help')
    syncp = subp.add_parser('sync', help='sync help')

    syncp.add_argument(
        '-f', '--sync-file',
        action='store',
        required=True,
        help='Sync file path')

    syncp.add_argument(
        '-c', '--chunk-include',
        action='append',
        default=[],
        required=False,
        help='Adds a chunk include directory. This flag can be repeated.')

    syncp.add_argument(
        '-p', '--parametrization-include',
        action='append',
        default=[],
        required=False,
        help='Adds a parametrization include directory. This flag can be repeated.')

    syncp.add_argument(
        '-t', '--pipeline-include',
        action='append',
        default=[],
        required=False,
        help='Adds a pipeline (testplan) include directory. This flag can be repeated.')

    syncp.add_argument(
        '-I', '--include',
        action='append',
        default=[],
        required=False,
        help='Adds a structured include directory that may contain chunks, parametrization and pipelines within a subdirectory whith the same name of the folder pointed by this flag. This flag can be repeated.')

    syncp.add_argument(
        '-m', '--mode',
        action='store',
        required=False,
        default='btnp',
        help="String of chars with enabled sync operations. 't': tests, 'p': pipelines, 'n': nodes, 'b' backup")

    syncp.add_argument(
        '-w', '--item-whitelist',
        action='append',
        default=[],
        required=False,
        help='Adds an item to the whitelist of items to sync. Items can be nodes, tests or pipelines. This flag can be repeated.')

    syncp.add_argument(
        '--dry-run',
        action='store_true',
        required=False,
        default=False,
        help='Doesn\'t issue modifications on the remote jenkins server.')

    syncp.add_argument(
        '--dry-run-xml',
        action='store_true',
        required=False,
        default=False,
        help='Doesn\'t issue modifications on the remote jenkins server. Dumps the generated XML on stdout')

    syncp.add_argument(
        '--dry-run-metadata',
        action='store_true',
        required=False,
        default=False,
        help='Doesn\'t issue modifications on the remote jenkins server. Dumps parseable metadata on stdout')

    syncp.add_argument(
        '-r', '--root-folder',
        action='store',
        required=False,
        default='test',
        help='Places (or extracts) all the jobs under a given folder. "/" means on the Jenkins root)')

    syncp.set_defaults(func=run_sync)

    revertp = subp.add_parser('revert', help='revert help')
    revertp.add_argument(
        '-b', '--backup-path',
        action='store',
        required=True,
        help='Root of the backed up path.')
    revertp.set_defaults(func=run_revert)

    args = p.parse_args()
    args.func (args)

if __name__ == '__main__':
    main()
