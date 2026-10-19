#!/usr/bin/env python3
"""Print an IDE settings file (JSONC, comments allowed) with list items from an untracked overlay.

Usage: apply-ide-overlay.py <settings.json> [<overlay.json>]

Only string list keys are supported, such as cSpell.userWords. Each overlay item
missing from the tracked list is inserted right after the opening line of that
list, so the rest of the tracked file stays byte for byte. A missing overlay
prints the file as is. Project words live in the overlay, never in tracked files.
"""
import json
import pathlib
import sys


def main(argv):
    if len(argv) not in (2, 3):
        sys.exit(__doc__)
    text = pathlib.Path(argv[1]).read_text()
    if len(argv) == 3 and pathlib.Path(argv[2]).is_file():
        overlay = json.loads(pathlib.Path(argv[2]).read_text())
        lines = text.split('\n')
        for key, items in overlay.items():
            opener = '"' + key + '": ['
            at = next((i for i, line in enumerate(lines) if line.strip() == opener), None)
            if at is None or not isinstance(items, list):
                continue
            end = next(i for i in range(at, len(lines)) if lines[i].strip().startswith(']'))
            present = '\n'.join(lines[at:end])
            indent = lines[at][:len(lines[at]) - len(lines[at].lstrip())] + '  '
            add = [indent + json.dumps(item) + ',' for item in items if json.dumps(item) not in present]
            lines[at + 1:at + 1] = add
        text = '\n'.join(lines)
    sys.stdout.write(text)


if __name__ == '__main__':
    main(sys.argv)
