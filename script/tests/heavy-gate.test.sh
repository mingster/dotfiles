#!/usr/bin/env bash
# Exercise the command boundary with isolated home directories and sensor readings.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, os, pathlib, select, signal, subprocess, sys, tempfile, time, unittest

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

    def run_gate(self, command, weight=1):
        p = subprocess.Popen(['bash', str(scripts/'heavy-gate.sh'), '--weight', str(weight), '--', *command],
                             env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(p)
        return p

    def job(self, label='job', delay=0.15, weight=1):
        # Independent append-only workload events reveal actual overlap.
        code = '''import os,sys,time
with open(sys.argv[1], 'a', buffering=1) as f:
 f.write(f'{time.time()} start {sys.argv[2]} {os.getpid()}\\n')
 time.sleep(float(sys.argv[3]))
 f.write(f'{time.time()} end {sys.argv[2]} {os.getpid()}\\n')
'''
        return self.run_gate([sys.executable, '-c', code, str(self.root/'events'), label, str(delay)], weight)

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
        self.assertEqual(len(err.splitlines()), 1, err)
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
        self.assertEqual(err, '')
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
