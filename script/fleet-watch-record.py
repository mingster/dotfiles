#!/usr/bin/env python3
"""Record the Orca and gh replies fleet watch replays in tests.

Runs as a shell with no terminal. Test sends use the subject
"fleet-watch recorder test". The worker-start call passes a repo id that does
not exist, so a start cannot succeed. Sends go to a scratch run, never the
coordinator Run.

    python3 script/fleet-watch-record.py --dry
    FLEET_WATCH_RECORD_RUN=run_<scratch> python3 script/fleet-watch-record.py

`--dry` records against a scratch run and fails when the installed Orca
version or a reply shape differs from
script/tests/fixtures/fleet-watch/orca-<version>/. A fake orca, one that
does not print a dotted version, only checks the saved files. Writing a
new recording still requires FLEET_WATCH_RECORD_RUN.
"""
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / 'tests'))
import fleet_watch_replies as replies  # noqa: E402

# The coordinator Run. Recording and tests refuse it; a scratch run is the target.
LIVE_RUN = 'run_2d30da234f80'
# Same string as fleet-watch.RECORDER_SCRATCH_OBJECTIVE. That pass skips this run.
SCRATCH_OBJECTIVE = 'fleet-watch recorder scratch'
SUBJECT = 'fleet-watch recorder test'
BODY = 'fleet-watch recorder test'
# A repo id Orca cannot resolve. Combined with a new worktree, the start fails
# before a worker exists even if a later Orca build stops requiring a sender.
MISSING_REPO = 'id:missing'
START = 'worker' + '-start'

KEEP_ORCA = frozenset((
    'ORCA_USER_DATA_PATH', 'ORCA_CLI_BIN_DIR', 'ORCA_APP_VERSION', 'ORCA_IMAGE_PROTOCOL',
    'ORCA_AGENT_HOOK_ENV', 'ORCA_WSL_HOSTS_GATE_STATE', 'ORCA_CLI_COMMAND',
))
REQUIRED = (
    'send-no-sender', 'send-from-receiver', 'send-to-run', 'send-from-owned-terminal',
    'worker-list', 'worker-start-missing-repo', 'run-list', 'run-list-full', 'run-show',
    'terminal-list', 'inbox', 'gh-pr-list',
)
GH_FIELDS = (
    'number,state,isDraft,headRefOid,headRefName,baseRefOid,mergeable,mergeStateStatus,'
    'reviewDecision,files,labels,comments,statusCheckRollup,mergeCommit,body'
)


def clean_env():
    """Drop the calling terminal so the replies match a supervisor with no pane."""
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('ORCA_') and key not in KEEP_ORCA:
            env.pop(key, None)
    return env


def orca_bin(env):
    return shlex.split(env.get('ORCA_CLI_COMMAND', 'orca'))


def orca_version(env):
    out = subprocess.run([*orca_bin(env), '--version'], capture_output=True, text=True, env=env, timeout=15)
    text = (out.stdout or out.stderr or '').strip().split()
    if not text:
        raise RuntimeError('orca --version printed nothing')
    return text[-1]


def run_cmd(argv, env, timeout):
    proc = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
    return proc.returncode, proc.stdout or '', proc.stderr or ''


def error_code(stdout):
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        return None
    err = data.get('error') if isinstance(data, dict) else None
    if isinstance(err, dict):
        return err.get('code')
    if isinstance(err, str):
        return err
    return None


def orca_json(args, env, timeout=60):
    return run_cmd([*orca_bin(env), *args, '--json'], env, timeout)


def create_terminal(env):
    code, stdout, _stderr = orca_json(
        ['terminal', 'create', '--title', 'fleet-watch', '--worktree', 'active'], env,
    )
    if code != 0:
        raise RuntimeError('terminal create failed: %s' % (error_code(stdout) or code))
    handle = json.loads(stdout)['result']['terminal']['handle']
    if not isinstance(handle, str) or not handle.startswith('term_'):
        raise RuntimeError('terminal create returned no handle')
    return handle


def close_terminal(env, handle):
    orca_json(['terminal', 'close', '--terminal', handle], env)


def public_argv(argv, patterns, homes, run):
    """Argv safe to commit. The live handles never enter the fixture."""
    keep = {
        'orca', 'gh', 'cursor', 'all', 'pr', 'list', MISSING_REPO, SUBJECT, BODY, GH_FIELDS,
        START, 'mingster/dotfiles', 'new-child', 'active',
    }
    out = []
    for arg in argv:
        if arg == run:
            out.append('<run>')
        elif arg == 'run:' + run:
            out.append('run:<run>')
        elif arg.startswith('--') or arg.isdigit() or arg in keep:
            out.append(arg)
        elif arg.startswith('term_'):
            out.append('term_placeholder')
        else:
            out.append(replies.redact_string(arg, patterns, homes))
    return out


def calls(receiver, owned, run):
    send = ['orchestration', 'send', '--subject', SUBJECT, '--body', BODY]
    return [
        ('send-no-sender', [*send, '--to', receiver]),
        ('send-from-receiver', [*send, '--to', receiver, '--from', receiver]),
        ('send-to-run', [*send, '--to', 'run:' + run]),
        ('send-from-owned-terminal', [*send, '--to', 'run:' + run, '--from', owned]),
        ('worker-list', [
            'orchestration', 'worker-list', '--run', run, '--include-remote', '--full',
        ]),
        ('worker-start-missing-repo', [
            'orchestration', START, '--spec', SUBJECT, '--agent', 'cursor', '--run', run,
            '--worktree', 'new-child', '--repo', MISSING_REPO,
        ]),
        ('run-list', ['orchestration', 'run-list']),
        ('run-list-full', ['orchestration', 'run-list', '--full']),
        ('run-show', ['orchestration', 'run-show', '--id', run, '--full']),
        # fleet-watch rpc() appends a second --json onto `terminal list --json`.
        ('terminal-list', ['terminal', 'list', '--json']),
        ('inbox', ['orchestration', 'inbox', '--limit', '5000']),
    ]


def gh_pr_list(env):
    argv = [
        'gh', 'pr', 'list', '--repo', 'mingster/dotfiles', '--state', 'all', '--limit', '50',
        '--json', GH_FIELDS,
    ]
    code, stdout, stderr = run_cmd(argv, env, timeout=60)
    return {
        'name': 'gh-pr-list',
        'argv': argv,
        'exit_code': code,
        'stdout': stdout,
        'stderr': stderr,
    }


def clean_record(record, patterns, homes, run):
    argv = public_argv(record['argv'], patterns, homes, run)
    stdout = replies.redact_text(record['stdout'], patterns, homes)
    stderr = replies.redact_text(record['stderr'], patterns, homes)
    cleaned = {
        'name': record['name'],
        'argv': argv,
        'exit_code': record['exit_code'],
        'stdout': stdout,
        'stderr': stderr,
    }
    blob = json.dumps(cleaned)
    kinds = replies.leak_kinds(blob)
    for cre in patterns:
        if cre.search(blob):
            kinds.append('project')
    if kinds:
        raise RuntimeError('%s still has %s' % (record['name'], ','.join(kinds)))
    return cleaned


def collect(env, receiver, owned, run):
    records = []
    for name, args in calls(receiver, owned, run):
        code, stdout, stderr = orca_json(args, env)
        if name == 'worker-start-missing-repo':
            try:
                started = json.loads(stdout).get('ok') is True
            except json.JSONDecodeError:
                started = False
            if code == 0 or started:
                raise RuntimeError('worker-start exited 0; refusing to record a start')
        records.append({
            'name': name,
            'argv': ['orca', *args, '--json'],
            'exit_code': code,
            'stdout': stdout,
            'stderr': stderr,
        })
    records.append(gh_pr_list(env))
    return records


def orca_result(stdout):
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError('orca reply is not json') from exc
    if not isinstance(data, dict) or data.get('ok') is False:
        raise RuntimeError(error_code(stdout) or 'orca failed')
    result = data.get('result')
    if not isinstance(result, dict):
        raise RuntimeError('orca reply has no result')
    return result


def list_all_runs(env):
    """Every run, following nextCursor. The scratch run may not be on the first page."""
    runs = []
    cursor = None
    seen = set()
    while True:
        args = ['orchestration', 'run-list', '--full']
        if cursor:
            args.extend(('--cursor', cursor))
        code, stdout, _stderr = orca_json(args, env)
        if code != 0:
            raise RuntimeError('run-list failed: %s' % (error_code(stdout) or code))
        result = orca_result(stdout)
        page = result.get('runs')
        if not isinstance(page, list):
            raise RuntimeError('run-list has no runs')
        runs.extend(item for item in page if isinstance(item, dict))
        cursor = result.get('nextCursor')
        if not cursor:
            return runs
        if not isinstance(cursor, str) or cursor in seen:
            raise RuntimeError('run-list repeated a cursor')
        seen.add(cursor)


def run_id_from_create(stdout):
    result = orca_result(stdout)
    run = result.get('run') if isinstance(result.get('run'), dict) else result
    rid = None
    if isinstance(run, dict):
        candidate = run.get('id') or run.get('runId')
        rid = candidate if isinstance(candidate, str) else None
    if not isinstance(rid, str) or re.fullmatch(r'run_[A-Za-z0-9_-]+', rid) is None:
        raise RuntimeError('run-create returned no scratch run')
    if rid == LIVE_RUN:
        raise RuntimeError('refusing the coordinator run')
    return rid


def ensure_scratch_run(env):
    """A run this recorder owns. Never the coordinator Run. The terminal is closed by the caller."""
    scratch = None
    for run in list_all_runs(env):
        rid = run.get('id')
        objective = run.get('objective')
        if not isinstance(rid, str) or rid == LIVE_RUN:
            continue
        if isinstance(objective, str) and objective.strip() == SCRATCH_OBJECTIVE:
            scratch = rid
            break
    owned = create_terminal(env)
    try:
        if not scratch:
            code, stdout, _stderr = orca_json(
                ['orchestration', 'run-create', '--objective', SCRATCH_OBJECTIVE, '--from', owned],
                env,
            )
            if code != 0:
                raise RuntimeError('run-create failed: %s' % (error_code(stdout) or code))
            scratch = run_id_from_create(stdout)
        # The fresh terminal coordinates the scratch run, so sends are not warnings
        # about a stranger speaking for it, and not mail to the coordinator.
        code, stdout, _stderr = orca_json(
            ['orchestration', 'run-use', '--id', scratch, '--from', owned], env,
        )
        if code != 0:
            raise RuntimeError('run-use failed: %s' % (error_code(stdout) or code))
        return scratch, owned
    except Exception:
        close_terminal(env, owned)
        raise


def stamp_problems(directory, version):
    """The folder and each file name the Orca version the recording came from."""
    named = directory.name[len('orca-'):] if directory.name.startswith('orca-') else ''
    problems = []
    if named != version:
        problems.append('folder %s' % directory.name)
    for path in sorted(directory.glob('*.json')):
        try:
            stamped = json.loads(path.read_text()).get('orca_version')
        except json.JSONDecodeError:
            problems.append('%s is not json' % path.name)
            continue
        if stamped != version:
            problems.append('%s names %s' % (path.name, stamped))
    return problems


def saved_files_ok(directory):
    """Saved replies exist, name their version, and contain no handles or addresses."""
    named = directory.name[len('orca-'):] if directory.name.startswith('orca-') else ''
    problems = stamp_problems(directory, named)
    if problems:
        print('version mismatch: %s' % ', '.join(problems), file=sys.stderr)
        return 1
    patterns = replies.default_patterns()
    missing = []
    for name in REQUIRED:
        path = directory / (name + '.json')
        if not path.is_file():
            missing.append(name)
            continue
        text = path.read_text()
        kinds = replies.leak_kinds(text)
        for cre in patterns:
            if cre.search(text):
                kinds.append('project')
        if kinds:
            print('fleet-watch-record: %s still has %s' % (name, ','.join(kinds)), file=sys.stderr)
            return 1
        replies.reply_shape(json.loads(text))
    if missing:
        print('missing %s' % ', '.join(missing), file=sys.stderr)
        return 1
    return 0


def local_contract():
    """Check the saved replies. This path does not record a fresh reply."""
    try:
        directory = replies.version_dir()
    except FileNotFoundError as exc:
        print('fleet-watch-record: %s' % exc, file=sys.stderr)
        return 1
    status = saved_files_ok(directory)
    if status != 0:
        return status
    print('fleet-watch contract local %s' % directory.name, file=sys.stderr)
    return 0


def version_mismatch(version):
    try:
        saved = replies.version_dir().name
    except FileNotFoundError:
        saved = 'none'
    print('version mismatch: installed orca %s, saved recording %s' % (version, saved), file=sys.stderr)
    return 1


def compare_shapes(directory, cleaned):
    failed = False
    for record in cleaned:
        path = directory / (record['name'] + '.json')
        if not path.is_file():
            print('shape mismatch: missing %s' % record['name'], file=sys.stderr)
            failed = True
            continue
        saved = json.loads(path.read_text())
        fresh = replies.reply_shape(record)
        old = replies.reply_shape(saved)
        if replies.same_shape(old, fresh):
            continue
        failed = True
        print('shape mismatch: %s' % record['name'], file=sys.stderr)
        print(json.dumps({'saved': old, 'fresh': fresh}, sort_keys=True)[:2000], file=sys.stderr)
    return failed


def main(argv):
    dry = '--dry' in argv
    run = os.environ.get('FLEET_WATCH_RECORD_RUN', '').strip()
    if run == LIVE_RUN:
        print('fleet-watch-record: refusing the coordinator run', file=sys.stderr)
        return 2
    if run and re.fullmatch(r'run_[A-Za-z0-9_-]+', run) is None:
        print('fleet-watch-record: scratch run id is not a run id', file=sys.stderr)
        return 2
    if not run and not dry:
        print('fleet-watch-record: set FLEET_WATCH_RECORD_RUN to a scratch run', file=sys.stderr)
        return 2
    env = clean_env()
    try:
        version = orca_version(env)
    except (RuntimeError, OSError) as exc:
        print('fleet-watch-record: %s' % exc, file=sys.stderr)
        return 2
    # A fake orca (wrap-up tests) does not print a dotted version. Do not send.
    if dry and re.fullmatch(r'\d+\.\d+\.\d+', version) is None:
        return local_contract()
    directory = replies.FIXTURES / ('orca-' + version)
    if dry and not directory.is_dir():
        return version_mismatch(version)
    if dry:
        problems = stamp_problems(directory, version)
        if problems:
            print('version mismatch: installed orca %s (%s)' % (version, ', '.join(problems)), file=sys.stderr)
            return 1
        files = saved_files_ok(directory)
        if files != 0:
            return files
    patterns = replies.default_patterns()
    homes = [str(Path.home())]
    owned = None
    try:
        if not run:
            run, owned = ensure_scratch_run(env)
        else:
            owned = create_terminal(env)
        # Sends use the terminal this check just opened, not the coordinator.
        records = collect(env, owned, owned, run)
        cleaned = [clean_record(record, patterns, homes, run) for record in records]
    except RuntimeError as exc:
        print('fleet-watch-record: %s' % exc, file=sys.stderr)
        return 2
    finally:
        if owned:
            close_terminal(env, owned)
    if dry:
        if compare_shapes(directory, cleaned):
            return 1
        print('fleet-watch contract ok orca-%s' % version)
        return 0
    directory.mkdir(parents=True, exist_ok=True)
    for record in cleaned:
        record['orca_version'] = version
        name = record.pop('name')
        path = directory / (name + '.json')
        path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
        print('recorded %s exit %s' % (name, record['exit_code']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
