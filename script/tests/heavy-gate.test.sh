#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Exercise the command boundary with isolated home directories and sensor readings.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import contextlib, importlib.util, io, os, pathlib, select, signal, subprocess, sys, tempfile, time, unittest
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

    def run_gate(self, command, weight=1, gate_class=None):
        env = dict(self.env, HEAVY_GATE_CLASS=gate_class) if gate_class else self.env
        p = subprocess.Popen(['bash', str(scripts/'heavy-gate.sh'), '--weight', str(weight), '--', *command],
                             env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(p)
        return p

    def job(self, label='job', delay=0.15, weight=1, gate_class=None):
        # Independent append-only workload events reveal actual overlap.
        code = '''import os,sys,time
with open(sys.argv[1], 'a', buffering=1) as f:
 f.write(f'{time.time()} start {sys.argv[2]} {os.getpid()}\\n')
 time.sleep(float(sys.argv[3]))
 f.write(f'{time.time()} end {sys.argv[2]} {os.getpid()}\\n')
'''
        return self.run_gate([sys.executable, '-c', code, str(self.root/'events'), label, str(delay)], weight, gate_class)

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
                    f'{group[0]} {100+i} 1 501 {state} worker\n' for i, state in enumerate(states))
                self.cleanup_rows = output.splitlines()[1:]
                return subprocess.CompletedProcess(command, 0, output, '')
            return real_run(command, *args, **kwargs)

        args = module.argparse.Namespace(weight=1, head_checks=False,
                                         command=['--', 'sh', '-c', f'exit {status}'])
        with contextlib.redirect_stderr(self.cleanup_stderr), \
             mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(module.os, 'killpg', side_effect=killpg), \
             mock.patch.object(module.subprocess, 'run', side_effect=run):
            if live_child:
                # No host process is launched: this is the still-running child seam.
                proc = mock.Mock(pid=987654, returncode=None)
                proc.wait.side_effect = subprocess.TimeoutExpired(['fixture-child'], 1200)
                with mock.patch.object(module.subprocess, 'Popen', side_effect=lambda command, *a, **kw:
                        proc if command == args.command[1:] else real_popen(command, *a, **kw)):
                    with self.assertRaises(PermissionError):
                        module.gate(args)
                result = None
            else:
                result = module.gate(args)
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

    def test_cleanup_eperm_without_live_members_preserves_child_status(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for states in ([], ['Z', 'Z+']):
                for status in (0, 7):
                    with self.subTest(signal=sig, states=states, status=status):
                        self.assertEqual(self.cleanup_gate(PermissionError(1, 'denied'),
                                                          states, sig, status), status)

    def test_cleanup_eperm_with_live_member_preserves_status_and_reports_members(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for status in (0, 7):
                with self.subTest(signal=sig, status=status):
                    self.assertEqual(self.cleanup_gate(PermissionError(1, 'denied'),
                                                      ['Z', 'S'], sig, status), status)
                    diagnostic = self.cleanup_stderr.getvalue()
                    self.assertIn(f'pgid={self.cleanup_pgid}', diagnostic)
                    self.assertIn('denied', diagnostic)
                    for row in self.cleanup_rows:
                        self.assertIn(row, diagnostic)
                    self.assertNotIn('other', diagnostic)

    def test_live_child_cleanup_error_reraises(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=sig):
                self.cleanup_gate(PermissionError(1, 'denied'), ['S'], sig, live_child=True)

    def test_group_publication_failure_holds_after_owner_exit(self):
        self.config(1)
        real_write = pathlib.Path.write_text
        def write(path, text, *args, **kwargs):
            if path.name == 'groups':
                raise OSError('fixture ledger publication failed')
            return real_write(path, text, *args, **kwargs)
        args = module.argparse.Namespace(weight=1, head_checks=False,
                                         command=['--', 'sh', '-c', 'exit 7'])
        with mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(pathlib.Path, 'write_text', new=write):
            self.assertEqual(module.gate(args), 7)
        paths = list((self.root/'.cache/heavy-gate').glob('slot-*'))
        self.assertEqual(len(paths), 1)
        with mock.patch.dict(os.environ, dict(self.env,
                             HEAVY_GATE_TOKEN=(paths[0]/'token').read_text()), clear=True):
            self.assertFalse(module.holds_slot())
        dead = subprocess.Popen(['true'])
        dead.wait()
        (paths[0]/'pid').write_text(str(dead.pid))
        with mock.patch.dict(os.environ, self.env, clear=True):
            claimant = module.Slots(1)
            self.assertFalse(claimant.claim(1))
            self.assertTrue(paths[0].exists())

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
            self.assertEqual(module.gate(args), 7)
        self.assertTrue(failures)
        paths = list((self.root/'.cache/heavy-gate').glob('slot-*'))
        self.assertEqual(len(paths), 1)
        with mock.patch.dict(os.environ, dict(self.env,
                             HEAVY_GATE_TOKEN=(paths[0]/'token').read_text()), clear=True):
            self.assertFalse(module.holds_slot())

    def test_live_and_legacy_owner_tokens_remain_authorized(self):
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
            self.assertTrue(module.holds_slot())

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
            dead = subprocess.Popen(['true'])
            dead.wait()
            (paths[0]/'pid').write_text(str(dead.pid))
            self.assertFalse(module.Slots(1).claim(1))

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

    def test_cleanup_eperm_inspection_failure_preserves_status(self):
        for error in (subprocess.CalledProcessError(1, ['ps']),
                      subprocess.TimeoutExpired(['ps'], 3)):
            with self.subTest(error=type(error).__name__):
                self.assertEqual(self.cleanup_gate(PermissionError(1, 'denied'), [],
                                                  signal.SIGTERM, ps_error=error), 0)
                diagnostic = self.cleanup_stderr.getvalue()
                self.assertIn(f'pgid={self.cleanup_pgid}', diagnostic)
                self.assertIn('denied', diagnostic)
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
        jobs = [self.job(str(i), 0.3, gate_class=c) for i, c in enumerate(('short', None, 'short', None))]
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

    def test_short_job_bypasses_load_sensor_while_only_long_jobs_hold_slots(self):
        self.config(2)
        long = self.job('long', 1.5, gate_class='long')
        self.wait_for(lambda: self.started('long'))
        self.set_reading('13 90')
        for label, gate_class in (('short', 'short'), ('unmarked', None)):
            self.finish(self.job(label, 0.1, gate_class=gate_class))
            self.assertTrue(self.started(label))
        self.finish(long)

    def test_short_job_held_at_high_load_when_short_job_holds_reserve(self):
        self.config(2)
        long = self.job('long', 2.5, gate_class='long')
        self.wait_for(lambda: self.started('long'))
        self.set_reading('13 90')
        first = self.job('short1', 1.0)
        self.wait_for(lambda: self.started('short1'))
        second = self.job('short2', 0.1)
        time.sleep(0.5)
        self.assertFalse(self.started('short2'))
        self.set_reading('0 90')
        self.finish(second)
        self.finish(first)
        self.finish(long)

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
        inner = f'for i in $(seq 1 {inner_count}); do bash {gate} --head-checks -- sh -c \'echo "n$i slots=$HEAD_CHECKS_SLOTS"\' & done; wait'
        return subprocess.run(['bash', gate, '--', 'bash', '-c', inner], env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

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
result = unittest.TextTestRunner(verbosity=2).run(suite)
print(f'passed {result.testsRun-len(result.failures)-len(result.errors)}, failed {len(result.failures)+len(result.errors)}')
sys.exit(not result.wasSuccessful())
PY
