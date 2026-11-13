"""Load recorded Orca and gh replies, and the shape the contract compares.

Recordings live in script/tests/fixtures/fleet-watch/orca-<version>/.
A reply file is JSON with exit_code, stdout, stderr, and argv.
Handles, hosts, paths and free text are already placeholders.
"""
import json
import os
import re
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / 'fixtures' / 'fleet-watch'

TEXT_KEYS = frozenset((
    'body', 'preview', 'objective', 'title', 'subject', 'text', 'message',
    'comment', 'description', 'content', 'summary', 'paneTitle', 'name',
    'snippet', 'output', 'command', 'spec',
))
PATH_KEYS = frozenset((
    'path', 'worktreePath', 'cwd', 'repo', 'worktree',
))
HOST_KEYS = frozenset((
    'host', 'hostname', 'hostId', 'hostIds', 'executionHostId', 'endpointId',
    'server', 'omittedHostIds', 'omittedHostSelectors',
))

_HANDLE = re.compile(r'term_(?!placeholder\b)[A-Za-z0-9_-]+')
_RUN = re.compile(r'run_(?!placeholder\b)[A-Za-z0-9_-]+')
_TASK = re.compile(r'task_(?!placeholder\b)[A-Za-z0-9_-]+')
_DISPATCH = re.compile(r'ctx_(?!placeholder\b)[A-Za-z0-9_-]+')
_UUID = re.compile(
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'
)
_HEX = re.compile(r'\b[0-9a-fA-F]{32,}\b')
_IPV4 = re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b')
_IPV6 = re.compile(r'(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}')
_EMAIL = re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b')
# msg_, wtr_, relay_ and the same shape. Protocol words (worker_done, in_progress) have no digit.
_PREFIXED_ID = re.compile(r'\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9-]*\d[A-Za-z0-9-]*\b')
_ENUM = re.compile(r'[A-Za-z][A-Za-z0-9_-]*')


def version_dir():
    """The recorded Orca version directory. The newest name wins when several exist."""
    dirs = sorted(p for p in FIXTURES.iterdir() if p.is_dir() and p.name.startswith('orca-'))
    if not dirs:
        raise FileNotFoundError('no recorded replies in %s' % FIXTURES)
    return dirs[-1]


def load_reply(name):
    """The recorded reply for one call. Raises when the file is missing."""
    path = version_dir() / (name + '.json')
    data = json.loads(path.read_text())
    for key in ('exit_code', 'stdout', 'stderr'):
        if key not in data:
            raise ValueError('%s missing %s' % (path.name, key))
    return data


def default_patterns():
    """Project-name regexes from the untracked pattern file, or none when it is absent."""
    path = os.environ.get('NO_PROJECT_NAMES_FILE')
    if not path:
        path = str(Path.home() / '.config' / 'dotfiles' / 'project-names.pattern')
    file = Path(path)
    if not file.is_file():
        return []
    return load_patterns(file.read_text())


def load_patterns(text):
    """Compile project-name regex lines. Skip a line that matches the empty string."""
    compiled = []
    for line in (text or '').splitlines():
        line = line.strip()
        if not line:
            continue
        cre = re.compile(line)
        if cre.search('') is not None:
            continue
        compiled.append(cre)
    return compiled


def _id_key(key):
    if key in ('from', 'to', 'handle', 'terminal'):
        return True
    return bool(key) and (
        key.endswith('Id') or key.endswith('Handle') or key.endswith('_id') or key.endswith('_handle')
    )


def _dynamic_key(key):
    if '/' in key or '\\' in key:
        return True
    if key.startswith(('term_', 'run_', 'task_', 'ctx_')):
        return True
    return _UUID.search(key) is not None


def redact_string(text, patterns, homes=()):
    """Replace identifiers in one string. Protocol tokens (no space, no path) stay."""
    for home in homes:
        if home and home in text:
            text = text.replace(home, '<path>')
    for cre in patterns:
        text = cre.sub('<name>', text)
    if re.search(r'\s', text):
        return '<redacted>'
    if '://' in text:
        return '<url>'
    if '/' in text or '\\' in text:
        return '<path>'
    text = _IPV4.sub('<ip>', text)
    if _IPV6.fullmatch(text):
        return '<ip>'
    text = _EMAIL.sub('<email>', text)
    text = _HANDLE.sub('term_placeholder', text)
    text = _RUN.sub('run_placeholder', text)
    text = _TASK.sub('task_placeholder', text)
    text = _DISPATCH.sub('ctx_placeholder', text)
    text = _UUID.sub('<id>', text)
    text = _HEX.sub('<id>', text)
    text = _PREFIXED_ID.sub('<id>', text)
    if len(text) > 80:
        return '<redacted>'
    if _ENUM.fullmatch(text):
        return text
    if text in ('<path>', '<ip>', '<email>', '<id>', '<url>', '<name>', '<redacted>', '<host>', '<key>'):
        return text
    if text.startswith('term_placeholder') or text.startswith('run_placeholder'):
        return text
    return '<redacted>'


def redact(value, patterns=(), homes=(), key=None):
    """Copy value with identifiers replaced. Error codes under error.code stay."""
    if isinstance(value, dict):
        out = {}
        dynamic = None
        for child_key, child in value.items():
            if _dynamic_key(child_key):
                dynamic = redact(child, patterns, homes)
                continue
            out[child_key] = redact(child, patterns, homes, key=child_key)
        if dynamic is not None:
            out['<key>'] = dynamic
        return out
    if isinstance(value, list):
        return [redact(item, patterns, homes, key=key) for item in value]
    if isinstance(value, str):
        if key == 'code' and re.fullmatch(r'[a-z0-9_]+', value):
            return value
        if key in TEXT_KEYS:
            return '<redacted>'
        if key in PATH_KEYS:
            return '<path>'
        if key in HOST_KEYS:
            return '<host>'
        if _id_key(key):
            if value.startswith('term_'):
                return 'term_placeholder'
            if value.startswith('run_'):
                return 'run_placeholder'
            return '<id>'
        return redact_string(value, patterns, homes)
    return value


def redact_text(text, patterns=(), homes=()):
    """Redact a JSON document, or a non-JSON blob as one string."""
    stripped = text.strip()
    if not stripped:
        return ''
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError:
        return redact_string(text, patterns, homes)
    cleaned = redact(parsed, patterns, homes)
    return json.dumps(cleaned, indent=2, sort_keys=True) + '\n'


def shape(value, keep_code=False):
    """Keys and value kinds. error.code strings stay. List elements keep shared keys only."""
    if isinstance(value, dict):
        # A cursor that is null on the last page and a string otherwise is one shape.
        normalized = dict(value)
        if 'nextCursor' in normalized:
            normalized['nextCursor'] = None
        out = {}
        for key in sorted(normalized):
            child = normalized[key]
            if key == 'code' and keep_code and isinstance(child, str):
                out[key] = child
            elif key == 'error' and isinstance(child, dict):
                out[key] = shape(child, keep_code=True)
            elif key == 'nextCursor':
                out[key] = 'cursor'
            else:
                out[key] = shape(child, keep_code=False)
        return out
    if isinstance(value, list):
        if not value:
            return []
        items = [shape(item) for item in value]
        if all(isinstance(item, dict) for item in items):
            keys = set(items[0])
            for item in items[1:]:
                keys &= set(item)
            merged = {}
            for key in sorted(keys):
                vals = [item[key] for item in items]
                merged[key] = vals[0] if all(val == vals[0] for val in vals) else 'varies'
            return [merged]
        if all(item == items[0] for item in items):
            return [items[0]]
        return ['varies']
    if isinstance(value, bool):
        return 'bool'
    if isinstance(value, int):
        return 'int'
    if isinstance(value, float):
        return 'float'
    if value is None:
        return 'null'
    if isinstance(value, str):
        return 'str'
    return type(value).__name__


def stream_shape(text):
    if not text:
        return ''
    try:
        return shape(json.loads(text))
    except json.JSONDecodeError:
        return 'text'


def reply_shape(record):
    """What the contract compares: exit code, plus keys and error codes of each stream."""
    return {
        'exit_code': record['exit_code'],
        'stdout': stream_shape(record.get('stdout') or ''),
        'stderr': stream_shape(record.get('stderr') or ''),
    }


def same_shape(saved, fresh):
    """Keys, error codes and exit codes. An empty list matches a list of rows.

    A scratch run has no workers. Row keys are compared only when both sides have a row.
    """
    if isinstance(saved, list) or isinstance(fresh, list):
        if not isinstance(saved, list) or not isinstance(fresh, list):
            return False
        if not saved or not fresh:
            return True
        if len(saved) != len(fresh):
            return False
        return all(same_shape(left, right) for left, right in zip(saved, fresh))
    if isinstance(saved, dict) or isinstance(fresh, dict):
        if not isinstance(saved, dict) or not isinstance(fresh, dict):
            return False
        if set(saved) != set(fresh):
            return False
        return all(same_shape(saved[key], fresh[key]) for key in saved)
    return saved == fresh


def leak_kinds(text):
    """Structural leaks. Project-name regexes are separate so a missing pattern file still checks these."""
    found = []
    checks = (
        ('handle', _HANDLE),
        ('run', _RUN),
        ('task', _TASK),
        ('dispatch', _DISPATCH),
        ('uuid', _UUID),
        ('ip', _IPV4),
        ('home', re.compile(r'/Users/|/home/')),
        ('prefixed_id', _PREFIXED_ID),
        ('email', _EMAIL),
    )
    for kind, cre in checks:
        if cre.search(text):
            found.append(kind)
    return found
