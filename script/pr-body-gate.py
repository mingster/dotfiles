#!/usr/bin/env python3
"""PR body gate shared by fleet-watch and ship.sh.

A builder may finish only when Acceptance has no unchecked box, ## Self-check
names a command and a line of output, and the body has a valid
"Builder: agent=<provider> model=<model>" line (#1201).

Two opt-in rules (#1840), off unless the caller passes the input:
--diff <file>: when the diff changes an existing function or field, the body has a Readers: section
naming each changed name, every item with a test or a reason.
--asked no: the worker sent no ask, so the body has a Decisions: section (Decisions: none is fine).

One per-repo rule (#2065), on with --diff: a "# perf-paths: <prefix> ..." line in .agents/head-checks.conf of the
current checkout, and a diff touching one of those prefixes, need a "Perf: <text>" line in the body.
"""
import re
import subprocess
import sys

_ACCEPT_HEAD = re.compile(r'^(?:## Acceptance(?: criteria)?\b|\*\*Acceptance(?: criteria)?:\*\*)', re.I)
_ANY_HEAD = re.compile(r'^(?:## |\*\*[^*]+:\*\*)')
_SELF_HEAD = re.compile(r'^## Self-check\b', re.I)
_UNCHECKED = re.compile(r'^[ \t]*- \[ \]')
_COMMAND = re.compile(
    r'(?:^\$\s+\S)|(?:^Command\b[^:\n]*:)|(?:(?<![\w./-])(?:bash|sh|python3?|pytest|bun|bunx|npm|npx|uv|node|gh|git)(?![\w./-]))',
    re.I,
)
_ACCEPT_ISSUE = re.compile(
    r'(?:^|\b)#([0-9]+)\s+acceptance\b|^##\s+Acceptance(?: criteria)?\s*\(\s*#([0-9]+)\s*\)',
    re.I | re.M,
)
_BUILDER_LINE = re.compile(r'^Builder: agent=([A-Za-z0-9._-]+) model=([A-Za-z0-9._:-]+)\s*$')
# template-sync-pr.sh opens bump PRs as a script, not a model. Only this exact pair is allowed (#1291).
_SCRIPT_BUILDER = ('script', 'template-sync-pr.sh')
_PROVIDERS = ('claude', 'antigravity', 'agy', 'grok', 'cursor', 'codex')
# Model prefixes of the families in usage-gate.py family(). A role name or a host fails here.
_MODEL_PREFIXES = ('claude-', 'sonnet', 'opus', 'haiku', 'fable', 'gpt-', 'composer', 'grok', 'gemini-')
# Definitions a diff can change. A hunk header (@@ ... @@ <context>) names the function the hunk edits.
_DEF_PATTERNS = (
    re.compile(r'^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\('),
    re.compile(r'^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)'),
    re.compile(r'^\s*(?:export\s+)?(?:const|let)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\(|function\b)'),
    re.compile(r'^\s*([A-Za-z_][\w-]*)\s*\(\)\s*\{'),
)
_FIELD_PATTERNS = {
    ('.ts', '.tsx'): re.compile(r'^\s*(?:readonly\s+)?([A-Za-z_$][\w$]*)\??\s*:\s*[^=(]+;?\s*$'),
    ('.prisma',): re.compile(r'^\s+([a-z_]\w*)\s+[A-Z]\w*(?:\[\])?\??(?:\s|$)'),
}
_TEST_PATH = re.compile(r'(?:^|/)(?:tests?/|test_[^/]*$|[^/]*[._-](?:test|spec)\.[A-Za-z0-9]+$)')
_TEST_REF = re.compile(r'[\w./-]*(?:test|spec)[\w./-]*\.[A-Za-z0-9]+|\btest\b', re.I)
_REASON_REF = re.compile(r'\b(?:reason|because)\b', re.I)
_PERF_CONF = re.compile(r'^#[ \t]*perf-paths:(.*)$', re.M)
_PERF_LINE = re.compile(r'^Perf:[ \t]*\S', re.M)
_DIFF_PATHS = re.compile(r'^diff --git a/(.+?) b/(.+)$', re.M)
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


def has_valid_builder_line(body):
    """True when the last Builder: line names a known provider and a model of a known family."""
    found = None
    for line in (body or '').splitlines():
        match = _BUILDER_LINE.match(line.strip())
        if match:
            found = match.groups()
    if not found:
        return False
    if found == _SCRIPT_BUILDER:
        return True
    return found[0].lower() in _PROVIDERS and found[1].lower().startswith(_MODEL_PREFIXES)


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


def _definition_name(line, path):
    for pattern in _DEF_PATTERNS:
        match = pattern.match(line)
        if match:
            return match.group(1)
    for suffixes, pattern in _FIELD_PATTERNS.items():
        if path.endswith(suffixes):
            match = pattern.match(line)
            if match:
                return match.group(1)
    return None


def changed_definitions(diff):
    """Names of existing functions or fields the diff changes, in diff order. A brand new definition
    (only + lines) has no readers yet, and test files are skipped."""
    names = []
    path = ''
    hunk_name = None
    hunk_counted = True
    for line in (diff or '').splitlines():
        if line.startswith('+++ '):
            path = line[4:].strip()
            path = path[2:] if path.startswith('b/') else path
            continue
        if line.startswith('--- ') or line.startswith('diff --git'):
            continue
        if _TEST_PATH.search(path):
            continue
        if line.startswith('@@'):
            context = line.split('@@', 2)[2] if line.count('@@') >= 2 else ''
            hunk_name = _definition_name(context, path)
            hunk_counted = False
            continue
        if line[:1] not in ('+', '-'):
            continue
        name = _definition_name(line[1:], path) if line.startswith('-') else None
        for found in (name, None if hunk_counted else hunk_name):
            if found and found not in names:
                names.append(found)
        hunk_counted = True
    return names


def _labeled_section(body, label):
    """Text of a '## <label>' section, or of a '<label>:' line plus the list under it. None when absent."""
    heading = _section(body, re.compile(r'^## %s\b' % label, re.I))
    if heading is not None:
        return heading
    lines = (body or '').splitlines()
    for index, line in enumerate(lines):
        match = re.match(r'^\s*(?:\*\*)?%s:(?:\*\*)?(.*)$' % label, line.strip(), re.I)
        if not match:
            continue
        chunk = [match.group(1)]
        for rest in lines[index + 1:]:
            if not rest.strip() or _ANY_HEAD.match(rest.strip()):
                break
            chunk.append(rest)
        return '\n'.join(chunk)
    return None


def readers_block_reason(body, diff):
    names = changed_definitions(diff)
    if not names:
        return None
    need = "PR body needs a Readers: section listing each caller of %s with a test or a reason" % ', '.join(names)
    section = _labeled_section(body, 'Readers')
    if section is None:
        return need
    items = [line.strip() for line in section.splitlines() if re.match(r'^\s*(?:[-*]|[0-9]+[.)])\s+\S', line)]
    items = items or [line.strip() for line in section.splitlines() if line.strip()]
    missing = [name for name in names if not re.search(r'\b%s\b' % re.escape(name), section)]
    bare = [item for item in items if not (_TEST_REF.search(item) or _REASON_REF.search(item))]
    if not items or missing or bare:
        return need
    return None


def decisions_block_reason(body, asked):
    if asked is not False:
        return None
    section = _labeled_section(body, 'Decisions')
    if section is None or not section.strip():
        return "PR body needs a Decisions: section (the worker sent no ask; 'Decisions: none' when there were none)"
    return None


def perf_paths():
    """Path prefixes the current checkout marks perf relevant. Empty outside a checkout or with no line."""
    try:
        top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True, check=True)
        with open(top.stdout.strip() + '/.agents/head-checks.conf', encoding='utf-8', errors='replace') as handle:
            conf = handle.read()
    except (OSError, subprocess.CalledProcessError):
        return []
    return [prefix for line in _PERF_CONF.findall(conf) for prefix in line.split()]


def perf_block_reason(body, diff):
    prefixes = tuple(perf_paths())
    if not prefixes or _PERF_LINE.search(body or ''):
        return None
    for pair in _DIFF_PATHS.findall(diff):
        for path in pair:
            if path.startswith(prefixes):
                return ('PR body needs a Perf: line (Perf: <checked items> or Perf: n/a: no data reads changed) '
                        'because the diff touches %s' % path)
    return None


def finish_block_reason(body, issue=None, diff=None, asked=None):
    """None when the body may finish. Otherwise the one-line reason.

    diff (unified diff text) turns on the Readers: and Perf: rules; asked=False turns on the Decisions: rule."""
    if unchecked_acceptance(body):
        return 'unchecked Acceptance items'
    if not self_check_has_command_and_output(body):
        return 'PR body needs ## Self-check with a command and its output'
    missing = int(issue) if (issue and not has_issue_link(body, issue)) else unlinked_acceptance_issue(body)
    if missing:
        return 'PR body needs Closes #%d or Refs #%d' % (missing, missing)
    if not has_valid_builder_line(body):
        return "PR body needs a 'Builder: agent=<provider> model=<model>' line (provider claude, antigravity, grok or cursor, never a role or host)"
    if diff is not None:
        reason = readers_block_reason(body, diff) or perf_block_reason(body, diff)
        if reason:
            return reason
    return decisions_block_reason(body, asked)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    opts = dict(zip(argv[::2], argv[1::2])) if len(argv) % 2 == 0 else {}
    if len(argv) % 2 or set(opts) - {'--issue', '--diff', '--asked'} or opts.get('--asked', 'no') not in ('yes', 'no'):
        print('usage: pr-body-gate.py [--issue <n>] [--diff <file>] [--asked yes|no] < body')
        return 2
    issue = opts['--issue'] if opts.get('--issue', '').isdigit() else None
    diff = None
    if '--diff' in opts:
        with open(opts['--diff'], encoding='utf-8', errors='replace') as handle:
            diff = handle.read()
    asked = {'yes': True, 'no': False}.get(opts.get('--asked'))
    text = sys.stdin.read()
    reason = finish_block_reason(text, issue, diff=diff, asked=asked)
    if reason:
        print(reason)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
