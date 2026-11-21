#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# A cancelled head-checks run must leave no step process behind, gated or not, on TERM, INT and KILL.
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$script/head-checks.sh" "$script/heavy-gate.py" <<'PY'
import json, os, pathlib, shutil, signal, subprocess, sys, tempfile, time
runner, gate = sys.argv[1], sys.argv[2]
passed = failed = 0

def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:
        state = subprocess.check_output(['ps', '-o', 'stat=', '-p', str(pid)], text=True).strip()
    except subprocess.CalledProcessError:
        return False
    return not state.startswith('Z')

def gone_within(pid, seconds):
    deadline = time.time() + seconds
    while alive(pid) and time.time() < deadline:
        time.sleep(0.1)
    return not alive(pid)

def wait_for(predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    return None

def read_pid(path):
    try:
        text = path.read_text().strip()
    except FileNotFoundError:
        return None
    return int(text) if text.isdigit() else None

with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp); repo = root/'fixture'; repo.mkdir()
    home = root/'home'
    slot_root = home/'.cache/heavy-gate'
    reader = root/'reader'
    reader.write_text('#!/usr/bin/env bash\ncase "$1" in hardware) echo "12 8 1000000000";; model) echo fixture;; *) echo "0 90";; esac\n'); reader.chmod(0o755)
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
    git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid')
    (repo/'code.txt').write_text('base\n'); git('add', '.'); git('commit', '-qm', 'base'); base = git('rev-parse', 'HEAD'); git('update-ref', 'refs/remotes/origin/main', base)
    (repo/'.agents').mkdir(); conf = repo/'.agents/head-checks.conf'
    env = dict(os.environ, HOME=str(home), HEAVY_GATE_READER=str(reader), HEAVY_GATE_POLL_SECONDS='0.05', HEAD_CHECKS_WAIT_SECONDS='0')
    env.pop('HEAD_CHECKS_SLOTS', None)
    tmpdir = root/'tmp'
    env['TMPDIR'] = str(tmpdir)

    def claimed_slots():
        # The same slot-* directories Slots.claim and stuck_slot_names read.
        return sorted(p.name for p in slot_root.glob('slot-*'))

    def case(name, step, signals, ready='pidfile', kill=False, max_exit=None, setup=None, check=None, after=None):
        """signals: (delay seconds, signal) pairs sent to head-checks alone, after the step is ready."""
        global passed, failed
        slug = name.replace(' ', '-')
        pidfile = root/(slug + '.pid'); readyfile = root/(slug + '.ready')
        pidfile.unlink(missing_ok=True); readyfile.unlink(missing_ok=True)
        shutil.rmtree(tmpdir, ignore_errors=True); tmpdir.mkdir()
        conf.write_text(step.replace('PIDFILE', str(pidfile)).replace('READYFILE', str(readyfile)) + '\n')
        (repo/'code.txt').write_text(name + '\n'); git('add', '.'); git('commit', '-qm', name)
        sha = git('rev-parse', 'HEAD')
        holder = setup() if setup else None
        proc = subprocess.Popen(['bash', runner, '--repo', str(repo), '--ref', sha, '--base', base, '--config', str(conf)],
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
        problems = []
        if ready == 'pidfile':
            started = wait_for(lambda: read_pid(pidfile), 30)
        elif ready == 'readyfile':
            started = wait_for(readyfile.exists, 30)
        else:
            started = wait_for(ready, 30)
        if not started:
            failed += 1; print('FAIL', name, 'step never started')
            for pgid in (proc.pid, holder.pid if holder else None):
                if pgid:
                    try: os.killpg(pgid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError): pass
            proc.communicate(); return
        first = time.time()
        for delay, sig in signals:
            time.sleep(delay)
            os.kill(proc.pid, sig)
        if check:
            problems += check(pidfile, started)
        else:
            child = wait_for(lambda: read_pid(pidfile), 5) if ready == 'readyfile' else started
            if child is None:
                problems.append('step wrote no PIDFILE')
            elif not gone_within(child, 10 if kill else 15):
                problems.append(f'child {child} survived')
                os.kill(child, signal.SIGKILL)
        if kill:
            # finish cannot run after KILL: only the step must be gone.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            proc.communicate()
        else:
            try:
                out, _ = proc.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                out, _ = proc.communicate()
                problems.append('head-checks did not exit')
            else:
                took = time.time() - first
                if max_exit is not None and took > max_exit:
                    problems.append(f'head-checks took {took:.1f}s to exit (limit {max_exit}s)')
                if proc.returncode == 0:
                    problems.append('exit status is 0')
                if not any(l.startswith('Checks: FAIL head=' + sha) for l in out.splitlines()):
                    problems.append('no "Checks: FAIL head=<sha>" line')
                locks = [p.name for p in (home/'orca/workspaces/fixture').glob('*.lock')]
                if locks:
                    problems.append('lock left: ' + ', '.join(locks))
                temps = [p.name for p in tmpdir.glob('tmp.*')]
                if temps:
                    problems.append('temp files left: ' + ', '.join(temps))
        if after:
            problems += after()
        if holder:
            try: os.killpg(holder.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError): pass
            holder.wait(timeout=10)
        if problems:
            failed += 1; print('FAIL', name, '; '.join(problems))
        else:
            passed += 1; print('ok  ', name)

    gated = ': playwright; sleep 300 & echo $! > PIDFILE; wait'
    plain = 'sleep 300 & echo $! > PIDFILE; wait'
    case('gated step dies on TERM', gated, [(0, signal.SIGTERM)])
    case('plain step dies on TERM', plain, [(0, signal.SIGTERM)])
    case('gated step dies on INT', gated, [(0, signal.SIGINT)])
    case('gated step dies on KILL of head-checks', gated, [(0, signal.SIGKILL)], kill=True)

    case('plain step child started on TERM dies',
         "trap 'sleep 300 & echo $! > PIDFILE; wait' TERM; : > READYFILE; sleep 300 & wait",
         [(0, signal.SIGTERM)], ready='readyfile')

    def slot_free():
        held = claimed_slots()
        return ['slot still claimed under ~/.cache/heavy-gate: ' + ', '.join(held)] if held else []
    case('gated step releases its slot when its child ignores TERM',
         ': playwright; (trap "" TERM; exec sleep 300) & echo $! > PIDFILE; wait',
         [(0, signal.SIGTERM)], after=slot_free)
    for path in slot_root.glob('slot-*'):
        shutil.rmtree(path, ignore_errors=True)

    case('plain step dies on KILL of head-checks', plain, [(0, signal.SIGKILL)], kill=True)

    case('INT then TERM still cleans up', '(trap "" TERM; exec sleep 300) & echo $! > PIDFILE; wait',
         [(0, signal.SIGINT), (1, signal.SIGTERM)], max_exit=8)

    def hold_every_slot():
        holder = subprocess.Popen(['python3', gate, 'gate', '--weight', '2', '--', 'sleep', '60'], env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        if not wait_for(lambda: len(claimed_slots()) == 2, 10):
            print('     ', 'slot holder never claimed both slots')
        return holder
    def queued_gate():
        for record in (slot_root/'waiting').glob('*'):
            if not record.name.startswith('.'):
                try:
                    return json.loads(record.read_text())['pid']
                except (OSError, ValueError, KeyError):
                    pass
        return None
    def left_queue(pidfile, gate_pid):
        problems = []
        if not gone_within(gate_pid, 10):
            problems.append(f'queued gate {gate_pid} survived'); os.kill(gate_pid, signal.SIGKILL)
        if pidfile.exists():
            problems.append('gated command ran')
        return problems
    case('queued gated step leaves the queue on KILL of head-checks', ': playwright; echo $$ > PIDFILE; sleep 300',
         [(0, signal.SIGKILL)], ready=queued_gate, kill=True, setup=hold_every_slot, check=left_queue)
print(f'passed {passed}, failed {failed}')
sys.exit(bool(failed))
PY
