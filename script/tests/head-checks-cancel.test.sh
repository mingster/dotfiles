#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# A cancelled head-checks run must leave no step process behind, gated or not, on TERM and on KILL.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)/head-checks.sh" <<'PY'
import os, pathlib, shutil, signal, subprocess, sys, tempfile, time
runner = sys.argv[1]
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

with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp); repo = root/'fixture'; repo.mkdir()
    reader = root/'reader'
    reader.write_text('#!/usr/bin/env bash\ncase "$1" in hardware) echo "12 8 1000000000";; model) echo fixture;; *) echo "0 90";; esac\n'); reader.chmod(0o755)
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
    git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid')
    (repo/'code.txt').write_text('base\n'); git('add', '.'); git('commit', '-qm', 'base'); base = git('rev-parse', 'HEAD'); git('update-ref', 'refs/remotes/origin/main', base)
    (repo/'.agents').mkdir(); conf = repo/'.agents/head-checks.conf'
    env = dict(os.environ, HOME=str(root/'home'), HEAVY_GATE_READER=str(reader), HEAVY_GATE_POLL_SECONDS='0.05', HEAD_CHECKS_WAIT_SECONDS='0')
    env.pop('HEAD_CHECKS_SLOTS', None)
    tmpdir = root/'tmp'
    env['TMPDIR'] = str(tmpdir)

    def case(name, step, sig):
        global passed, failed
        pidfile = root/(name.replace(' ', '-') + '.pid')
        pidfile.unlink(missing_ok=True)
        shutil.rmtree(tmpdir, ignore_errors=True); tmpdir.mkdir()
        conf.write_text(step.replace('PIDFILE', str(pidfile)) + '\n')
        (repo/'code.txt').write_text(name + '\n'); git('add', '.'); git('commit', '-qm', name)
        sha = git('rev-parse', 'HEAD')
        proc = subprocess.Popen(['bash', runner, '--repo', str(repo), '--ref', sha, '--base', base, '--config', str(conf)],
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
        child = None
        deadline = time.time() + 30
        while time.time() < deadline:
            if pidfile.exists() and pidfile.read_text().strip().isdigit():
                child = int(pidfile.read_text()); break
            time.sleep(0.1)
        if child is None:
            failed += 1; print('FAIL', name, 'step never started'); os.killpg(proc.pid, signal.SIGKILL); proc.communicate(); return
        os.kill(proc.pid, sig)
        deadline = time.time() + 15
        while alive(child) and time.time() < deadline:
            time.sleep(0.1)
        survived = alive(child)
        if survived:
            os.kill(child, signal.SIGKILL)
        problems = []
        if survived:
            problems.append(f'child {child} survived')
        if sig == signal.SIGKILL:
            # finish cannot run after KILL: only the child must be gone.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
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
                if proc.returncode == 0:
                    problems.append('exit status is 0')
                if not any(l.startswith('Checks: FAIL head=' + sha) for l in out.splitlines()):
                    problems.append('no "Checks: FAIL head=<sha>" line')
                locks = [p.name for p in (root/'home/orca/workspaces/fixture').glob('*.lock')]
                if locks:
                    problems.append('lock left: ' + ', '.join(locks))
                temps = [p.name for p in tmpdir.glob('tmp.*')]
                if temps:
                    problems.append('temp files left: ' + ', '.join(temps))
        if problems:
            failed += 1; print('FAIL', name, '; '.join(problems))
        else:
            passed += 1; print('ok  ', name)

    gated = ': playwright; sleep 300 & echo $! > PIDFILE; wait'
    plain = 'sleep 300 & echo $! > PIDFILE; wait'
    case('gated step dies on TERM', gated, signal.SIGTERM)
    case('plain step dies on TERM', plain, signal.SIGTERM)
    case('gated step dies on INT', gated, signal.SIGINT)
    case('gated step dies on KILL of head-checks', gated, signal.SIGKILL)
print(f'passed {passed}, failed {failed}')
sys.exit(bool(failed))
PY
