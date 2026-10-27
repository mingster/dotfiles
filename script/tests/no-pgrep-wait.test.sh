#!/usr/bin/env bash
# A `pgrep -f` pattern matches the waiter's own command line, so a loop on it waits forever.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/../.." && pwd)" <<'PY'
import pathlib, re, sys, tempfile
DIRS = ['script', 'templates', '.agents/skills', '.agents/claude']
LOOP = re.compile(r'^\s*(while|until)\b')
DONE = re.compile(r'^\s*done\b')


def scan(root):
    hits = []
    for d in DIRS:
        for path in sorted((root / d).rglob('*')):
            if not path.is_file() or path.name == 'no-pgrep-wait.test.sh':
                continue
            try:
                lines = path.read_text().splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            depth = 0
            for number, line in enumerate(lines, 1):
                if LOOP.match(line):
                    depth += 1
                elif depth and DONE.match(line):
                    depth -= 1
                    continue
                if 'pgrep -f' in line and (depth or re.search(r'\b(while|until)\b.*pgrep -f', line)):
                    hits.append(f'{path.relative_to(root)}:{number}')
    return hits


passed = failed = 0
with tempfile.TemporaryDirectory() as temp:
    fixture = pathlib.Path(temp)
    for d in DIRS:
        (fixture / d).mkdir(parents=True)
    (fixture / 'script/bad.sh').write_text('while pgrep -f "x y"; do sleep 1; done\n')
    (fixture / 'templates/bad.md').write_text('until ! pgrep -f job\ndo\n  sleep 1\ndone\n')
    (fixture / 'script/ok.sh').write_text('pgrep -f once\nwhile true; do sleep 1; done\n')
    found = scan(fixture)
    if found == ['script/bad.sh:1', 'templates/bad.md:1']:
        passed += 1; print('ok   lint flags pgrep -f inside while and until loops only')
    else:
        failed += 1; print('FAIL lint fixture', found)
found = scan(pathlib.Path(sys.argv[1]))
if not found:
    passed += 1; print('ok   no pgrep -f inside a while or until loop')
else:
    failed += 1; print('FAIL pgrep -f inside a wait loop:', *found, sep='\n')
print(f'passed {passed}, failed {failed}')
sys.exit(bool(failed))
PY
