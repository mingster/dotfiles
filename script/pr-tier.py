#!/usr/bin/env python3
"""Label a pull request tier 0, 1 or 2 from its changed files and line counts (#1730).

Tier 0: only test files and docs, 150 changed lines or fewer. Ships on Review PASS plus green Checks, no verifier.
Tier 1: 50 changed code lines or fewer, no UI file. Still needs a verifier, which starts first and sits outside the pass cap.
Tier 2: everything else. Unchanged rules.

A protected path, a list that may be cut off, a missing line count or an empty list is always tier 2.
Usage: pr-tier.py [--explain] < files.json   (gh api pulls/N/files or gh pr list files; prints 0, 1 or 2)
"""
import json
import re
import sys

TIER0_MAX_LINES = 150
TIER1_MAX_LINES = 50
# gh pr list returns at most 100 files per PR, so a list this long may be cut off.
FILES_LIMIT = 100

DOC_RE = re.compile(r'\.mdx?$', re.I)
TEST_NAME_RE = re.compile(
    r'(\.(test|spec)\.(sh|py|ts|tsx|js|jsx|mjs|cjs)$)|(^test_[^/]*\.py$)|(_test\.(py|go)$)|(Test\.php$)'
)
# A file under one of these is a shared helper, fixture or mock, never a plain test.
HELPER_SEGMENTS = {
    'fixtures', 'fixture', 'mocks', 'mock', '__mocks__', 'helpers', 'helper', 'support', 'testdata',
    '__snapshots__', 'snapshots', 'lib', 'factories', 'stubs', 'utils',
}
UI_EXTS = ('.tsx', '.jsx', '.vue', '.svelte', '.css', '.scss', '.sass', '.less', '.html', '.blade.php')
UI_SEGMENTS = {'components', 'pages', 'views', 'ui', 'styles', 'locales', 'lang'}

# Same paths protected-paths.sh calls protected, plus the owner's list: hooks, settings, schema, payment, auth,
# secrets, ship.sh, post-verdict.sh. test_pr_tier_1730.py checks that every path protected_path names is protected here.
PROTECTED_NAMES = {'ship.sh', 'post-verdict.sh', 'owner-approve.sh', 'model-routing.md', 'AGENTS.md', 'head-checks.conf'}
PROTECTED_TOKENS = {'auth', 'authn', 'authz', 'oauth', 'authentication', 'authorization'}
PROTECTED_TOKEN_PREFIXES = ('payment', 'secret', 'credential', 'schema', 'migration')
PROTECTED_ROLE_FILES = {'docs/agents/elon-dispatch.md', 'docs/agents/team.md'}


def _tokens(path):
    return [t for t in re.split(r'[^a-z0-9]+', path.lower()) if t]


def is_protected(path):
    parts = path.split('/')
    name = parts[-1]
    if name in PROTECTED_NAMES or name.endswith('.rules') or name.startswith('.env'):
        return True
    if 'hooks' in parts or path.startswith('.claude/settings') or re.fullmatch(r'settings[^/]*\.json', name):
        return True
    if path.startswith('docs/intent/') or path in PROTECTED_ROLE_FILES or '.claude/agents/' in '/' + path:
        return True
    if '.github/workflows/' in '/' + path:
        return True
    tokens = _tokens(path)
    if any(t in PROTECTED_TOKENS for t in tokens):
        return True
    return any(t.startswith(PROTECTED_TOKEN_PREFIXES) for t in tokens)


def is_doc(path):
    return bool(DOC_RE.search(path))


def is_test(path):
    parts = path.split('/')
    if any(p in HELPER_SEGMENTS for p in parts[:-1]) or parts[-1] == 'conftest.py':
        return False
    return bool(TEST_NAME_RE.search(parts[-1]))


def is_ui(path):
    low = path.lower()
    return low.endswith(UI_EXTS) or any(p in UI_SEGMENTS for p in low.split('/')[:-1])


def _count(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def normalize(files):
    """[(path, previous_path, lines)] or None when any entry lacks a path or a line count."""
    rows = []
    for item in files or []:
        if not isinstance(item, dict):
            return None
        path = item.get('path') or item.get('filename') or ''
        add, dele = _count(item.get('additions')), _count(item.get('deletions'))
        if not path or add is None or dele is None:
            return None
        rows.append((path, item.get('previous_filename') or item.get('previousFilename') or '', add + dele))
    return rows


def classify(files):
    """(tier, reason). Fails closed to tier 2."""
    rows = normalize(files)
    if not rows:
        return 2, 'no usable file list'
    if len(rows) >= FILES_LIMIT:
        return 2, 'file list may be cut off'
    for path, prev, _lines in rows:
        for p in (path, prev):
            if p and is_protected(p):
                return 2, 'protected path %s' % p
    total = sum(lines for _p, _o, lines in rows)
    if total <= TIER0_MAX_LINES and all(
        (is_doc(path) or is_test(path)) and (not prev or is_doc(prev) or is_test(prev)) for path, prev, _l in rows
    ):
        return 0, '%d lines, tests and docs only' % total
    code = sum(lines for path, _o, lines in rows if not is_doc(path))
    ui = [path for path, _o, _l in rows if is_ui(path)]
    if code <= TIER1_MAX_LINES and not ui:
        return 1, '%d code lines, no UI file' % code
    if ui:
        return 2, 'UI file %s' % ui[0]
    return 2, '%d lines' % total


def main(argv):
    explain = '--explain' in argv
    try:
        files = json.load(sys.stdin)
        if files and isinstance(files, list) and isinstance(files[0], list):
            files = [item for page in files for item in page]
    except ValueError:
        files = None
    tier, reason = classify(files if isinstance(files, list) else None)
    print(tier)
    if explain:
        print('tier %d: %s' % (tier, reason), file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
