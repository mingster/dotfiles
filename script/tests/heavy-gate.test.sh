#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Exercise the command boundary with isolated home directories and sensor readings.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import contextlib, importlib.util, io, json, os, pathlib, select, shutil, signal, subprocess, sys, tempfile, time, unittest
from unittest import mock

scripts = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('heavy_gate', scripts/'heavy-gate.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.reading = self.root/'sample'
        self.reading.write_text('0 90')
        reader = self.root/'reader'
        reader.write_text('''#!/usr/bin/env bash
case "$1" in
  hardware) printf '%s\\n' "${HEAVY_GATE_HARDWARE:-12 8 1000000000}" ;;
  model) printf 'fixture\\n' ;;
  *) IFS= read -r reading < "$HEAVY_GATE_SAMPLE"; printf '%s\\n' "$reading" ;;
esac
''')
        reader.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.root), HEAVY_GATE_READER=str(reader),
                        HEAVY_GATE_SAMPLE=str(self.reading), HEAVY_GATE_POLL_SECONDS='0.05')
        self.processes = []
        self.addCleanup(self.stop)

    def stop(self):
        for p in self.processes:
            if p.poll() is None:
                p.terminate()
            p.communicate(timeout=8)

    def config(self, slots=2, load=12):
        path = self.root/'.config/heavy-gate/slots.conf'
        path.parent.mkdir(parents=True, exist_ok=True)
        import hashlib, json
        digest = hashlib.sha256(json.dumps({'hw.model': 'fixture', 'hw.ncpu': 12, 'hw.memsize': 1000000000}, sort_keys=True).encode()).hexdigest()
        path.write_text(f'slots={slots}\nload_max={load}\n# fingerprint={digest}\n')
        return path

    def set_reading(self, value):
        temporary = self.reading.with_suffix('.tmp')
        temporary.write_text(value)
        temporary.replace(self.reading)

    def run_gate(self, command, weight=1, gate_class=None, memory=None, env_memory=None, measure=False):
        env = dict(self.env, HEAVY_GATE_CLASS=gate_class) if gate_class else dict(self.env)
        if env_memory is not None:
            env['HEAVY_GATE_MEMORY_MB'] = str(env_memory)
        flag = ['--memory-mb', str(memory)] if memory is not None else []
        admission = ['--measure'] if measure else ['--weight', str(weight)]
        p = subprocess.Popen(['bash', str(scripts/'heavy-gate.sh'), *admission, *flag, '--', *command],
                             env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(p)
        return p

    def release(self, label):
        (self.root/f'release-{label}').write_text('go')

    def job(self, label='job', delay=0.15, weight=1, gate_class=None, memory=None, env_memory=None, hold=False, wrap=None):
        # Independent append-only workload events reveal actual overlap.
        # hold=True keeps the job running until release(label), so no sleep can race its end.
        code = '''import os,sys,time
with open(sys.argv[1], 'a', buffering=1) as f:
 f.write(f'{time.time()} start {sys.argv[2]} {os.getpid()}\\n')
 if sys.argv[4]:
  while not os.path.exists(sys.argv[4]): time.sleep(0.02)
 else:
  time.sleep(float(sys.argv[3]))
 f.write(f'{time.time()} end {sys.argv[2]} {os.getpid()}\\n')
'''
        argv = [sys.executable, '-c', code, str(self.root/'events'), label, str(delay),
                str(self.root/f'release-{label}') if hold else '']
        return self.run_gate(wrap(argv) if wrap else argv, weight, gate_class, memory, env_memory)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail('timed out waiting for observable condition')

    def events(self):
        path = self.root/'events'
        return path.read_text().splitlines() if path.exists() else []

    def finish(self, p, status=0):
        out, err = p.communicate(timeout=10)
        self.assertEqual(p.returncode, status, out+err)
        return out, err

    def assert_overlap(self, weights, maximum):
        active = peak = 0
        for event in sorted(self.events(), key=lambda e: float(e.split()[0])):
            _, action, label, _ = event.split()
            active += weights[label] * (1 if action == 'start' else -1)
            peak = max(peak, active)
        self.assertEqual(active, 0)
        self.assertEqual(peak, maximum, self.events())

    def test_exit_code_and_argument_boundaries(self):
        self.finish(self.run_gate(['sh', '-c', 'test "$1" = "a b" || exit 9; exit 7', 'sh', 'a b']), 7)
        self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])

    def cleanup_gate(self, error, states, failing_signal, status=0, ps_error=None, check_status=False, live_child=False):
        self.config(1)
        real_run = subprocess.run
        real_popen = subprocess.Popen
        group = []
        self.cleanup_stderr = io.StringIO()

        def killpg(pgid, sig):
            group[:] = [pgid]
            self.cleanup_pgid = pgid
            self.assertEqual(len(list((self.root/'.cache/heavy-gate').glob('slot-*'))), 1)
            if check_status:
                self.assertIn(f"heavy-gate: child exited with status {status}\n",
                              self.cleanup_stderr.getvalue())
            if sig == failing_signal:
                raise error

        def run(command, *args, **kwargs):
            if command[0] == 'ps':
                if ps_error:
                    raise ps_error
                # Include another group's live member: only this group matters.
                output = '1 2 0 0 S other\n' + ''.join(
                    f'{group[0]} {100+i} 1 501 {state} worker\n' for i, state in enumerate([] if isinstance(error, ProcessLookupError) else states))
                self.cleanup_rows = output.splitlines()[1:]
                return subprocess.CompletedProcess(command, 0, output, '')
            return real_run(command, *args, **kwargs)

        args = module.argparse.Namespace(weight=1, head_checks=False,
                                         command=['--', 'sh', '-c', f'exit {status}'])
        def popen(command, *a, **kw):
            proc = (mock.Mock(pid=987654, returncode=None) if live_child and command[len(command) - len(args.command[1:]):] == args.command[1:]
                    else real_popen(command, *a, **kw))
            if command[len(command) - len(args.command[1:]):] == args.command[1:]:
                group[:] = [proc.pid]
                self.cleanup_pgid = proc.pid
                if live_child:
                    proc.wait.side_effect = subprocess.TimeoutExpired(['fixture-child'], 1200)
            return proc

        with contextlib.redirect_stderr(self.cleanup_stderr), \
             mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(module.subprocess, 'Popen', side_effect=popen), \
             mock.patch.object(module.os, 'waitid', return_value=None, create=True), \
             mock.patch.object(module.os, 'killpg', side_effect=killpg) as signals, \
             mock.patch.object(module.subprocess, 'run', side_effect=run):
            if live_child:
                # No host process is launched: this is the still-running child seam.
                with self.assertRaises(PermissionError):
                    module.gate(args)
                result = None
            else:
                result = module.gate(args)
                signals.assert_not_called()
                if check_status:
                    self.assertIn(f'heavy-gate: child exited with status {status}\n',
                                  self.cleanup_stderr.getvalue())
            held = not isinstance(error, ProcessLookupError) and (ps_error or any(
                not state.startswith('Z') for state in states))
            original_pgid = self.cleanup_pgid
            original_rows = getattr(self, 'cleanup_rows', [])
            paths = list((self.root/'.cache/heavy-gate').glob('slot-*'))
            print(f'cleanup child_exit={status} gate_exit={result} held={len(paths)} '
                  f'signal={failing_signal} states={states} inspection_error={ps_error!r}', flush=True)
            self.assertEqual(len(paths), int(bool(held)))
            if held:
                # A quarantined token cannot authorize a nested command, even while
                # its original gate PID is still alive in this in-process fixture.
                self.env['HEAVY_GATE_TOKEN'] = (paths[0]/'token').read_text()
                with mock.patch.dict(os.environ, self.env, clear=True):
                    self.assertFalse(module.holds_slot())
                dead = subprocess.Popen(['true'])
                dead.wait()
                (paths[0]/'pid').write_text(str(dead.pid))
                marker = self.root/f'unexpected-admission-{original_pgid}-{failing_signal}'
                self.assertFalse(marker.exists(), 'each cleanup case starts with a fresh marker')
                claimant = module.argparse.Namespace(weight=1, head_checks=False,
                    command=['--', 'touch', str(marker)])
                # Interrupt at the first wait, with no test sleeps or retries.
                with mock.patch.object(module.time, 'sleep', side_effect=module.Interrupted(signal.SIGTERM)):
                    with self.assertRaises(module.Interrupted):
                        module.gate(claimant)
                self.assertFalse(marker.exists())
                self.assertTrue(paths[0].exists())
                # Unknown inspection holds; positive empty/zombie proof reclaims.
                ps_error = None
                states[:] = ['Z', 'Z+']
                self.assertEqual(module.gate(claimant), 0)
                self.assertTrue(marker.exists())
                self.assertFalse(paths[0].exists())
                self.env.pop('HEAVY_GATE_TOKEN')
            self.cleanup_pgid = original_pgid
            self.cleanup_rows = original_rows
        return result

    def test_completed_group_without_live_members_preserves_child_status(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for states in ([], ['Z', 'Z+']):
                for status in (0, 7):
                    with self.subTest(signal=sig, states=states, status=status):
                        self.assertEqual(self.cleanup_gate(PermissionError(1, 'denied'),
                                                          states, sig, status), status)

    def test_completed_group_with_live_member_withholds_signal_and_reports_members(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for status in (0, 7):
                with self.subTest(signal=sig, status=status):
                    self.assertEqual(self.cleanup_gate(PermissionError(1, 'denied'),
                                                      ['Z', 'S'], sig, status), status)
                    diagnostic = self.cleanup_stderr.getvalue()
                    self.assertIn(f'pgid={self.cleanup_pgid}', diagnostic)
                    self.assertIn('signal withheld', diagnostic)
                    for row in self.cleanup_rows:
                        self.assertIn(row, diagnostic)
                    self.assertNotIn('other', diagnostic)

    def test_live_child_cleanup_error_reraises(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=sig):
                self.cleanup_gate(PermissionError(1, 'denied'), ['S'], sig, live_child=True)

    def test_reaped_or_unknown_generation_never_signals_recorded_group(self):
        self.config(1)
        for reaped, inspection, snapshot_error in (
                (True, None, None), (False, ChildProcessError(), None),
                (False, PermissionError('unknown child'), None),
                (False, None, subprocess.TimeoutExpired(['ps'], 3))):
            with self.subTest(reaped=reaped, inspection=inspection, snapshot_error=snapshot_error):
                shutil.rmtree(self.root/'.cache/heavy-gate', ignore_errors=True)
                proc = mock.Mock(pid=987654, returncode=7 if reaped else None)
                proc.wait.return_value = 7
                args = module.argparse.Namespace(weight=1, head_checks=False,
                                                 command=['--', 'fixture'])
                real_popen, real_run = subprocess.Popen, subprocess.run
                def run(command, *a, **kw):
                    if command[0] == 'ps':
                        if snapshot_error:
                            raise snapshot_error
                        return subprocess.CompletedProcess(command, 0,
                            '987654 987654 1 501 S reused-worker\n', '')
                    return real_run(command, *a, **kw)
                with mock.patch.dict(os.environ, self.env, clear=True), \
                     mock.patch.object(module.subprocess, 'Popen', side_effect=lambda command, *a, **kw:
                         proc if command[-1:] == ['fixture'] else real_popen(command, *a, **kw)), \
                     mock.patch.object(module.subprocess, 'run', side_effect=run), \
                     mock.patch.object(module.os, 'waitid', side_effect=inspection, create=True), \
                     mock.patch.object(module.os, 'killpg') as killpg:
                    self.assertEqual(module.gate(args), 7)
                    killpg.assert_not_called()
                    self.assertTrue(list((self.root/'.cache/heavy-gate').glob('slot-*')))

    def test_each_signal_requires_fresh_unreaped_child_authorization(self):
        self.config(1)
        proc = mock.Mock(pid=987654, returncode=None)
        proc.wait.return_value = 7
        args = module.argparse.Namespace(weight=1, head_checks=False, command=['--', 'fixture'])
        real_popen, real_run = subprocess.Popen, subprocess.run
        def run(command, *a, **kw):
            if command[0] == 'ps':
                return subprocess.CompletedProcess(command, 0,
                    '987654 987654 1 501 S fixture-worker\n', '')
            return real_run(command, *a, **kw)
        import itertools
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(module.subprocess, 'Popen', side_effect=lambda command, *a, **kw:
                 proc if command[-1:] == ['fixture'] else real_popen(command, *a, **kw)), \
             mock.patch.object(module.subprocess, 'run', side_effect=run), \
             mock.patch.object(module.time, 'monotonic', side_effect=itertools.count(step=4)), \
             mock.patch.object(module.os, 'waitid', side_effect=[None, ChildProcessError('generation lost')], create=True), \
             mock.patch.object(module.os, 'killpg') as killpg:
            self.assertEqual(module.gate(args), 7)
            killpg.assert_called_once_with(987654, signal.SIGTERM)
            self.assertTrue(list((self.root/'.cache/heavy-gate').glob('slot-*')))

    def test_missing_waitid_still_delivers_term_to_live_group(self):
        self.config(1)
        proc = mock.Mock(pid=987654, returncode=None)
        proc.wait.return_value = 7
        args = module.argparse.Namespace(weight=1, head_checks=False, command=['--', 'fixture'])
        real_popen, real_run = subprocess.Popen, subprocess.run
        gate_pgid = os.getpid()
        term_sent = []

        def killpg(pgid, sig):
            term_sent.append(sig)

        def run(command, *a, **kw):
            if command[0] == 'ps':
                state = 'Z' if term_sent else 'S'
                if len(command) > 1 and command[1] == '-p':
                    return subprocess.CompletedProcess(
                        command, 0, f'987654 987654 {gate_pgid} {state}\n', '')
                return subprocess.CompletedProcess(
                    command, 0, f'987654 987654 {gate_pgid} 501 {state} fixture-worker\n', '')
            return real_run(command, *a, **kw)

        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(module.subprocess, 'Popen', side_effect=lambda command, *a, **kw:
                 proc if command[-1:] == ['fixture'] else real_popen(command, *a, **kw)), \
             mock.patch.object(module.subprocess, 'run', side_effect=run), \
             mock.patch.object(module.os, 'waitid', None, create=True), \
             mock.patch.object(module.os, 'killpg', side_effect=killpg) as killpg_mock:
            self.assertEqual(module.gate(args), 7)
            killpg_mock.assert_any_call(987654, signal.SIGTERM)
            self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])

    def test_group_publication_failure_never_runs_command(self):
        self.config(1)
        real_write = pathlib.Path.write_text
        ran = self.root/'ran'
        def write(path, text, *args, **kwargs):
            if path.name == 'groups':
                raise OSError('fixture ledger publication failed')
            return real_write(path, text, *args, **kwargs)
        args = module.argparse.Namespace(weight=1, head_checks=False,
                                         command=['--', 'touch', str(ran)])
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(pathlib.Path, 'write_text', new=write):
            with self.assertRaises(OSError):
                module.gate(args)
        time.sleep(0.5)
        self.assertFalse(ran.exists())
        paths = list((self.root/'.cache/heavy-gate').glob('slot-*'))
        self.assertEqual(len(paths), 1)
        with mock.patch.dict(os.environ, dict(self.env,
                             HEAVY_GATE_TOKEN=(paths[0]/'token').read_text()), clear=True):
            self.assertFalse(module.holds_slot())
        dead = subprocess.Popen(['true'])
        dead.wait()
        (paths[0]/'pid').write_text(str(dead.pid))
        with mock.patch.dict(os.environ, self.env, clear=True):
            self.assertTrue(module.Slots(1).claim(1))

    def test_gate_killed_before_publication_is_reclaimed(self):
        self.config(1)
        with mock.patch.dict(os.environ, self.env, clear=True):
            dying = module.Slots(1)
            self.assertTrue(dying.claim(1))
            slot = dying.owned[0]
            self.assertTrue((slot/'prelaunch').exists())
            self.assertFalse((slot/'groups-ready').exists())
            dead = subprocess.Popen(['true']); dead.wait()
            (slot/'pid').write_text(str(dead.pid))
            self.assertTrue(module.Slots(1).claim(1))

    def test_dead_owner_with_live_group_is_not_reclaimed(self):
        self.config(1)
        group = subprocess.Popen(['sleep', '30'], start_new_session=True)
        self.addCleanup(lambda: (group.kill(), group.wait()))
        with mock.patch.dict(os.environ, self.env, clear=True):
            dying = module.Slots(1)
            self.assertTrue(dying.claim(1))
            slot = dying.owned[0]
            dying.record_groups([group])
            dying.launched()
            dead = subprocess.Popen(['true']); dead.wait()
            (slot/'pid').write_text(str(dead.pid))
            claimant = module.Slots(1)
            self.assertFalse(claimant.claim(1))
            self.assertEqual(claimant.stuck, [slot.name])
            self.assertTrue(slot.exists())

    def dead_pid(self):
        dead = subprocess.Popen(['true'])
        dead.wait()
        return dead.pid

    def seed_slot(self, *, running=False, groups_ready=True, groups=None, quarantine=False, pid=None):
        self.config(1)
        slot = self.root / '.cache/heavy-gate/slot-1'
        slot.mkdir(parents=True)
        (slot / 'pid').write_text(str(pid if pid is not None else self.dead_pid()))
        (slot / 'groups').write_text(json.dumps(groups if groups is not None else [424242]))
        if groups_ready:
            (slot / 'groups-ready').touch()
        if running:
            (slot / 'running').touch()
        if quarantine:
            (slot / 'quarantine').touch()
        return slot

    def empty_members(self, _pgid):
        return []

    def zombie_members(self, _pgid):
        return [('Z', 'fixture-zombie')]

    def live_members(self, _pgid):
        return [('S', 'fixture-live')]

    def try_reclaim(self, members):
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(module, 'group_members', side_effect=members):
            return module.Slots(1).claim(1)

    def test_dead_owner_running_marker_empty_groups_reclaimed(self):
        slot = self.seed_slot(running=True)
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(module, 'group_members', side_effect=self.empty_members):
            gates = module.Slots(1)
            gates.reclaim()
            self.assertEqual(gates.stuck, [])
        self.assertFalse(slot.exists())

    def test_dead_owner_live_group_held(self):
        slot = self.seed_slot(running=True)
        self.assertFalse(self.try_reclaim(self.live_members))
        self.assertTrue(slot.exists())

    def test_dead_owner_missing_groups_ready_held(self):
        slot = self.seed_slot(groups_ready=False, running=True)
        self.assertFalse(self.try_reclaim(self.empty_members))
        self.assertTrue(slot.exists())

    def test_dead_owner_malformed_ledger_held(self):
        slot = self.seed_slot(running=True)
        (slot / 'groups').write_text('not-json')
        self.assertFalse(self.try_reclaim(self.empty_members))
        self.assertTrue(slot.exists())

    def test_dead_owner_quarantine_marker_held(self):
        slot = self.seed_slot(running=True, quarantine=True)
        self.assertFalse(self.try_reclaim(self.zombie_members))
        self.assertTrue(slot.exists())

    def test_dead_owner_quarantine_only_empty_groups_reclaimed(self):
        slot = self.seed_slot(quarantine=True)
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(module, 'group_members', side_effect=self.empty_members):
            gates = module.Slots(1)
            gates.reclaim()
            self.assertEqual(gates.stuck, [])
        self.assertFalse(slot.exists())

    def test_live_owner_held(self):
        slot = self.seed_slot(running=True, pid=os.getpid())
        self.assertFalse(self.try_reclaim(self.empty_members))
        self.assertTrue(slot.exists())

    def test_killed_gate_with_live_command_stays_held(self):
        self.config(1)
        self.run_gate(['sleep', '30'])
        slot = self.root/'.cache/heavy-gate/slot-1'
        self.wait_for(lambda: (slot/'groups-ready').exists() and not (slot/'prelaunch').exists())
        pgid = json.loads((slot/'groups').read_text())[0]
        self.addCleanup(lambda: os.killpg(pgid, signal.SIGKILL))
        owner = int((slot/'pid').read_text())
        os.kill(owner, signal.SIGKILL)
        self.processes[-1].wait()
        with mock.patch.dict(os.environ, self.env, clear=True):
            self.assertFalse(module.Slots(1).claim(1))
        self.assertTrue(slot.exists())

    def test_marker_publication_failure_rejects_nested_token(self):
        self.config(1)
        real_touch = pathlib.Path.touch
        failures = []
        def touch(path, *args, **kwargs):
            if path.name in ('quarantine', 'groups-ready'):
                failures.append(path.name)
                raise OSError('fixture marker publication failed')
            return real_touch(path, *args, **kwargs)
        args = module.argparse.Namespace(weight=1, head_checks=False,
                                         command=['--', 'sh', '-c', 'exit 7'])
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(pathlib.Path, 'touch', new=touch):
            with self.assertRaises(OSError):
                module.gate(args)
        self.assertTrue(failures)
        paths = list((self.root/'.cache/heavy-gate').glob('slot-*'))
        self.assertEqual(len(paths), 1)
        with mock.patch.dict(os.environ, dict(self.env,
                             HEAVY_GATE_TOKEN=(paths[0]/'token').read_text()), clear=True):
            self.assertFalse(module.holds_slot())

    def test_live_owner_authorized_but_legacy_token_requires_new_claim(self):
        with mock.patch.dict(os.environ, self.env, clear=True):
            slots = module.Slots(2)
            self.assertTrue(slots.claim(1))
            os.environ['HEAVY_GATE_TOKEN'] = slots.token
            self.assertTrue(module.holds_slot())
            legacy = slots.root/'slot-2'
            legacy.mkdir()
            (legacy/'pid').write_text(str(os.getpid()))
            (legacy/'token').write_text('legacy')
            os.environ['HEAVY_GATE_TOKEN'] = 'legacy'
            self.assertFalse(module.holds_slot())
            slots.revoke()

    def test_authorization_revocation_failure_surfaces_without_signalling(self):
        self.config(1)
        real_rename = pathlib.Path.rename
        def rename(path, target):
            if path.name == 'running':
                raise PermissionError('fixture authorization revocation failed')
            return real_rename(path, target)
        args = module.argparse.Namespace(weight=1, head_checks=False,
                                         command=['--', 'sh', '-c', 'exit 7'])
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(pathlib.Path, 'rename', new=rename), \
             mock.patch.object(module.os, 'killpg') as killpg:
            with self.assertRaises(PermissionError):
                module.gate(args)
            killpg.assert_not_called()
            paths = list((self.root/'.cache/heavy-gate').glob('slot-*'))
            self.assertEqual(len(paths), 1)
            with mock.patch.dict(os.environ, dict(self.env,
                             HEAVY_GATE_TOKEN=(paths[0]/'token').read_text()), clear=True):
                self.assertFalse(module.holds_slot(),
                                 'failed rename must not leave old token authorized')
            marker = self.root/'stale-token-command'
            claimant = module.argparse.Namespace(weight=1, head_checks=False,
                                                 command=['--', 'touch', str(marker)])
            with mock.patch.dict(os.environ, self.env, clear=True), \
                 mock.patch.object(module.time, 'sleep', side_effect=module.Interrupted(signal.SIGTERM)):
                with self.assertRaises(module.Interrupted):
                    module.gate(claimant)
            self.assertFalse(marker.exists(), 'stale token must not admit a command')
            dead = subprocess.Popen(['true'])
            dead.wait()
            (paths[0]/'pid').write_text(str(dead.pid))
            with mock.patch.dict(os.environ, self.env, clear=True), \
                 mock.patch.object(module, 'group_members', side_effect=self.empty_members):
                stuck = module.Slots(1)
                stuck.reclaim()
                self.assertEqual(stuck.stuck, [])
            self.assertFalse(paths[0].exists())

    def test_later_cleanup_cannot_forget_failed_publication(self):
        with mock.patch.dict(os.environ, self.env, clear=True):
            slots = module.Slots(1)
            self.assertTrue(slots.claim(1))
            # Model successful authorization revocation before ledger publication.
            (slots.owned[0]/'running').rename(slots.owned[0]/'quarantine')
            first = mock.Mock(pid=987651)
            later = mock.Mock(pid=987652)
            real_write = pathlib.Path.write_text
            def write(path, text, *args, **kwargs):
                if path.name == 'groups':
                    raise OSError('fixture first publication failed')
                return real_write(path, text, *args, **kwargs)
            with mock.patch.object(pathlib.Path, 'write_text', new=write):
                with self.assertRaises(OSError):
                    slots.record_groups([first])
            slots.record_groups([later])
            # The later group is gone; the earlier survivor must still hold capacity.
            def members(pgid):
                return [('S', 'fixture survivor')] if pgid == first.pid else []
            with mock.patch.object(module, 'group_members', side_effect=members):
                slots.release()
                self.assertEqual(len(list(slots.root.glob('slot-*'))), 1)

    def test_child_status_is_logged_before_cleanup(self):
        self.assertEqual(self.cleanup_gate(ProcessLookupError(), [], signal.SIGTERM,
                                          7, check_status=True), 7)

    def test_cleanup_missing_group_preserves_child_status(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=sig):
                self.assertEqual(self.cleanup_gate(ProcessLookupError(), ['S'], sig, 7), 7)

    def test_completed_group_inspection_failure_preserves_status(self):
        for error in (subprocess.CalledProcessError(1, ['ps']),
                      subprocess.TimeoutExpired(['ps'], 3)):
            with self.subTest(error=type(error).__name__):
                self.assertEqual(self.cleanup_gate(PermissionError(1, 'denied'), [],
                                                  signal.SIGTERM, ps_error=error), 0)
                diagnostic = self.cleanup_stderr.getvalue()
                self.assertIn(f'pgid={self.cleanup_pgid}', diagnostic)
                self.assertIn('signal withheld', diagnostic)
                self.assertIn('inspection failed', diagnostic)

    def test_timeout_reports_command_and_releases_all_slots(self):
        self.config()
        self.env['HEAVY_GATE_TIMEOUT_SECONDS'] = '2'
        _, err = self.finish(self.run_gate(['sleep', '4'], weight=2), 124)
        self.assertEqual(err, 'heavy-gate: timed out after 2s: sleep 4\n')
        self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])

    def test_timeout_stops_spawned_child(self):
        self.config()
        self.env['HEAVY_GATE_TIMEOUT_SECONDS'] = '2'
        pid_file = self.root/'child-pid'
        code = '''import pathlib, signal, subprocess, sys
child = subprocess.Popen(['sleep', '5'])
pathlib.Path(sys.argv[1]).write_text(str(child.pid))
def stop(*args):
    child.wait()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
child.wait()
'''
        p = self.run_gate([sys.executable, '-c', code, str(pid_file)])
        self.wait_for(pid_file.exists)
        pid = int(pid_file.read_text())
        self.finish(p, 124)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])

    def test_timeout_kills_command_ignoring_sigterm(self):
        self.config()
        self.env['HEAVY_GATE_TIMEOUT_SECONDS'] = '2'
        # Finite even before timeout support, so the RED run leaves no job behind.
        command = ['bash', '-c', "trap '' TERM; end=$((SECONDS+8)); while ((SECONDS<end)); do :; done; echo survived"]
        p = self.run_gate(command)
        started = time.monotonic()
        out, _ = self.finish(p, 124)
        self.assertEqual(out, '')
        self.assertLess(time.monotonic()-started, 8)
        self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])

    def test_fast_command_preserves_output_and_status_with_timeout(self):
        self.config()
        self.env['HEAVY_GATE_TIMEOUT_SECONDS'] = '2'
        out, err = self.finish(self.run_gate(['sh', '-c', 'echo output; echo error >&2; exit 7']), 7)
        self.assertEqual((out, err), ('output\n', 'error\nheavy-gate: child exited with status 7\n'))

    def test_timeout_can_be_disabled(self):
        self.config()
        for value in ('0', 'none'):
            with self.subTest(value=value):
                self.env['HEAVY_GATE_TIMEOUT_SECONDS'] = value
                self.finish(self.run_gate(['sleep', '2.2']))

    def started(self, label):
        return any(e.split()[1:3] == ['start', label] for e in self.events())

    def test_long_job_keeps_last_slot_for_short_job(self):
        self.config(2)
        first = self.job('long1', 1.5, gate_class='long')
        self.wait_for(lambda: self.started('long1'))
        second = self.job('long2', 0.1, gate_class='long')
        short = self.job('short', 0.1)
        self.finish(short)
        self.assertTrue(self.started('short'))
        self.assertFalse(self.started('long2'), self.events())
        self.finish(first)
        self.finish(second)
        self.assertTrue(self.started('long2'))

    def test_without_long_job_admission_is_unchanged(self):
        self.config(2)
        jobs = [self.job(str(i), 0.3, gate_class=c) for i, c in enumerate((None, None, None, None))]
        for p in jobs:
            self.finish(p)
        self.assert_overlap({str(i): 1 for i in range(4)}, 2)

    def test_long_job_weight_is_capped_to_leave_a_slot(self):
        self.config(2)
        long = self.job('long', 1.5, weight=2, gate_class='long')
        self.wait_for(lambda: self.started('long'))
        self.finish(self.job('short', 0.1))
        self.assertEqual(len(list((self.root/'.cache/heavy-gate').glob('slot-*'))), 1)
        self.finish(long)

    def test_measure_runs_without_slots(self):
        self.config(2)
        heavy = self.job('heavy', 0.3, weight=2)
        self.wait_for(lambda: self.started('heavy'))
        out, err = self.finish(self.run_gate(['true'], measure=True))
        self.assertEqual(err, 'heavy-gate: child exited with status 0\n')
        measure_log = self.root / '.orca' / 'logs' / 'heavy-gate-measure.log'
        self.assertTrue(measure_log.exists())
        self.assertIn('duration_s=', measure_log.read_text())
        self.assertEqual(len(list((self.root/'.cache/heavy-gate').glob('slot-*'))), 2)
        self.finish(heavy)

    def test_measure_timeout_stops_child_and_logs(self):
        self.config()
        self.env['HEAVY_GATE_TIMEOUT_SECONDS'] = '0.2'
        pid_file = self.root / 'measure-pid'
        code = '''import os, pathlib, sys, time
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
os.close(1)
os.close(2)
time.sleep(30)
'''
        p = self.run_gate([sys.executable, '-c', code, str(pid_file)], measure=True)
        self.wait_for(pid_file.exists)
        pid = int(pid_file.read_text())
        def cleanup_pid():
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGKILL)
        self.addCleanup(cleanup_pid)
        self.finish(p, 124)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        measure_log = self.root / '.orca' / 'logs' / 'heavy-gate-measure.log'
        self.assertTrue(measure_log.exists())
        self.assertIn('duration_s=', measure_log.read_text())

    def host_memory(self, mib):
        self.env['HEAVY_GATE_HARDWARE'] = f'12 8 {mib * 1024 * 1024}'

    def memory_files(self):
        return sorted(p.read_text() for p in (self.root/'.cache/heavy-gate').glob('slot-*/memory'))

    def test_declared_memory_over_host_total_never_runs_at_once(self):
        self.host_memory(3000)
        first = self.job('first', memory=2000, hold=True)
        self.wait_for(lambda: self.started('first'))
        second = self.job('second', 0.1, memory=2000)
        time.sleep(0.5)
        self.assertFalse(self.started('second'), 'second job started while first held its memory')
        self.release('first')
        self.finish(first)
        self.finish(second)
        self.assert_overlap({'first': 1, 'second': 1}, 1)

    def test_declared_memory_that_fits_runs_together(self):
        self.host_memory(3000)
        first = self.job('first', 0.5, memory=1000)
        self.wait_for(lambda: self.started('first'))
        second = self.job('second', 0.1, memory=1000)
        self.wait_for(lambda: self.started('second'))
        self.finish(first)
        self.finish(second)

    def test_memory_env_matches_flag_and_flag_wins(self):
        self.host_memory(3000)
        first = self.job('first', env_memory=2000, hold=True)
        self.wait_for(lambda: self.started('first'))
        self.assertEqual(self.memory_files(), ['2000'])
        second = self.job('second', 0.1, env_memory=2000)
        time.sleep(0.5)
        self.assertFalse(self.started('second'))
        self.release('first')
        self.finish(first)
        self.finish(second)
        flagged = self.job('flagged', memory=500, env_memory=2900, hold=True)
        self.wait_for(lambda: self.started('flagged'))
        self.assertEqual(self.memory_files(), ['500'])
        self.release('flagged')
        self.finish(flagged)

    # Command shapes that run playwright: the argv or the bash -c script names it.
    PLAYWRIGHT_SHAPES = {
        'direct': lambda argv: ['sh', '-c', 'exec "$@"', 'playwright', *argv],
        'bunx': lambda argv: ['sh', '-c', 'shift; exec "$@"', 'bunx', 'playwright', *argv],
        'npx': lambda argv: ['sh', '-c', 'shift; exec "$@"', 'npx', 'playwright', *argv],
        'bashc': lambda argv: ['bash', '-c', 'exec "$@" # bunx playwright test', '_', *argv],
    }

    def test_playwright_default_is_declared_and_declared_value_wins(self):
        self.host_memory(15360)
        for name, wrap in self.PLAYWRIGHT_SHAPES.items():
            job = self.job(name, hold=True, wrap=wrap)
            self.wait_for(lambda: self.started(name))
            self.assertEqual(self.memory_files(), ['8192'], name)
            self.release(name)
            self.finish(job)
        declared = self.job('declared', memory=500, hold=True, wrap=self.PLAYWRIGHT_SHAPES['bunx'])
        self.wait_for(lambda: self.started('declared'))
        self.assertEqual(self.memory_files(), ['500'])
        self.release('declared')
        self.finish(declared)
        env_declared = self.job('envdeclared', env_memory=700, hold=True, wrap=self.PLAYWRIGHT_SHAPES['npx'])
        self.wait_for(lambda: self.started('envdeclared'))
        self.assertEqual(self.memory_files(), ['700'])
        self.release('envdeclared')
        self.finish(env_declared)

    def test_other_undeclared_job_still_declares_nothing(self):
        self.host_memory(15360)
        job = self.job('plain', hold=True)
        self.wait_for(lambda: self.started('plain'))
        self.assertEqual(self.memory_files(), [])
        self.release('plain')
        self.finish(job)

    def test_incident_numbers_9216_job_and_playwright_never_run_at_once(self):
        self.host_memory(15360)
        checks = self.job('checks', memory=9216, hold=True)
        self.wait_for(lambda: self.started('checks'))
        browser = self.job('browser', 0.1, wrap=self.PLAYWRIGHT_SHAPES['bunx'])
        time.sleep(0.5)
        self.assertFalse(self.started('browser'), 'browser run started beside a 9216 MiB job')
        self.release('checks')
        self.finish(checks)
        self.finish(browser)
        self.assert_overlap({'checks': 1, 'browser': 1}, 1)

    def test_memory_record_is_in_the_slot_and_released_with_it(self):
        self.host_memory(3000)
        self.config(2)
        heavy = self.job('heavy', 0.5, weight=2, memory=1500)
        self.wait_for(lambda: self.started('heavy'))
        self.assertEqual(self.memory_files(), ['1500'])
        self.finish(heavy)
        self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])

    def test_dead_owner_does_not_hold_declared_memory(self):
        self.host_memory(3000)
        slot = self.root/'.cache/heavy-gate/slot-1'
        slot.mkdir(parents=True)
        dead = subprocess.Popen(['true']); dead.wait()
        (slot/'pid').write_text(str(dead.pid))
        (slot/'memory').write_text('2500')
        _, err = self.finish(self.job('after', 0.1, memory=2000))
        self.assertTrue(self.started('after'), err)
        self.assertFalse(slot.exists())

    def test_job_larger_than_host_runs_alone_and_does_not_wait_for_ever(self):
        self.host_memory(3000)
        big = self.job('big', memory=5000, hold=True)
        self.wait_for(lambda: self.started('big'))
        small = self.job('small', 0.1, memory=100)
        time.sleep(0.4)
        self.assertFalse(self.started('small'), 'a job larger than the host must run alone')
        self.release('big')
        out, err = self.finish(big)
        self.assertIn('exceeds host memory', err)
        self.assertIn('among jobs that declare memory', err)
        self.finish(small)
        self.assert_overlap({'big': 1, 'small': 1}, 1)

    def test_undeclared_job_is_not_held_by_declared_memory(self):
        self.host_memory(3000)
        declared = self.job('declared', 0.6, memory=3000)
        self.wait_for(lambda: self.started('declared'))
        plain = self.job('plain', 0.1)
        self.wait_for(lambda: self.started('plain'))
        self.finish(plain)
        self.finish(declared)
        self.assertEqual(self.memory_files(), [])

    def test_free_memory_floor_still_blocks_a_declared_job(self):
        self.host_memory(3000)
        self.set_reading('0 10')
        job = self.job('declared', 0.1, memory=100)
        time.sleep(0.4)
        self.assertFalse(self.started('declared'))
        self.set_reading('0 90')
        self.finish(job)

    def test_bad_memory_declaration_is_refused(self):
        for value in ('0', '-5', 'many'):
            _, err = self.finish(self.job(memory=value), 1)
            self.assertIn('memory', err)
        self.assertEqual(self.events(), [])

    def test_memory_floor_blocks_short_job_at_high_load(self):
        self.config(2)
        long = self.job('long', 1.5, gate_class='long')
        self.wait_for(lambda: self.started('long'))
        self.set_reading('13 10')
        short = self.job('short', 0.1)
        time.sleep(0.5)
        self.assertFalse(self.started('short'))
        self.set_reading('0 90')
        self.finish(short)
        self.finish(long)

    def test_long_job_still_waits_on_load_sensor(self):
        self.config(3)
        first = self.job('long1', 1.5, gate_class='long')
        self.wait_for(lambda: self.started('long1'))
        self.set_reading('13 90')
        second = self.job('long2', 0.1, gate_class='long')
        time.sleep(0.5)
        self.assertFalse(self.started('long2'))
        self.set_reading('0 90')
        self.finish(second)
        self.finish(first)

    def test_single_slot_has_nothing_to_reserve(self):
        self.config(1)
        self.finish(self.job('long', 0.1, gate_class='long'))
        self.assertTrue(self.started('long'))

    def test_unknown_class_is_rejected(self):
        self.config(2)
        _, err = self.finish(self.job('x', 0.1, gate_class='lng'), 1)
        self.assertIn('HEAVY_GATE_CLASS', err)
        self.assertFalse(self.started('x'))

    def test_fallback_without_config_respects_two_slots(self):
        jobs = [self.job(str(i), 0.3) for i in range(6)]
        for p in jobs:
            self.finish(p)
        self.assert_overlap({str(i): 1 for i in range(6)}, 2)
        self.assertFalse((self.root/'.config/heavy-gate/slots.conf').exists())

    def test_configured_slots_respected(self):
        self.config(1)
        jobs = [self.job(str(i)) for i in range(3)]
        for p in jobs:
            self.finish(p)
        self.assert_overlap({str(i): 1 for i in range(3)}, 1)

    def assert_config_fallback(self):
        self.set_reading('11 90')
        out, err = self.finish(self.run_gate(['sh', '-c', 'echo ran; exit 7'], weight=2), 7)
        self.assertEqual(out, 'ran\n')
        self.assertEqual(len(err.splitlines()), 2, err)
        self.assertIn('heavy-gate: child exited with status 7\n', err)
        self.assertIn('using slots=2 load_max=12', err)
        _, err = self.finish(self.job(weight=3), 1)
        self.assertIn('weight', err)
        self.set_reading('12.1 90')
        p = self.job(weight=2)
        self.wait_for(lambda: bool(select.select([p.stderr], [], [], 0)[0]))
        warning = p.stderr.readline()
        self.assertIn('using slots=2 load_max=12', warning)
        self.assertIn('load 12.10 exceeds 12', p.stderr.readline())
        self.assertEqual(self.events(), [])
        self.set_reading('11 90')
        _, err = self.finish(p)
        self.assertEqual(err, 'heavy-gate: child exited with status 0\n')
        self.assertEqual(len(self.events()), 2)

    def test_missing_config_warns_and_uses_complete_fallback(self):
        self.assert_config_fallback()

    def test_partial_config_warns_and_uses_complete_fallback(self):
        path = self.config(slots=1, load=1)
        path.write_text(path.read_text().replace('load_max=1\n', ''))
        self.assert_config_fallback()

    def test_non_numeric_slots_warns_and_uses_complete_fallback(self):
        self.config(slots='oops', load=1)
        self.assert_config_fallback()

    def test_zero_slots_warns_and_uses_complete_fallback(self):
        self.config(slots=0, load=1)
        self.assert_config_fallback()

    def test_nan_load_warns_and_uses_complete_fallback(self):
        self.config(slots=1, load='nan')
        self.assert_config_fallback()

    def test_unreadable_config_warns_and_uses_complete_fallback(self):
        path = self.config()
        path.unlink()
        path.mkdir()
        self.assert_config_fallback()

    def test_force_synthetic_calibration_replaces_malformed_config(self):
        path = self.config(slots='oops')
        result = self.probe('--force', '--calibrate', 'true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(path.read_text(), r'^slots=[123]\nload_max=14\n')
        self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)

    def test_weight_two_claims_atomically(self):
        self.config(2)
        heavy = self.job('heavy', 0.4, 2)
        self.wait_for(lambda: bool(self.events()))
        light = self.job('light')
        second = self.job('second', weight=2)
        for p in (heavy, light, second):
            self.finish(p)
        self.assert_overlap({'heavy': 2, 'light': 1, 'second': 2}, 2)

    def test_waiting_weight_two_job_gets_a_turn_within_bound(self):
        self.config(2)
        self.env['HEAVY_GATE_MAX_WAIT_SECONDS'] = '0.4'
        weights = {'big': 2}
        first = self.job('l0', 1.0)
        self.wait_for(lambda: self.started('l0'))
        big = self.job('big', 0.1, weight=2)
        lights = [first]
        for i in range(1, 7):
            weights[f'l{i}'] = 1
            lights.append(self.job(f'l{i}', 0.5))
            time.sleep(0.2)
        weights['l0'] = 1
        for p in (big, *lights):
            self.finish(p)
        starts = {e.split()[2]: float(e.split()[0]) for e in self.events() if e.split()[1] == 'start'}
        # Without the bound the light jobs hold a slot until the last one ends.
        self.assertLess(starts['big'], starts['l6'], self.events())
        self.assertLess(starts['big'] - starts['l0'], 0.4 + 1.0 + 0.5, self.events())
        self.assert_overlap(weights, 2)

    def test_weight_one_jobs_run_while_waiter_is_under_bound(self):
        self.config(2)
        self.env['HEAVY_GATE_MAX_WAIT_SECONDS'] = '60'
        first = self.job('l0', 1.2)
        self.wait_for(lambda: self.started('l0'))
        big = self.job('big', 0.1, weight=2)
        time.sleep(0.3)
        self.finish(self.job('l1', 0.1))
        self.assertFalse(self.started('big'), self.events())
        for p in (first, big):
            self.finish(p)
        self.assertTrue(self.started('big'))
        self.assert_overlap({'l0': 1, 'l1': 1, 'big': 2}, 2)

    def test_bad_max_wait_is_refused(self):
        self.config(2)
        self.env['HEAVY_GATE_MAX_WAIT_SECONDS'] = 'soon'
        _, err = self.finish(self.job(), 1)
        self.assertIn('HEAVY_GATE_MAX_WAIT_SECONDS', err)

    def test_weight_above_capacity_refuses(self):
        self.config(1)
        _, err = self.finish(self.job(weight=2), 1)
        self.assertIn('weight', err)
        self.assertEqual(self.events(), [])

    def test_stale_dead_pid_reclaimed(self):
        self.config(1)
        dead = subprocess.Popen(['true']); dead.wait()
        slot = self.root/'.cache/heavy-gate/slot-1'
        slot.mkdir(parents=True)
        (slot/'pid').write_text(str(dead.pid))
        self.finish(self.job())
        self.assertFalse(slot.exists())

    def test_live_pid_preserved(self):
        self.config(1)
        slot = self.root/'.cache/heavy-gate/slot-1'
        slot.mkdir(parents=True)
        (slot/'pid').write_text(str(os.getpid()))
        p = self.job()
        self.wait_for(lambda: bool(select.select([p.stderr], [], [], 0)[0]))
        self.assertIn('slots', p.stderr.readline())
        self.assertEqual(self.events(), [])
        self.assertEqual((slot/'pid').read_text(), str(os.getpid()))
        import shutil
        shutil.rmtree(slot)
        self.finish(p)

    def test_signal_releases_slots_and_stops_child(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(signal=sig):
                p = self.job(str(sig), 30, 2)
                self.wait_for(lambda: any(e.split()[2] == str(sig) for e in self.events()))
                pid = int(self.events()[-1].split()[3])
                p.send_signal(sig)
                self.finish(p, 128+sig)
                self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)

    def wait_on_reading(self, reading, expected):
        if not (self.root/'.config/heavy-gate/slots.conf').exists():
            self.config()
        self.set_reading(reading)
        p = self.job()
        self.wait_for(lambda: bool(select.select([p.stderr], [], [], 0)[0]))
        self.assertIn(expected, p.stderr.readline())
        self.assertEqual(self.events(), [])
        self.set_reading('0 90')
        self.finish(p)

    def test_wait_on_high_load_then_resume(self):
        self.wait_on_reading('12.1 90', 'load')

    def test_wait_on_low_memory_then_resume(self):
        self.wait_on_reading('0 19.9', 'free memory')

    def test_configured_load_limit(self):
        self.config(load=3)
        self.wait_on_reading('3.1 90', 'exceeds 3')

    def test_waiter_signal_leaves_no_slots(self):
        self.config()
        self.set_reading('20 90')
        p = self.job()
        self.wait_for(lambda: bool(select.select([p.stderr], [], [], 0)[0]))
        p.terminate()
        self.finish(p, 143)
        self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])

    def probe(self, *args):
        return subprocess.run(['bash', str(scripts/'hw-probe.sh'), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_probe_prints_hardware_without_writing_config(self):
        result = self.probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('cores_total=12\ncores_performance=8\nmemory_bytes=1000000000', result.stdout)
        self.assertFalse((self.root/'.config').exists())

    def test_calibration_refuses_high_load_without_starting_command(self):
        for limit in (None, 4):
            with self.subTest(limit=limit):
                if limit:
                    self.config(load=limit)
                self.set_reading('12.1 90')
                result = self.probe('--force', '--calibrate', 'touch '+str(self.root/'ran'))
                self.assertEqual(result.returncode, 1)
                self.assertIn('calibration refused', result.stderr)
                self.assertFalse((self.root/'ran').exists())

    def test_calibration_refuses_while_heavy_job_runs(self):
        p = self.job(delay=0.5)
        self.wait_for(lambda: bool(self.events()))
        result = self.probe('--calibrate', 'true')
        self.assertEqual(result.returncode, 1)
        self.assertIn('heavy jobs are running', result.stderr)
        self.finish(p)

    def test_failed_synthetic_calibration_preserves_config(self):
        path = self.config()
        before = path.read_text()
        result = self.probe('--force', '--calibrate', 'exit 9')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(path.read_text(), before)
        self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])

    def test_existing_calibration_requires_force(self):
        path = self.config()
        before = path.read_text()
        result = self.probe('--calibrate', 'touch '+str(self.root/'ran'))
        self.assertEqual(result.returncode, 1)
        self.assertIn('--force', result.stderr)
        self.assertEqual(path.read_text(), before)
        self.assertFalse((self.root/'ran').exists())

    def test_calibration_load_limit_uses_total_cores(self):
        self.env['HEAVY_GATE_HARDWARE'] = '10 4 1000000000'
        self.set_reading('8 90')
        result = self.probe('--calibrate', 'true')
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.root/'.config/heavy-gate/slots.conf'
        self.assertIn('load_max=12\n', path.read_text())
        # The recorded limit must also permit later calibration at idle team load.
        result = self.probe('--force', '--calibrate', 'true')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_calibration_excludes_cold_warmup_from_baseline(self):
        workload = self.root/'workload.py'
        workload.write_text('''import fcntl, pathlib, time
counter = pathlib.Path(__file__).with_name('invocations')
with counter.open('a+') as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    stream.seek(0)
    invocation = len(stream.readlines()) + 1
    stream.write('run\\n')
time.sleep(1.5 if invocation == 1 else 0.15 if invocation == 2 else 0.6)
''')
        import shlex
        result = self.probe('--calibrate', shlex.join([sys.executable, str(workload)]))
        self.assertEqual(result.returncode, 0, result.stderr)
        contents = (self.root/'.config/heavy-gate/slots.conf').read_text()
        self.assertTrue(contents.startswith('slots=1\n'), contents)
        self.assertRegex(result.stdout, r'(?m)^warmup wall_seconds=\d+\.\d+$')
        self.assertEqual(result.stdout.count('round copies='), 3)
        self.assertEqual(contents.count('wall_seconds='), 3)
        self.assertEqual((self.root/'invocations').read_text().splitlines(), ['run']*7)

    def test_synthetic_default_workload_persists_readings_and_fingerprint(self):
        local = self.root/'.config/heavy-gate/calibration.conf'
        local.parent.mkdir(parents=True)
        local.write_text('command=printf "run\\n" >> '+str(self.root/'runs')+'\n')
        result = self.probe('--calibrate')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root/'runs').read_text().splitlines(), ['run']*7)
        path = local.with_name('slots.conf')
        contents = path.read_text()
        self.assertRegex(contents, r'^slots=[123]\nload_max=14\n')
        self.assertIn('# date=', contents)
        self.assertIn('# fingerprint=', contents)
        self.assertIn('"hw.model": "fixture"', contents)
        self.assertEqual(contents.count('wall_seconds='), 3)
        self.assertEqual(contents.count('peak_load='), 3)
        self.assertEqual(contents.count('peak_memory_bytes='), 3)
        result = self.probe('--force', '--calibrate', 'true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(path.read_text(), contents)

    def test_changed_fingerprint_warns_and_uses_fallback(self):
        path = self.config(1, 1)
        path.write_text(path.read_text().replace('# fingerprint=', '# old='))
        self.set_reading('2 90')
        p = self.job(weight=2)
        _, err = self.finish(p)
        self.assertEqual(err.count('recalibrate'), 1)
        self.assertIn('slots=2 load_max=12', err)

    def test_calibration_has_exclusive_machine_budget(self):
        self.config()
        command = 'printf "start\\n" >> '+str(self.root/'calibrating')+'; sleep 0.2'
        p = subprocess.Popen(['bash', str(scripts/'hw-probe.sh'), '--force', '--calibrate', command],
                             env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(p)
        self.wait_for(lambda: (self.root/'calibrating').exists())
        job = self.job()
        self.wait_for(lambda: bool(select.select([job.stderr], [], [], 0)[0]))
        self.assertIn('slots', job.stderr.readline())
        self.assertEqual(self.events(), [])
        self.finish(p)
        self.finish(job)

    def nested(self, inner_count):
        # Every inner gate call runs inside the one slot the outer call holds.
        gate = str(scripts/'heavy-gate.sh')
        inner = f'for i in $(seq 1 {inner_count}); do bash {gate} -- sh -c \'echo "n$i slots=$(ls -d "$HOME"/.cache/heavy-gate/slot-* | wc -l | tr -d " ")"\' & done; wait'
        return subprocess.run(['bash', gate, '--', 'bash', '-c', inner], env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def test_nested_command_stays_in_accounted_ancestor_group(self):
        self.config(slots=1)
        gate = str(scripts/'heavy-gate.sh')
        outer = "import os,subprocess,sys; print('outer',os.getpgrp(),flush=True); subprocess.run(['bash',sys.argv[1],'--',sys.executable,'-c',\"import os; print('inner',os.getpgrp())\"],check=True)"
        out, _ = self.finish(self.run_gate([sys.executable, '-c', outer, gate]))
        groups = dict(line.split() for line in out.splitlines())
        self.assertEqual(groups['outer'], groups['inner'], 'nested session must remain in tracked group')

    def test_nested_survivor_keeps_capacity_after_outer_parent_exits(self):
        self.config(slots=1)
        ready, done = self.root/'nested-ready', self.root/'nested-done'
        gate = str(scripts/'heavy-gate.sh')
        child = "import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(1); pathlib.Path(sys.argv[2]).touch()"
        outer = """import pathlib,subprocess,sys,time
subprocess.Popen(['bash',sys.argv[1],'--',sys.executable,'-c',sys.argv[2],sys.argv[3],sys.argv[4]],
                 stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
limit=time.monotonic()+5
while not pathlib.Path(sys.argv[3]).exists():
 if time.monotonic()>limit: raise RuntimeError('nested readiness missing')
 time.sleep(.01)
"""
        self.finish(self.run_gate([sys.executable, '-c', outer, gate, child, str(ready), str(done)]))
        self.assertFalse(done.exists(), 'survivor must still be live when outer gate exits')
        self.assertTrue(list((self.root/'.cache/heavy-gate').glob('slot-*')),
                        'nested survivor must hold ancestor capacity')
        self.wait_for(done.exists)
        self.finish(self.job('after-survivor'))
        self.assertEqual(list((self.root/'.cache/heavy-gate').glob('slot-*')), [])

    def test_nested_gate_runs_inside_the_held_slot(self):
        self.config(slots=1)
        done = self.nested(1)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('slots=1', done.stdout)

    def test_four_parallel_nested_jobs_finish_with_one_slot(self):
        self.config(slots=1)
        done = self.nested(4)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.count('slots=1'), 4)

    def test_stale_token_does_not_bypass_the_budget(self):
        self.config(slots=1)
        self.env['HEAVY_GATE_TOKEN'] = 'stale'
        holder = self.job(delay=1)
        self.wait_for(lambda: self.events())
        waiting = self.job(label='second')
        self.wait_for(lambda: bool(select.select([waiting.stderr], [], [], 0)[0]))
        self.assertIn('slots', waiting.stderr.readline())
        self.finish(holder)
        self.finish(waiting)

    def test_free_host_does_not_sleep_before_admission(self):
        self.config(1)
        sleeps = []
        args = module.argparse.Namespace(weight=1, head_checks=False, command=['--', 'true'])
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(module.time, 'sleep', side_effect=lambda s: sleeps.append(s)):
            self.assertEqual(module.gate(args), 0)
        self.assertEqual(sleeps, [])

    def test_wait_appends_host_and_seconds_to_wait_log(self):
        self.config(1)
        wait_log = self.root / '.orca' / 'logs' / 'heavy-gate-wait.log'
        wait_log.parent.mkdir(parents=True, exist_ok=True)
        self.env['HEAVY_GATE_WAIT_LOG'] = str(wait_log)
        self.env['HEAVY_GATE_HOST'] = 'fixture-host'
        holder = self.job('hold', hold=True)
        self.wait_for(lambda: self.started('hold'))
        after = self.job('after', 0.05)
        self.wait_for(lambda: bool(select.select([after.stderr], [], [], 0)[0]))
        self.release('hold')
        self.finish(after)
        self.finish(holder)
        body = wait_log.read_text()
        self.assertRegex(body, r'host=fixture-host wait_s=[0-9.]+')

    def test_wait_log_stays_within_line_bound_after_many_appends(self):
        wait_log = self.root / '.orca' / 'logs' / 'heavy-gate-wait.log'
        wait_log.parent.mkdir(parents=True, exist_ok=True)
        bound = 40
        with mock.patch.dict(os.environ, {**self.env, 'HEAVY_GATE_WAIT_LOG': str(wait_log),
                                          'HEAVY_GATE_WAIT_LOG_MAX_LINES': str(bound)}, clear=True):
            for i in range(bound + 60):
                module.log_heavy_gate_wait(0.5 + i * 0.001)
        lines = [ln for ln in wait_log.read_text().splitlines() if ln.strip()]
        self.assertLessEqual(len(lines), bound)
        self.assertGreater(len(lines), 0)

    def test_failed_wait_log_trim_does_not_break_gate(self):
        wait_log = self.root / '.orca' / 'logs' / 'heavy-gate-wait.log'
        wait_log.parent.mkdir(parents=True, exist_ok=True)
        self.env['HEAVY_GATE_WAIT_LOG'] = str(wait_log)
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(module, 'trim_heavy_gate_wait_log', side_effect=OSError('trim failed')):
            module.log_heavy_gate_wait(1.0)
        self.config(1)
        args = module.argparse.Namespace(weight=1, head_checks=False, command=['--', 'true'])
        with mock.patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(module.gate(args), 0)

    def test_non_utf8_wait_log_does_not_fail_gate(self):
        wait_log = self.root / '.orca' / 'logs' / 'heavy-gate-wait.log'
        wait_log.parent.mkdir(parents=True, exist_ok=True)
        wait_log.write_bytes(b'\xff\xfejunk\n')
        self.env['HEAVY_GATE_WAIT_LOG'] = str(wait_log)
        self.env['HEAVY_GATE_HOST'] = 'fixture-host'
        self.config(1)
        holder = self.job('hold', hold=True)
        self.wait_for(lambda: self.started('hold'))
        waiter = self.job('after', 0.05)
        self.wait_for(lambda: bool(select.select([waiter.stderr], [], [], 0)[0]))
        self.release('hold')
        self.finish(waiter, 0)
        self.finish(holder, 0)
        self.assertRegex(wait_log.read_bytes().decode('utf-8', errors='replace'),
                         r'host=fixture-host wait_s=[0-9.]+')

    def test_concurrent_wait_log_trims_keep_every_fresh_row(self):
        wait_log = self.root / '.orca' / 'logs' / 'heavy-gate-wait.log'
        wait_log.parent.mkdir(parents=True, exist_ok=True)
        bound = 8
        stamp = '2025-06-01T12:00:00Z'
        seed = [f'{stamp} host=fixture-host wait_s=0.{i:03d}' for i in range(24)]
        wait_log.write_text('\n'.join(seed) + '\n')
        worker_env = dict(self.env, HEAVY_GATE_WAIT_LOG=str(wait_log),
                          HEAVY_GATE_WAIT_LOG_MAX_LINES=str(bound),
                          HEAVY_GATE_HOST='fixture-host')
        markers = [1.111, 2.222, 3.333, 4.444, 5.555, 6.666]
        child = '''import importlib.util, json, os, pathlib, sys
scripts = pathlib.Path(sys.argv[1])
marker = float(sys.argv[2])
env = json.loads(sys.argv[3])
spec = importlib.util.spec_from_file_location('heavy_gate', scripts / 'heavy-gate.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
os.environ.update(env)
mod.log_heavy_gate_wait(marker)
'''
        env_json = json.dumps(worker_env)
        processes = []
        try:
            for marker in markers:
                processes.append(subprocess.Popen(
                    [sys.executable, '-c', child, str(scripts), str(marker), env_json],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True))
            for proc in processes:
                out, err = proc.communicate(timeout=60)
                self.assertEqual(proc.returncode, 0, err)
        finally:
            for proc in processes:
                if proc.poll() is None:
                    proc.kill()
        body = wait_log.read_text(encoding='utf-8', errors='replace')
        for marker in markers:
            self.assertIn(f'wait_s={marker:.3f}', body, body)


class CalibrationMathTests(unittest.TestCase):
    def readings(self, walls=(10, 14, 16), memory=(30, 60, 70)):
        return [dict(copies=n, wall_seconds=w, peak_memory_percent=m)
                for n, w, m in zip((1, 2, 3), walls, memory)]

    def test_wall_time_limits_slots(self):
        self.assertEqual(module.choose_slots(self.readings()), 2)

    def test_memory_limits_slots(self):
        self.assertEqual(module.choose_slots(self.readings((10, 12, 14), (30, 60, 81))), 2)

    def test_largest_qualifying_round(self):
        self.assertEqual(module.choose_slots(self.readings((10, 12, 14))), 3)

    def test_exact_thresholds_are_excluded(self):
        self.assertEqual(module.choose_slots(self.readings((10, 15, 14), (30, 60, 80))), 1)

    def test_no_safe_round_preserves_existing_settings(self):
        with self.assertRaises(ValueError):
            module.choose_slots(self.readings(memory=(90, 90, 90)))


suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(GateTests),
                           unittest.defaultTestLoader.loadTestsFromTestCase(CalibrationMathTests)])
if os.environ.get('HEAVY_GATE_TEST_FILTER'):
    names = os.environ['HEAVY_GATE_TEST_FILTER'].split(',')
    suite = unittest.TestSuite(test for group in suite for test in group
                               if any(name in test.id() for name in names))
    if not suite.countTestCases():
        raise ValueError('test filter matched no cases')
result = unittest.TextTestRunner(verbosity=2).run(suite)
print(f'passed {result.testsRun-len(result.failures)-len(result.errors)}, failed {len(result.failures)+len(result.errors)}')
sys.exit(not result.wasSuccessful())
PY
