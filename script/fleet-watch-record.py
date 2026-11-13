#!/usr/bin/env python3
"""Record the Orca and gh replies fleet watch replays in tests.

Runs as a shell with no terminal, against one run. Test sends use the subject
"fleet-watch recorder test". The worker-start call passes a repo id that does
not exist, so a start cannot succeed.

    python3 script/fleet-watch-record.py          # write fixtures
    python3 script/fleet-watch-record.py --dry    # compare shapes, write nothing

Fixtures go to script/tests/fixtures/fleet-watch/orca-<version>/.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / 'tests'))
import fleet_watch_replies as replies  # noqa: E402

RUN = 'run_2d30da234f80'
SUBJECT = 'fleet-watch recorder test'
BODY = 'fleet-watch recorder test'
# A repo id Orca cannot resolve. Combined with a new worktree, the start fails
# before a worker exists even if a later Orca build stops requiring a sender.
MISSING_REPO = 'id:missing'
START = 'worker' + '-start'

KEEP_ORCA = frozenset((
    'ORCA_USER_DATA_PATH', 'ORCA_CLI_BIN_DIR', 'ORCA_APP_VERSION', 'ORCA_IMAGE_PROTOCOL',
    'ORCA_AGENT_HOOK_ENV', 'ORCA_WSL_HOSTS_GATE_STATE',
))
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


def orca_version(env):
    out = subprocess.run(['orca', '--version'], capture_output=True, text=True, env=env, timeout=15)
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
    return run_cmd(['orca', *args, '--json'], env, timeout)


def coordinator_handle(env):
    code, stdout, _stderr = orca_json(
        ['orchestration', 'run-show', '--id', RUN, '--full'], env,
    )
    if code != 0:
        raise RuntimeError('run-show failed: %s' % (error_code(stdout) or code))
    data = json.loads(stdout)
    handle = data['result']['run']['coordinator_handle']
    if not isinstance(handle, str) or not handle.startswith('term_'):
        raise RuntimeError('run-show returned no coordinator terminal')
    return handle


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


def public_argv(argv, patterns, homes):
    """Argv safe to commit. The live handles never enter the fixture."""
    keep = {
        'orca', 'gh', 'cursor', 'all', 'pr', 'list', MISSING_REPO, SUBJECT, BODY, GH_FIELDS,
        START, 'mingster/dotfiles', 'new-child', 'active',
    }
    out = []
    for arg in argv:
        if arg == RUN:
            out.append('<run>')
        elif arg == 'run:' + RUN:
            out.append('run:<run>')
        elif arg.startswith('--') or arg.isdigit() or arg in keep:
            out.append(arg)
        elif arg.startswith('term_'):
            out.append('term_placeholder')
        else:
            out.append(replies.redact_string(arg, patterns, homes))
    return out


def calls(receiver, owned):
    send = ['orchestration', 'send', '--subject', SUBJECT, '--body', BODY]
    return [
        ('send-no-sender', [*send, '--to', receiver]),
        ('send-from-receiver', [*send, '--to', receiver, '--from', receiver]),
        ('send-to-run', [*send, '--to', 'run:' + RUN]),
        ('send-from-owned-terminal', [*send, '--to', 'run:' + RUN, '--from', owned]),
        ('worker-list', [
            'orchestration', 'worker-list', '--run', RUN, '--include-remote', '--full',
        ]),
        ('worker-start-missing-repo', [
            'orchestration', START, '--spec', SUBJECT, '--agent', 'cursor', '--run', RUN,
            '--worktree', 'new-child', '--repo', MISSING_REPO,
        ]),
        ('run-list', ['orchestration', 'run-list']),
        ('run-list-full', ['orchestration', 'run-list', '--full']),
        ('run-show', ['orchestration', 'run-show', '--id', RUN, '--full']),
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


def clean_record(record, patterns, homes):
    argv = public_argv(record['argv'], patterns, homes)
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


def collect(env, receiver, owned):
    records = []
    for name, args in calls(receiver, owned):
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


def main(argv):
    dry = '--dry' in argv
    env = clean_env()
    version = orca_version(env)
    # wrap-up tests put a fake orca on PATH. A real build prints a dotted version.
    if dry and re.fullmatch(r'\d+\.\d+\.\d+', version) is None:
        print('fleet-watch contract skipped', file=sys.stderr)
        return 0
    directory = replies.FIXTURES / ('orca-' + version)
    if dry and not directory.is_dir():
        print('no recording for orca-%s' % version, file=sys.stderr)
        return 1
    patterns = replies.default_patterns()
    homes = [str(Path.home())]
    owned = None
    try:
        receiver = coordinator_handle(env)
        owned = create_terminal(env)
        records = collect(env, receiver, owned)
        cleaned = [clean_record(record, patterns, homes) for record in records]
    except RuntimeError as exc:
        print('fleet-watch-record: %s' % exc, file=sys.stderr)
        return 2
    finally:
        if owned:
            close_terminal(env, owned)
    if dry:
        failed = False
        for record in cleaned:
            path = directory / (record['name'] + '.json')
            if not path.is_file():
                print('missing %s' % record['name'], file=sys.stderr)
                failed = True
                continue
            saved = json.loads(path.read_text())
            fresh = replies.reply_shape(record)
            old = replies.reply_shape(saved)
            if fresh != old:
                failed = True
                print('shape changed: %s' % record['name'], file=sys.stderr)
                print(json.dumps({'saved': old, 'fresh': fresh}, sort_keys=True)[:2000], file=sys.stderr)
        if failed:
            return 1
        print('fleet-watch contract ok orca-%s' % version)
        return 0
    directory.mkdir(parents=True, exist_ok=True)
    for record in cleaned:
        name = record.pop('name')
        path = directory / (name + '.json')
        path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
        print('recorded %s exit %s' % (name, record['exit_code']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
