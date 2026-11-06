#!/usr/bin/env bash
# Start workers for leads. A lead writes a request file; one locked drain starts it under the coordinator's own binding.
#   fleet-start.sh request --role R --brief FILE --ticket T --kind builder|reviewer --from LEAD_HANDLE --repo OWNER/NAME
#                          [--host H] [--branch B] [--pr N]...      builder needs --branch, reviewer needs at least one --pr
#   fleet-start.sh drain [--dry-run]    start every queued request, oldest first (one drain at a time, mkdir lock)
#   fleet-start.sh settle ID            after checking that no worker exists, put an unknown-state request back in the queue
#   fleet-start.sh delay                count, median and max of started_at - requested_at over started requests
# `request` writes one file by atomic rename into FLEET_START_DIR (default ~/.claude/state/start-requests) and never calls orca.
# Per request, drain runs: fleet-watch.py --admit (host cap, plus the seats this script started in the last 120 s, because
# worker-list lags), usage-gate.py pick then check (exit 3 stops the drain), the project's guard-bash.py on the start command
# as PreToolUse JSON (the grill gate), then a "starting" marker, then orca worker-start (script/start-remote-worker.sh for a
# remote host) with --run and --from set to the coordinator, then the owner record, then a reply to the lead.
# A refused request stays queued, its reason in <id>.refused (fleet-watch puts it in the digest). A marker without a result
# (crash, failed start) is an unknown state: it is never started again until a person runs `settle`.
# Nothing here depends on a coordinator terminal or on who calls drain, so cron or the coordinator's own wake can run it.
# Config (FLEET_START_CONFIG, default ~/.config/fleet-start/config.json, see fleet-start.config.example.json):
#   local_host, run, coordinator, placement {kind: [host, ...]}, projects {owner/name: checkout path}.
# Env: FLEET_START_DIR, WORKER_DONE_OWNER_DIR, FLEET_WATCH_CONFIG (for --admit), ORCA_CLI_COMMAND,
#      FLEET_START_USAGE_GATE (default: python3 usage-gate.py beside this script), FLEET_START_NOW (epoch seconds, tests).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec python3 - "$here" "$@" <<'PY'
import glob, json, os, re, secrets, shlex, statistics, subprocess, sys, time

here, args = sys.argv[1], sys.argv[2:]
PENDING_SECONDS = 120


def die(message, code=2):
    print('fleet-start: ' + message, file=sys.stderr)
    sys.exit(code)


def now():
    return float(os.environ.get('FLEET_START_NOW') or time.time())


def path_env(name, default):
    return os.environ.get(name) or os.path.expanduser(default)


queue = path_env('FLEET_START_DIR', '~/.claude/state/start-requests')
owners = path_env('WORKER_DONE_OWNER_DIR', '~/.claude/state/dispatch-owners')
orca = shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca'))
gate = shlex.split(os.environ.get('FLEET_START_USAGE_GATE') or 'python3 ' + os.path.join(here, 'usage-gate.py'))


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp = os.path.join(os.path.dirname(path), '.tmp-%d-%s' % (os.getpid(), secrets.token_hex(3)))
    with open(temp, 'w') as stream:
        stream.write(text)
    os.rename(temp, path)


def read_json(path):
    try:
        with open(path) as stream:
            return json.load(stream)
    except (OSError, ValueError):
        return None


def parse(argv, valued, repeated=(), flags=()):
    got = {key: [] for key in repeated}
    for key in flags:
        got[key] = False
    i = 0
    while i < len(argv):
        name = argv[i][2:] if argv[i].startswith('--') else None
        if name in flags:
            got[name] = True
            i += 1
        elif name in valued or name in repeated:
            if i + 1 >= len(argv):
                die('--%s needs a value' % name)
            if name in repeated:
                got[name].append(argv[i + 1])
            else:
                got[name] = argv[i + 1]
            i += 2
        else:
            die('unknown argument: %s' % argv[i])
    return got


def request():
    got = parse(args[1:], {'role', 'brief', 'ticket', 'kind', 'host', 'from', 'repo', 'branch'}, repeated=('pr',))
    for key in ('role', 'brief', 'ticket', 'kind', 'from', 'repo'):
        if not got.get(key):
            die('refusing, --%s is required' % key)
    if got['kind'] not in ('builder', 'reviewer'):
        die('--kind must be builder or reviewer')
    if got['kind'] == 'builder' and not got.get('branch'):
        die('refusing, a builder request needs --branch (the owner record cannot prove a push without it)')
    if got['kind'] == 'reviewer' and not got['pr']:
        die('refusing, a reviewer request needs at least one --pr')
    for key, pattern in (('role', r'[A-Za-z0-9_-]+'), ('ticket', r'[A-Za-z0-9_.#-]+'), ('from', r'[A-Za-z0-9_-]+'),
                         ('repo', r'[\w.-]+/[\w.-]+'), ('host', r'[A-Za-z0-9_.-]+'), ('branch', r'[A-Za-z0-9_./-]+')):
        if got.get(key) and not re.fullmatch(pattern, got[key]):
            die('--%s has characters it may not have' % key)
    if not all(re.fullmatch(r'\d+', number) for number in got['pr']):
        die('--pr must be a number')
    try:
        with open(got['brief']) as stream:
            brief = stream.read(65536)
    except OSError as error:
        die('cannot read the brief: %s' % error)
    if not brief.strip():
        die('the brief is empty')
    at = now()
    ident = '%013d-%s' % (int(at * 1000), secrets.token_hex(3))
    record = {'id': ident, 'role': got['role'], 'brief': brief, 'ticket': got['ticket'], 'kind': got['kind'],
              'host': got.get('host') or None, 'from': got['from'], 'repo': got['repo'],
              'branch': got.get('branch') or None, 'pr': got['pr'], 'requested_at': at}
    write_atomic(os.path.join(queue, ident + '.json'), json.dumps(record))
    print(ident)


def lock_dir():
    return os.path.join(queue, 'drain.lock')


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True


def acquire_lock():
    """mkdir lock holding our pid. A dead holder's lock is cleared by one waiter at a time, after reading the pid again."""
    lock = lock_dir()
    os.makedirs(queue, exist_ok=True)
    for _ in range(3):
        try:
            os.mkdir(lock)
            with open(os.path.join(lock, 'pid'), 'w') as stream:
                stream.write(str(os.getpid()))
            return True
        except FileExistsError:
            pass
        try:
            holder = open(os.path.join(lock, 'pid')).read().strip()
        except OSError:
            holder = ''
        if holder and not pid_alive(holder):
            try:
                os.mkdir(lock + '.takeover')
            except FileExistsError:
                if time.time() - os.path.getmtime(lock + '.takeover') > 60:
                    os.rmdir(lock + '.takeover')
                continue
            try:
                again = open(os.path.join(lock, 'pid')).read().strip()
            except OSError:
                again = ''
            if again == holder:
                print('fleet-start: taking over stale lock of pid %s' % holder, file=sys.stderr)
                subprocess.run(['rm', '-rf', lock])
            os.rmdir(lock + '.takeover')
            continue
        break
    return False


def release_lock():
    subprocess.run(['rm', '-rf', lock_dir()])


def load_config():
    path = path_env('FLEET_START_CONFIG', '~/.config/fleet-start/config.json')
    config = read_json(path)
    if not isinstance(config, dict) or not config.get('run') or not config.get('coordinator'):
        die('config %s is missing or lacks run and coordinator' % path, 1)
    return config


def run(command, timeout, cwd=None, stdin=None):
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout, cwd=cwd, input=stdin,
                              stdin=None if stdin is not None else subprocess.DEVNULL)
    except (subprocess.SubprocessError, OSError) as error:
        return subprocess.CompletedProcess(command, 127, '', repr(error))


def seats_dir():
    return os.path.join(queue, 'seats')


def pending_seats(host):
    count = 0
    for path in glob.glob(os.path.join(seats_dir(), glob_escape(host) + '.*')):
        stamp = read_json(path)
        if isinstance(stamp, dict) and now() - stamp.get('at', 0) < PENDING_SECONDS:
            count += 1
        elif not isinstance(stamp, dict) or now() - stamp.get('at', 0) >= PENDING_SECONDS:
            try:
                os.unlink(path)
            except OSError:
                pass
    return count


def glob_escape(text):
    return glob.escape(text)


def admit(host):
    """None when the host has a free seat, else the reason."""
    watch = path_env('FLEET_WATCH_CONFIG', '~/.config/fleet-watch/config.json')
    done = run([sys.executable, os.path.join(here, 'fleet-watch.py'), '--config', watch, '--admit', host], 60)
    try:
        receipt = json.loads(done.stdout)
    except ValueError:
        return 'admission check failed: %s' % ((done.stderr or '').strip()[-200:] or 'no receipt')
    if not receipt.get('admitted'):
        return receipt.get('reason') or 'host not admitted'
    pending = pending_seats(host)
    if pending and receipt['occupied'] + pending >= receipt['cap']:
        return 'host cap exceeded: %s %d/%d counting %d pending seat(s) started under 120 s ago' % (
            host, receipt['occupied'] + pending, receipt['cap'], pending)
    return None


def usage(role):
    """('ok', provider, model, effort), ('stop', reason) for exit 3, or ('refused', reason)."""
    picked = run(gate + ['pick', '--role', role, '--json'], 60)
    try:
        chosen = (json.loads(picked.stdout) or {}).get('selected')
    except ValueError:
        chosen = None
    if picked.returncode == 3:
        return ('stop', 'usage gate: nothing allowed for %s (exit 3), the drain stops' % role)
    if picked.returncode != 0 or not chosen:
        return ('refused', 'usage gate: no provider picked for %s (exit %d)' % (role, picked.returncode))
    command = gate + ['check', '--provider', chosen['provider']]
    if chosen['provider'] in ('antigravity', 'cursor') and chosen.get('model'):
        command += ['--model', chosen['model']]
    if run(command, 60).returncode == 3:
        return ('stop', 'usage gate: %s is at its ceiling (exit 3), the drain stops' % chosen['provider'])
    return ('ok', chosen['provider'], chosen.get('model'), chosen.get('effort'))


def guard(config, req, start_args):
    """None when the project's guard-bash.py lets the start through, else its reason."""
    project = (config.get('projects') or {}).get(req['repo'])
    script = os.path.join(os.path.expanduser(project), '.claude', 'hooks', 'guard-bash.py') if project else None
    if not script or not os.path.isfile(script):
        return 'no guard-bash.py configured for %s' % req['repo']
    command = 'orca ' + shlex.join(start_args)
    payload = json.dumps({'tool_name': 'Bash', 'tool_input': {'command': command}, 'cwd': os.path.expanduser(project)})
    done = run([sys.executable, script], 30, cwd=os.path.expanduser(project), stdin=payload)
    if done.returncode != 0:
        return 'guard-bash.py failed (exit %d): %s' % (done.returncode, (done.stderr or '').strip()[-200:])
    for line in done.stdout.splitlines():
        try:
            decision = json.loads(line)['hookSpecificOutput']
        except (ValueError, KeyError, TypeError):
            continue
        if decision.get('permissionDecision') == 'deny':
            return 'guard: ' + (decision.get('permissionDecisionReason') or 'denied')
    return None


def find(node, key):
    if isinstance(node, dict):
        if isinstance(node.get(key), str):
            return node[key]
        for value in node.values():
            found = find(value, key)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find(value, key)
            if found:
                return found
    return None


def side(ident, suffix):
    return os.path.join(queue, ident + suffix)


def owner_record(dispatch, req):
    lines = [req['from'], 'kind=' + req['kind'], 'repo=' + req['repo']]
    if req['kind'] == 'builder':
        lines.append('branch=' + req['branch'])
    lines += ['pr=' + number for number in req['pr']]
    write_atomic(os.path.join(owners, dispatch), '\n'.join(lines) + '\n')


def reply(config, ident, started):
    done = run(['bash', os.path.join(here, 'orca-reply.sh'), '--to', started['from'],
                '--subject', 'started %s %s' % (started['role'], started['ticket']),
                '--body', 'dispatch=%s host=%s' % (started['dispatch'], started['host']),
                '--from', config['coordinator']], 90)
    if done.returncode == 0:
        write_atomic(side(ident, '.replied'), '')
    else:
        print('fleet-start: reply to %s failed, retried next drain: %s' % (started['from'], (done.stderr or '').strip()[-200:]), file=sys.stderr)


def try_start(config, req, dry):
    """('started',), ('refused', reason), ('stop', reason) or ('dry',)."""
    hosts = [req['host']] if req['host'] else (config.get('placement') or {}).get(req['kind']) or []
    if not hosts:
        return ('refused', 'no host named and no placement for kind %s in the fleet-start config' % req['kind'])
    reasons = []
    host = None
    for candidate in hosts:
        why = admit(candidate)
        if why is None:
            host = candidate
            break
        reasons.append('%s: %s' % (candidate, why))
    if host is None:
        return ('refused', 'admit refused, ' + '; '.join(reasons))
    picked = usage(req['role'])
    if picked[0] != 'ok':
        return picked
    _, provider, model, effort = picked
    remote = host != config.get('local_host')
    ticket = req['ticket']
    worktree = 'new-top-level' if remote or not re.fullmatch(r'\d+', ticket) else 'issue:' + ticket
    start_args = ['orchestration', 'worker-start', '--spec', req['brief'], '--worktree', worktree, '--agent', provider]
    if model:
        start_args += ['--model', model]
    if effort:
        start_args += ['--effort', effort]
    start_args += ['--run', config['run'], '--from', config['coordinator']]
    if remote:
        start_args += ['--on', host]
    why = guard(config, req, start_args)
    if why:
        return ('refused', why)
    command = (['bash', os.path.join(here, 'start-remote-worker.sh')] + start_args[2:] if remote else orca + start_args) + ['--json']
    if dry:
        print('dry-run: %s -> %s on %s: %s' % (req['id'], req['role'], host, shlex.join(command[:6] + ['...'] + command[-6:])))
        return ('dry',)
    ident = req['id']
    write_atomic(side(ident, '.starting'), json.dumps({'host': host, 'at': now()}))
    write_atomic(os.path.join(seats_dir(), '%s.%s' % (host, ident)), json.dumps({'at': now()}))
    done = run(command, 300)
    dispatch = None
    try:
        dispatch = find(json.loads(done.stdout), 'dispatchId')
    except ValueError:
        pass
    if done.returncode != 0 or not dispatch or not re.fullmatch(r'[A-Za-z0-9_-]+', dispatch):
        write_atomic(side(ident, '.starting'), json.dumps({'host': host, 'at': now(), 'exit': done.returncode,
                                                            'error': (done.stderr or '').strip()[-300:]}))
        return ('unknown', 'start exited %d without a dispatch id: %s' % (done.returncode, (done.stderr or '').strip()[-200:]))
    owner_record(dispatch, req)
    started = {'dispatch': dispatch, 'host': host, 'from': req['from'], 'role': req['role'], 'ticket': ticket,
               'requested_at': req['requested_at'], 'started_at': now()}
    write_atomic(side(ident, '.started'), json.dumps(started))
    for suffix in ('.starting', '.refused'):
        try:
            os.unlink(side(ident, suffix))
        except OSError:
            pass
    reply(config, ident, started)
    return ('started',)


def drain():
    got = parse(args[1:], set(), flags=('dry-run',))
    dry = got['dry-run']
    config = load_config()
    if not acquire_lock():
        print('fleet-start: another drain is running (lock %s), nothing to do' % lock_dir())
        return 0
    try:
        for path in sorted(glob.glob(os.path.join(queue, '*.started'))):
            ident = os.path.basename(path)[:-len('.started')]
            started = read_json(path)
            if started and not os.path.exists(side(ident, '.replied')) and not dry:
                reply(config, ident, started)
        for path in sorted(glob.glob(os.path.join(queue, '*.json'))):
            ident = os.path.basename(path)[:-len('.json')]
            if os.path.exists(side(ident, '.started')) or os.path.exists(side(ident, '.starting')):
                continue
            req = read_json(path)
            if not isinstance(req, dict):
                continue
            outcome = try_start(config, req, dry)
            if outcome[0] in ('refused', 'stop'):
                print('fleet-start: %s stays queued: %s' % (ident, outcome[1]))
                if not dry:
                    write_atomic(side(ident, '.refused'), outcome[1])
                if outcome[0] == 'stop':
                    return 0
            elif outcome[0] == 'unknown':
                print('fleet-start: %s state unknown, not started again until settled: %s' % (ident, outcome[1]), file=sys.stderr)
            elif outcome[0] == 'started':
                print('fleet-start: started %s' % ident)
    finally:
        release_lock()
    return 0


def settle():
    if len(args) != 2 or not re.fullmatch(r'[A-Za-z0-9-]+', args[1]):
        die('usage: settle ID')
    ident = args[1]
    if not os.path.exists(side(ident, '.json')):
        die('no request %s' % ident)
    if os.path.exists(side(ident, '.started')):
        die('request %s already started' % ident)
    for suffix in ('.starting', '.refused', '.noted'):
        try:
            os.unlink(side(ident, suffix))
        except OSError:
            pass
    for path in glob.glob(os.path.join(seats_dir(), '*.' + ident)):
        os.unlink(path)
    print('fleet-start: %s is queued again' % ident)


def delay():
    delays = []
    for path in glob.glob(os.path.join(queue, '*.started')):
        started = read_json(path)
        if isinstance(started, dict) and 'started_at' in started and 'requested_at' in started:
            delays.append(started['started_at'] - started['requested_at'])
    if not delays:
        print('count=0')
    else:
        print('count=%d median=%ds max=%ds' % (len(delays), round(statistics.median(delays)), round(max(delays))))


commands = {'request': request, 'drain': drain, 'settle': settle, 'delay': delay}
if not args or args[0] not in commands:
    die('usage: request|drain|settle|delay (see the header of this script)')
sys.exit(commands[args[0]]() or 0)
PY
