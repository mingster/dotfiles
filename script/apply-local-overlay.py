#!/usr/bin/env python3
"""Print a JSON file merged with an optional untracked local overlay.

Usage: apply-local-overlay.py <base.json> [<overlay.json>]

Objects merge recursively, lists append the overlay items that are not already
present, other values take the overlay. A missing overlay prints the base as is.
Project names, hosts and paths live in the overlay, never in tracked files.
"""
import json
import pathlib
import sys


def merge(base, extra):
    if isinstance(base, dict) and isinstance(extra, dict):
        out = dict(base)
        for key, value in extra.items():
            out[key] = merge(base[key], value) if key in base else value
        return out
    if isinstance(base, list) and isinstance(extra, list):
        return base + [item for item in extra if item not in base]
    return extra


def main(argv):
    if len(argv) not in (2, 3):
        sys.exit(__doc__)
    data = json.loads(pathlib.Path(argv[1]).read_text())
    if len(argv) == 3 and pathlib.Path(argv[2]).is_file():
        data = merge(data, json.loads(pathlib.Path(argv[2]).read_text()))
    print(json.dumps(data, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main(sys.argv)
