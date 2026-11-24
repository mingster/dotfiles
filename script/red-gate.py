#!/usr/bin/env python3
"""File or update the one issue for a broken shared gate, and list the open ones (#1746).

  red-gate.py file --tool <tool> [--repo owner/name] [--output-file F]
  red-gate.py open [--repo owner/name]
  red-gate.py infra-tool [--output-file F]

`file` keeps one open issue `red gate: <tool>` (P1, ready-for-agent). A second failure of the same tool
adds a comment with the failing output instead of a second issue. It prints the issue number.
`open` prints `<number><TAB><tool>` per open red gate issue.
`infra-tool` reads a failed gate's output and prints the tool of its first `infra: <tool>: <reason>`
line (a bare `infra: <reason>` line from the test database preflight names `test-database`), or prints
nothing and exits 1 when the output has no such line, which means a test failure and not a broken gate.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

TITLE_PREFIX = 'red gate: '
LABELS = ('P1', 'ready-for-agent')
OUTPUT_CAP = 6000
INFRA_LINE = re.compile(r'^infra:\s*(?:(?P<tool>[a-z0-9][a-z0-9_.-]*):\s|(?P<bare>\S))', re.M)
DEFAULT_TOOL = 'test-database'
SECRET = re.compile(r'(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|sqlserver)://\S+')
TOOL_OK = re.compile(r'^[a-z0-9][a-z0-9_.-]*$')


def title_for(tool):
    return '%s%s' % (TITLE_PREFIX, tool)


def tool_from_title(title):
    title = str(title or '')
    return title[len(TITLE_PREFIX):] if title.startswith(TITLE_PREFIX) else None


def infra_tool(output):
    """The tool named by the first `infra:` line of a gate's output, or None for a plain failure."""
    match = INFRA_LINE.search(output or '')
    if not match:
        return None
    return match.group('tool') or DEFAULT_TOOL


def clip(output, cap=OUTPUT_CAP):
    text = SECRET.sub('[redacted database URL]', output or '')
    for key, value in os.environ.items():
        if len(value) > 3 and re.search(r'SECRET|TOKEN|PASSWORD|DATABASE_URL|API_KEY', key, re.I):
            text = text.replace(value, '[redacted]')
    return text if len(text) <= cap else '[... cut]\n' + text[-cap:]


def issue_body(tool, output):
    return (
        'The shared gate `%s` is broken: it failed for a reason that is not the code under test.\n\n'
        'Failing output:\n\n```\n%s\n```\n\n'
        '## Acceptance\n'
        '- [ ] `%s` runs again on a PR with no change to it, and the fix names the cause above.\n'
        '- [ ] A test pins the cause.\n'
        '- [ ] bash script/checks-local.sh exits 0.\n\n'
        '## Out of scope\n'
        'Other failures and unrelated cleanup. PRs that hit only this gate wait on this issue.\n'
    ) % (tool, clip(output).rstrip('\n') or '(no output)', tool)


def _gh(args, run):
    return run(['gh'] + args, capture_output=True, text=True, timeout=60, check=True)


def open_gates(repo, run=subprocess.run):
    """{number: tool} of the open red gate issues, or None when gh fails."""
    command = ['issue', 'list', '--state', 'open', '--search', '"%s" in:title' % TITLE_PREFIX.strip(),
               '--json', 'number,title', '--limit', '50']
    if repo:
        command += ['--repo', repo]
    try:
        rows = json.loads(_gh(command, run).stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        return None
    gates = {}
    for row in rows:
        tool = tool_from_title(row.get('title'))
        if tool and TOOL_OK.match(tool):
            gates[int(row['number'])] = tool
    return gates


def file_gate(tool, output, repo=None, run=subprocess.run):
    """Number of the one open issue for this tool, created or commented. None when gh fails."""
    if not TOOL_OK.match(tool or ''):
        return None
    gates = open_gates(repo, run)
    if gates is None:
        return None
    scope = ['--repo', repo] if repo else []
    for number, name in sorted(gates.items()):
        if name == tool:
            body = 'Failed again:\n\n```\n%s\n```\n' % (clip(output).rstrip('\n') or '(no output)')
            try:
                _gh(['issue', 'comment', str(number), '--body', body] + scope, run)
            except (subprocess.SubprocessError, OSError):
                pass  # the open issue exists; a lost comment must not drop the receipt line
            return number
    command = ['issue', 'create', '--title', title_for(tool), '--body', issue_body(tool, output)]
    for label in LABELS:
        command += ['--label', label]
    try:
        out = _gh(command + scope, run).stdout.strip()
        return int(out.rsplit('/', 1)[-1])
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def _read(path):
    if not path:
        return sys.stdin.read() if not sys.stdin.isatty() else ''
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            return handle.read()
    except OSError:
        return ''


def main(argv=None, run=subprocess.run):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    file_p = sub.add_parser('file')
    file_p.add_argument('--tool', required=True)
    file_p.add_argument('--repo')
    file_p.add_argument('--output-file')
    open_p = sub.add_parser('open')
    open_p.add_argument('--repo')
    infra_p = sub.add_parser('infra-tool')
    infra_p.add_argument('--output-file')
    args = parser.parse_args(argv)
    if args.command == 'infra-tool':
        tool = infra_tool(_read(args.output_file))
        if tool is None:
            return 1
        print(tool)
        return 0
    if args.command == 'open':
        gates = open_gates(args.repo, run)
        if gates is None:
            return 1
        for number, tool in sorted(gates.items()):
            print('%d\t%s' % (number, tool))
        return 0
    number = file_gate(args.tool, _read(args.output_file), args.repo, run)
    if number is None:
        return 1
    print(number)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
