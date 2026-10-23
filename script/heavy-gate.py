#!/usr/bin/env python3
"""Machine sensors, cooperative mkdir slots, and opt-in workload calibration.

Python is already required by head-checks. flock serializes only allocation and
reclamation, never workloads, so multi-slot claims are atomic on macOS and Linux.
HEAVY_GATE_READER is an executable: sample prints load and free-memory percent;
hardware prints total cores, performance cores, and memory bytes; model prints
the hardware model. Overrides are for synthetic tests, never real calibration.
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid


def config_path():
    return Path.home() / '.config/heavy-gate/slots.conf'


def fingerprint():
    fake = override_read('hardware')
    if fake is not None:
        total, _, memory = map(int, fake)
        model = subprocess.check_output([os.environ['HEAVY_GATE_READER'], 'model'], text=True).strip()
    elif sys.platform == 'darwin':
        model = subprocess.check_output(['sysctl', '-n', 'hw.model'], text=True).strip()
        total, memory = sysctl('hw.ncpu'), sysctl('hw.memsize')
    else:
        model_path = Path('/sys/class/dmi/id/product_name')
        model = model_path.read_text().strip() if model_path.exists() else platform.machine()
        total, _, memory = hardware()
    fields = {'hw.model': model, 'hw.ncpu': total, 'hw.memsize': memory}
    digest = hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()
    return digest, fields


def config():
    defaults = {'slots': 2, 'load_max': 12.0}
    path = config_path()
    try:
        lines = path.read_text().splitlines()
        recorded = next((line.removeprefix('# fingerprint=') for line in lines
                         if line.startswith('# fingerprint=')), None)
        if recorded != fingerprint()[0]:
            print('heavy-gate: hardware fingerprint changed or missing; ask Elon to recalibrate; '
                  'using slots=2 load_max=12', file=sys.stderr)
            return defaults
        values = {}
        for line in lines:
            key, sep, value = line.partition('=')
            if sep and key in defaults:
                values[key] = int(value) if key == 'slots' else float(value)
        if values.keys() != defaults.keys():
            raise ValueError('both slots and load_max are required')
        if values['slots'] < 1 or not math.isfinite(values['load_max']) or values['load_max'] <= 0:
            raise ValueError('slots and load_max must be positive and finite')
    except (OSError, ValueError) as exc:
        print(f'heavy-gate: warning: cannot use {path}: {exc}; '
              'using slots=2 load_max=12', file=sys.stderr)
        return defaults
    return values


def override_read(kind):
    reader = os.environ.get('HEAVY_GATE_READER')
    if reader:
        return [float(v) for v in subprocess.check_output([reader, kind], text=True).split()]
    return None


def sysctl(name):
    return int(subprocess.check_output(['sysctl', '-n', name], text=True, stderr=subprocess.DEVNULL))


def hardware():
    fake = override_read('hardware')
    if fake is not None:
        total, performance, memory = map(int, fake)
    elif sys.platform == 'darwin':
        total = sysctl('hw.ncpu')
        try:
            performance = sysctl('hw.perflevel0.physicalcpu')
        except subprocess.CalledProcessError:
            performance = sysctl('hw.physicalcpu')
        memory = sysctl('hw.memsize')
    else:
        total = performance = os.cpu_count() or 1
        memory = os.sysconf('SC_PHYS_PAGES') * os.sysconf('SC_PAGE_SIZE')
    if min(total, performance, memory) <= 0:
        raise ValueError('invalid hardware readings')
    return total, performance, memory


def sample():
    fake = override_read('sample')
    if fake is not None:
        load, free = fake
    else:
        load = os.getloadavg()[0]
        if sys.platform == 'darwin':
            stats = subprocess.check_output(['vm_stat'], text=True)
            page_size = int(re.search(r'page size of (\d+) bytes', stats)[1])
            pages = sum(int(re.search(r'^' + label + r':\s+(\d+)', stats, re.M)[1])
                        for label in ('Pages free', 'Pages inactive', 'Pages speculative'))
            free = 100 * pages * page_size / sysctl('hw.memsize')
        else:
            stats = dict(re.findall(r'^(\w+):\s+(\d+)', Path('/proc/meminfo').read_text(), re.M))
            free = 100 * int(stats['MemAvailable']) / int(stats['MemTotal'])
    if not math.isfinite(load) or load < 0 or not math.isfinite(free) or not 0 <= free <= 100:
        raise ValueError('invalid load or free-memory reading')
    return load, free


def alive(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class Slots:
    def __init__(self, count):
        self.count = count
        self.root = Path.home() / '.cache/heavy-gate'
        self.root.mkdir(parents=True, exist_ok=True)
        self.token = uuid.uuid4().hex
        self.owned = []

    @contextlib.contextmanager
    def allocation(self):
        with (self.root / '.allocator').open('a') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            yield

    def reclaim(self):
        for path in self.root.glob('slot-*'):
            if not path.is_dir():
                continue
            try:
                pid = int((path / 'pid').read_text())
            except (FileNotFoundError, ValueError):
                pid = 0
            if not alive(pid):
                shutil.rmtree(path)

    def claim(self, weight, exclusive=False):
        with self.allocation():
            self.reclaim()
            occupied = list(self.root.glob('slot-*'))
            if any((p / 'exclusive').exists() for p in occupied) or (exclusive and occupied):
                return False
            # Count even slots above a lowered configuration or a caller override.
            if len(occupied) + weight > self.count:
                return False
            available = [self.root / f'slot-{i}' for i in range(1, self.count + 1)
                         if not (self.root / f'slot-{i}').exists()]
            for path in available[:weight]:
                path.mkdir()
                self.owned.append(path)
                (path / 'pid').write_text(str(os.getpid()))
                (path / 'token').write_text(self.token)
                if exclusive:
                    (path / 'exclusive').touch()
            return True

    def release(self):
        with cleanup_signals(), self.allocation():
            for path in self.owned:
                if path.exists() and (not (path / 'token').exists() or (path / 'token').read_text() == self.token):
                    shutil.rmtree(path)
            self.owned.clear()


class Interrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum


def interrupted(signum, _frame):
    raise Interrupted(signum)


@contextlib.contextmanager
def cleanup_signals():
    handlers = {sig: signal.signal(sig, signal.SIG_IGN)
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        yield
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


@contextlib.contextmanager
def children():
    processes = []
    try:
        yield processes
    finally:
        # Keep capacity claimed until the command's process group has stopped.
        with cleanup_signals():
            for proc in processes:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            for proc in processes:
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
                # Also stop descendants that ignore TERM after their parent exits.
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()


def poll_interval():
    value = float(os.environ.get('HEAVY_GATE_POLL_SECONDS', '1'))
    if not math.isfinite(value) or value <= 0:
        raise ValueError('poll interval must be positive')
    return value


def gate(args):
    settings = config()
    count = settings['slots']
    if args.head_checks and os.environ.get('HEAD_CHECKS_SLOTS'):
        count = int(os.environ['HEAD_CHECKS_SLOTS'])
    if count < 1 or args.weight < 1 or args.weight > count:
        raise ValueError('weight must be positive and no greater than slots')
    if not args.command or args.command[0] != '--' or len(args.command) < 2:
        raise ValueError('usage: heavy-gate.sh [--weight N] -- <cmd...>')
    slots = Slots(count)
    last_notice = -math.inf
    try:
        while True:
            load, free = sample()
            reason = (f'load {load:.2f} exceeds {settings["load_max"]:g}' if load > settings['load_max']
                      else f'free memory {free:.1f}% is below 20%' if free < 20
                      else '')
            if not reason:
                if slots.claim(args.weight):
                    break
                reason = f'waiting for {args.weight} of {count} slots'
            now = time.monotonic()
            if now - last_notice >= 60:
                print(f'heavy-gate: {reason}', file=sys.stderr, flush=True)
                last_notice = now
            time.sleep(poll_interval())
        with children() as processes:
            env = dict(os.environ, HEAD_CHECKS_SLOTS=str(count)) if args.head_checks else None
            proc = subprocess.Popen(args.command[1:], start_new_session=True, env=env)
            processes.append(proc)
            status = proc.wait()
        return status if status >= 0 else 128 - status
    finally:
        slots.release()


def choose_slots(readings):
    """Round wall time is elapsed time until all N copies have finished."""
    baseline = readings[0]['wall_seconds']
    eligible = [r['copies'] for r in readings
                if r['wall_seconds'] < 1.5 * baseline and r['peak_memory_percent'] < 80]
    if not eligible:
        raise ValueError('no safe calibration round; existing configuration retained')
    return max(eligible)


def probe(args):
    total, performance, memory = hardware()
    print(f'cores_total={total}\ncores_performance={performance}\nmemory_bytes={memory}', flush=True)
    if args.calibrate is None:
        if args.force:
            raise ValueError('--force requires --calibrate')
        return 0
    if config_path().exists() and not args.force:
        raise ValueError('calibration refused: configuration exists; use --force to replace it')
    if not args.calibrate:
        local = Path.home() / '.config/heavy-gate/calibration.conf'
        if local.exists():
            args.calibrate = next((line.partition('=')[2] for line in local.read_text().splitlines()
                                   if line.startswith('command=')), '')
        if not args.calibrate:
            raise ValueError('provide --calibrate "<cmd>" or command= in ~/.config/heavy-gate/calibration.conf')
    settings = config()
    load, _ = sample()
    if load > settings['load_max']:
        raise ValueError(f'calibration refused: load {load:.2f} exceeds {settings["load_max"]:g}')
    slots = Slots(settings['slots'])
    try:
        if not slots.claim(settings['slots'], exclusive=True):
            raise ValueError('calibration refused: heavy jobs are running')
        start = time.monotonic()
        with children() as processes:
            proc = subprocess.Popen(['bash', '-c', args.calibrate], start_new_session=True)
            processes.append(proc)
            if proc.wait() != 0:
                raise ValueError('calibration command failed; existing configuration retained')
        print(f'warmup wall_seconds={time.monotonic() - start}', flush=True)
        readings = []
        for copies in (1, 2, 3):
            peak_load, free = sample()
            peak_memory = 100 - free
            start = time.monotonic()
            with children() as processes:
                for _ in range(copies):
                    processes.append(subprocess.Popen(['bash', '-c', args.calibrate], start_new_session=True))
                while True:
                    load, free = sample()
                    peak_load = max(peak_load, load)
                    peak_memory = max(peak_memory, 100 - free)
                    if all(p.poll() is not None for p in processes):
                        break
                    time.sleep(poll_interval())
                elapsed = time.monotonic() - start
                if any(p.returncode != 0 for p in processes):
                    raise ValueError('calibration command failed; existing configuration retained')
            reading = dict(copies=copies, wall_seconds=elapsed, peak_load=peak_load,
                           peak_memory_percent=peak_memory,
                           peak_memory_bytes=round(memory * peak_memory / 100))
            readings.append(reading)
            print('round ' + ' '.join(f'{k}={v}' for k, v in reading.items()), flush=True)
        selected = choose_slots(readings)
        limit = max(1, math.floor(1.2 * total + 0.5))
        digest, fields = fingerprint()
        path = config_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f'.slots-{os.getpid()}.tmp')
        try:
            with temporary.open('w') as stream:
                stream.write(f'slots={selected}\nload_max={limit}\n')
                stream.write(f'# date={datetime.datetime.now(datetime.timezone.utc).isoformat()}\n')
                stream.write(f'# fingerprint={digest}\n')
                stream.write('# hardware=' + json.dumps(fields, sort_keys=True) + '\n')
                stream.write(f'# cores_total={total} cores_performance={performance} memory_bytes={memory}\n')
                for reading in readings:
                    stream.write('# ' + ' '.join(f'{k}={v}' for k, v in reading.items()) + '\n')
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
        print(f'wrote {path}: slots={selected} load_max={limit}')
    finally:
        slots.release()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    run = commands.add_parser('gate')
    run.add_argument('--weight', type=int, default=1)
    run.add_argument('--head-checks', action='store_true', help=argparse.SUPPRESS)
    run.add_argument('command', nargs=argparse.REMAINDER)
    inspect = commands.add_parser('probe')
    inspect.add_argument('--calibrate', nargs='?', const='', metavar='CMD')
    inspect.add_argument('--force', action='store_true')
    args = parser.parse_args()
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        return gate(args) if args.mode == 'gate' else probe(args)
    except Interrupted as exc:
        return 128 + exc.signum
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'heavy-gate: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
