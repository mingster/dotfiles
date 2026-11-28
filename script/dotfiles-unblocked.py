#!/usr/bin/env python3
"""Drop issues whose body names an open `Blocked by #N` (same check fleet-watch uses, #1823).

An unreadable reference is kept, so worker-startup refuses the start (fail closed).

Usage: dotfiles-unblocked.py <fleet-watch.py> <repo> <issues-json>
Prints the issues that are not blocked as JSON.
"""
import importlib.util
import json
import sys


def main(argv):
    path, repo, raw = argv[1:4]
    spec = importlib.util.spec_from_file_location('fleet_watch_blockers', path)
    fw = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = fw
    spec.loader.exec_module(fw)
    cache = {}
    keep = []
    for issue in json.loads(raw):
        open_refs, unknown = fw.issue_open_blockers(issue, repo, fw.fetch_ref_state, cache)
        if not open_refs:
            keep.append(issue)
    print(json.dumps(keep))


if __name__ == '__main__':
    main(sys.argv)
