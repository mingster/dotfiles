#!/usr/bin/env python3
"""PR body gate shared by fleet-watch and ship.sh.

A builder may finish only when Acceptance has no unchecked box and ## Self-check
names a command and a line of output.
"""
import re
import sys

_ACCEPT_HEAD = re.compile(r'^(?:## Acceptance(?: criteria)?\b|\*\*Acceptance(?: criteria)?:\*\*)', re.I)
_ANY_HEAD = re.compile(r'^(?:## |\*\*[^*]+:\*\*)')
_SELF_HEAD = re.compile(r'^## Self-check\b', re.I)
_UNCHECKED = re.compile(r'^[ \t]*- \[ \]')
_COMMAND = re.compile(
    r'(?:^\$\s+\S)|(?:^Command:\s*\S)|(?:\b(?:bash|sh|python3?|pytest|bun|npm|gh|git)\b)',
    re.I,
)
_ACCEPT_ISSUE = re.compile(
    r'(?:^|\b)#([0-9]+)\s+acceptance\b|^##\s+Acceptance(?: criteria)?\s*\(\s*#([0-9]+)\s*\)',
    re.I | re.M,
)
_ISSUE_LINK_FMT = (
    r'\b(?:Closes|Closed|Close|Fixes|Fixed|Fix|Resolves|Resolved|Resolve|Refs)\s+(?:[A-Za-z0-9_./-]+)?#%s\b'
)


def _section(body, start_re):
    lines = (body or '').splitlines()
    start = None
    for index, line in enumerate(lines):
        if start_re.match(line.strip()):
            start = index + 1
            break
    if start is None:
        return None
    chunk = []
    for line in lines[start:]:
        stripped = line.strip()
        if _ANY_HEAD.match(stripped) and not start_re.match(stripped):
            break
        chunk.append(line)
    return '\n'.join(chunk)


def unchecked_acceptance(body):
    section = _section(body, _ACCEPT_HEAD)
    if section is None:
        return False
    return any(_UNCHECKED.match(line) for line in section.splitlines())


def self_check_has_command_and_output(body):
    section = _section(body, _SELF_HEAD)
    if section is None:
        return False
    commands = []
    other = []
    for line in section.splitlines():
        text = line.strip()
        if not text or text.startswith('#'):
            continue
        if _COMMAND.search(text):
            commands.append(text)
        else:
            other.append(text)
    return bool(commands and other)


def has_issue_link(body, issue_number):
    if not issue_number:
        return True
    return bool(re.search(_ISSUE_LINK_FMT % int(issue_number), body or '', re.I))


def unlinked_acceptance_issue(body):
    for match in _ACCEPT_ISSUE.finditer(body or ''):
        num = match.group(1) or match.group(2)
        if num and not has_issue_link(body, num):
            return int(num)
    return None


def finish_block_reason(body, issue=None):
    """None when the body may finish. Otherwise the one-line reason."""
    if unchecked_acceptance(body):
        return 'unchecked Acceptance items'
    if not self_check_has_command_and_output(body):
        return 'PR body needs ## Self-check with a command and its output'
    missing = int(issue) if (issue and not has_issue_link(body, issue)) else unlinked_acceptance_issue(body)
    if missing:
        return 'PR body needs Closes #%d or Refs #%d' % (missing, missing)
    return None


def main(argv=None):
    text = sys.stdin.read()
    reason = finish_block_reason(text)
    if reason:
        print(reason)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
