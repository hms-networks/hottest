import json
import jsonschema
import re
from os import path

def _remove_dict_comments (d, comment_key='#|comment'):
    r = {}
    for k, v in d.items():
        if k == comment_key:
            continue
        if type(v) is dict:
            r[k] = _remove_dict_comments(v)
        elif type(v) is list:
            r[k] = []
            for lv in v:
                r[k].append(
                    lv if type (lv) is not dict else _remove_dict_comments (lv))
        else:
            r[k] = v
    return r

def _substitute_refs (root, d, travelled={}, refdict_key='refs'):
    r = {}
    for k, v in d.items():
        match = re.match (r'^#\|ref *: *([A-Za-z][A-Za-z0-9_-]*) *$', k)
        if match is None or not match.group(1):
            # Not a ref, regular data
            if type(v) is dict:
                ok, ret = _substitute_refs (root, v, travelled.copy())
                if not ok:
                    return ok, ret
                r[k] = ret
            else:
                r[k] = v
            continue
        # ref field
        ref = match.group (1)
        if (root.get (refdict_key) is None or
                root[refdict_key].get (ref) is None):
            return False, 'definition is missing referenced field: [{}][{}]'.format (refdict_key, ref)

        if ref in travelled:
            return False, 'definition has a circular reference to field: [{}][{}]'.format (refdict_key, ref)

        tr      = travelled.copy()
        tr[ref] = True
        ok, ret = _substitute_refs (root, root[refdict_key][ref], tr)
        if not ok:
            return ok, ret
        r.update (ret)
    return True, r

def parse_json(filename, schema_filename=None):
    def _parse_json(filename):
        try:
            with open (filename) as f:
                return json.load(f)

        except ValueError as ex:
            raise ValueError('On file: "{}"\n'.format(filename) + str(ex))
    f = _parse_json (filename)

    if type(f) is dict:
        f = _remove_dict_comments (f)
        ok, f = _substitute_refs (f, f)
        if not ok:
            raise ValueError ('On file: "{}": {}'.format (filename, f))

    if schema_filename is not None:
        s = _parse_json (schema_filename)
        try:
            resolver = jsonschema.RefResolver(
                'file://{}/'.format (path.dirname(schema_filename)), s)
            jsonschema.Draft4Validator (s, resolver=resolver).validate (f)
        except jsonschema.exceptions.ValidationError as ex:
            raise ValueError(
                'On file: "{}" using schema "{}"\n'.format(
                    filename, schema_filename) + str(ex))
    return f

def try_find_chunk_fullpath(includedirs, chunk_path):
    for d in includedirs:
        prefix = path.join (d, chunk_path)
        json   = prefix + '.json'
        sh     = prefix + '.sh'
        if path.exists(json) and path.exists(sh):
            return prefix
    return None


def jenkins_path_join (path, addpath = ''):
    r = re.sub (r'/+','/', path + '/' + addpath)
    r = r[:-1] if r.endswith ('/') else r
    return r[1:] if r.startswith ('/') else r

def from_strlist(ms):
    '''on the json files sometimes strings are specified as arrays of string
       to allow line breaking. This is the function to parse them.'''
    return ' '.join (ms) if isinstance (ms, list) else ms
