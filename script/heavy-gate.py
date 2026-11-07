#!/usr/bin/env python3
"""Machine sensors, cooperative mkdir slots, and opt-in workload calibration.

Python is already required by head-checks. flock serializes only allocation and
reclamation, never workloads, so multi-slot claims are atomic on macOS and Linux.
HEAVY_GATE_READER is an executable: sample prints load and free-memory percent;
hardware prints total cores, performance cores, and memory bytes; model prints
the hardware model. Overrides are for synthetic tests, never real calibration.
Gated commands have a 1200-second (20-minute) wall clock limit, excluding slot
wait time. HEAVY_GATE_TIMEOUT_SECONDS overrides it; 0 or "none" disables it.
Timeouts terminate the process group, force-kill after a 3-second grace, release
slots only after proving no live group members, and exit 124.
HEAVY_GATE_CLASS=long marks a long job (full regression, build). A long job is
admitted only while the slots in use, itself included, stay at or under slots
minus 1, so one slot stays free for short scoped jobs. Its weight is capped at
slots minus 1. With a single slot there is nothing to reserve.
A short job (HEAVY_GATE_CLASS=short, or unmarked with weight 1) skips the load
sensor when only long jobs hold slots, so it can take the reserved slot while a
long job keeps the machine hot. The free-memory floor always applies, and long
jobs always wait on the load sensor.
New slots carry an unknown group ledger initialized before atomic publication.
Running authorization requires an owner-held kernel lock, closed before any
filesystem revocation or cleanup signal. Failed rename holds capacity but cannot
restore stale-token admission. Publication failure cannot restore authorization.
Live or unverifiable groups keep
the full claim occupied after exit; a completed child's status (0 or nonzero) is
preserved, while a still-running child's signalling error still raises. Nested
tokens cannot use quarantined or dead owners. Dead-owner reclaim only inspects,
never signals: complete inspection proving empty/zombie-only groups releases slots.
The command is released only after its group is published, so a gate that dies
before publication never ran it: its slot (marked prelaunch) is reclaimed once
the owner is gone. After release, a dead owner is reclaimed only when inspection
proves every recorded group empty or zombie-only; a leftover ``running`` marker
from a killed owner does not block that reclaim. Any other hold (live group,
malformed ledger, missing ``groups-ready``, or both ``running`` and ``quarantine``
from interrupted cleanup) keeps capacity, is named in the wait notice, and requires
operator
inspection. There is no manual release.
Reused PGIDs during reclaim may prolong a hold but never authorize killing there.
Signals require a positively inspected live group and an unreaped direct-child
leader, verified with waitid(WNOWAIT) before each signal when available, else ps
of that pid (ppid ours, pgid equals pid, not zombie). Reaped or unverifiable
leaders never authorize signals. Nested gates share the tracked ancestor group;
their survivors keep capacity. Legacy slots without kernel authority cannot nest,
but retain dead-PID reclaim.
Timeout and admission limits are unchanged.
A job may declare the memory it expects to use, in MiB: --memory-mb N or
HEAVY_GATE_MEMORY_MB (the flag wins). The amount is written as a memory file in
the job's first slot, so it is counted across processes and released with the
slot, including when the owner dies and the slot is reclaimed. A job is admitted
only while the declared memory of the jobs holding slots, itself included, stays
within the host total. A job that declares more than the host total cannot ever
fit, so it runs alone among jobs that declare memory: it waits until no declared
job holds memory, then starts, and says so on stderr. Jobs that declare nothing
count for nothing and never wait on memory, so an oversize job can still overlap
them. The one exception: an undeclared job whose command runs playwright (a
browser plus its dev server) declares 8192 MiB by default, whether it is called
directly, through bunx or npx, or inside bash -c. A declared value wins. The
free-memory floor and every other check are unchanged.
A job that cannot get its slots publishes a waiter record. Once a waiter of weight
W has waited HEAVY_GATE_MAX_WAIT_SECONDS (default 300), jobs lighter than W stop
taking slots until it has run, so a weight 2 job cannot be starved by a stream of
weight 1 jobs. Until then lighter jobs run as usual. Only waits for slots count,
never waits on the load or memory sensors. Waiter records of dead owners are ignored.
"""
import argparse
import calendar
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
import re
import shlex
import signal
import socket
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


def group_members(pgid):
    """A complete, successful snapshot; malformed output is not absence."""
    result = subprocess.run(['ps', '-axo', 'pgid=,pid=,ppid=,uid=,stat=,comm='],
                            check=True, capture_output=True, text=True, timeout=3)
    members = []
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=5)
        # macOS reports uid -2 for some system daemons (nobody), so uid may be signed.
        if len(fields) != 6 or not all(field.lstrip('-').isdecimal() for field in fields[:4]):
            raise ValueError('malformed process inspection')
        if int(fields[0]) == pgid:
            members.append((fields[4], line))
    return members


def verify_unreaped_leader(proc):
    if proc.returncode is not None:
        raise ChildProcessError('child already reaped; generation unknown')
    waitid = getattr(os, 'waitid', None)
    if waitid is not None:
        waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        return
    result = subprocess.run(['ps', '-p', str(proc.pid), '-o', 'pgid=,pid=,ppid=,stat='],
                            capture_output=True, text=True, timeout=3)
    result.check_returncode()
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise ValueError('malformed process inspection')
    fields = lines[0].split()
    if len(fields) != 4 or not all(field.lstrip('-').isdecimal() for field in fields[:3]):
        raise ValueError('malformed process inspection')
    pgid, pid, ppid = map(int, fields[:3])
    stat = fields[3]
    if pid != proc.pid or pgid != proc.pid or ppid != os.getpid():
        raise ChildProcessError('leader generation unknown')
    if stat.startswith('Z'):
        raise ChildProcessError('leader already reaped; generation unknown')


def recorded_groups_empty(path, members=None):
    """True when groups-ready is published and every recorded group is empty or zombie-only."""
    inspect = group_members if members is None else members
    if not (path / 'groups-ready').is_file():
        return False
    groups = json.loads((path / 'groups').read_text())
    if not isinstance(groups, list) or any(type(pgid) is not int or pgid <= 0 for pgid in groups):
        return False
    return all(not any(not state.startswith('Z') for state, _ in inspect(pgid)) for pgid in groups)


def dead_owner_reclaimable(path, members=None):
    """Inspect-only reclaim when the owner is gone."""
    try:
        if (path / 'quarantine').exists() and (path / 'running').exists():
            return False
        return recorded_groups_empty(path, members)
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def groups_empty(path, members=None):
    try:
        # Normal release still requires cleanup to have dropped the running marker.
        if (path / 'running').exists():
            return False
        return recorded_groups_empty(path, members)
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def stuck_slot_names(root, members=None):
    """Slot directory names held with a dead owner and no reclaim proof."""
    names = []
    for path in Path(root).glob('slot-*'):
        if not path.is_dir():
            continue
        try:
            pid = int((path / 'pid').read_text())
        except (FileNotFoundError, ValueError):
            pid = 0
        if alive(pid) or (path / 'prelaunch').exists() or not (path / 'groups').exists():
            continue
        if dead_owner_reclaimable(path, members=members):
            continue
        names.append(path.name)
    return names


class Slots:
    def __init__(self, count):
        self.count = count
        self.root = Path.home() / '.cache/heavy-gate'
        self.root.mkdir(parents=True, exist_ok=True)
        self.token = uuid.uuid4().hex
        self.owned = []
        self.groups = set()
        self.authorizations = []
        self.stuck = []
        self.waiting = self.root / 'waiting'
        self.bound = max_wait()

    def wait_record(self, weight):
        """Publish (once) that this job is blocked on slots; keeps its first time."""
        record = self.waiting / self.token
        if not record.exists():
            self.waiting.mkdir(exist_ok=True)
            temporary = self.waiting / f'.{self.token}.tmp'
            temporary.write_text(json.dumps({'pid': os.getpid(), 'weight': weight,
                                             'since': time.time()}))
            temporary.replace(record)

    def stop_waiting(self):
        (self.waiting / self.token).unlink(missing_ok=True)

    def starved_heavier(self, weight):
        """True when a live, bounded-out waiter needs more slots than this job."""
        for record in self.waiting.glob('*'):
            if record.name.startswith('.') or record.name == self.token:
                continue
            try:
                info = json.loads(record.read_text())
                if not alive(info['pid']):
                    record.unlink(missing_ok=True)
                elif info['weight'] > weight and time.time() - info['since'] >= self.bound:
                    return True
            except (OSError, ValueError, KeyError, TypeError):
                continue
        return False

    @contextlib.contextmanager
    def allocation(self):
        with (self.root / '.allocator').open('a') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            yield

    def reclaim(self):
        self.stuck = []
        for path in self.root.glob('slot-*'):
            if not path.is_dir():
                continue
            try:
                pid = int((path / 'pid').read_text())
            except (FileNotFoundError, ValueError):
                pid = 0
            if not alive(pid):
                # prelaunch: the workload is released only after its group is
                # published, so a dead owner here never ran anything.
                if (not (path / 'prelaunch').exists() and (path / 'groups').exists()
                        and not dead_owner_reclaimable(path)):
                    self.stuck.append(path.name)
                    continue
                shutil.rmtree(path)

    def declared(self, paths):
        """MiB declared by the given slots; a slot without a record declares nothing."""
        total = 0
        for path in paths:
            with contextlib.suppress(OSError, ValueError):
                total += int((path / 'memory').read_text())
        return total

    def claim(self, weight, exclusive=False, reserve=0, long_job=False, only_long=False,
              memory=0, host_memory=0):
        with self.allocation():
            self.reclaim()
            if self.starved_heavier(weight):
                return False
            occupied = list(self.root.glob('slot-*'))
            if any((p / 'exclusive').exists() for p in occupied) or (exclusive and occupied):
                return False
            if only_long and (not occupied or not all((p / 'long').exists() for p in occupied)):
                return False
            # Count even slots above a lowered configuration or a caller override.
            if len(occupied) + weight > self.count - reserve:
                return False
            # Declared memory counts like a slot; an oversize job can only run alone.
            if memory:
                held = self.declared(occupied)
                if held and held + memory > host_memory:
                    return False
            available = [self.root / f'slot-{i}' for i in range(1, self.count + 1)
                         if not (self.root / f'slot-{i}').exists()]
            for index, path in enumerate(available[:weight]):
                # Initialize the durable unknown barrier while still invisible to
                # reclaim. A failed initialization can never look like a legacy slot.
                staging = self.root / f'.claim-{self.token}-{path.name}'
                staging.mkdir()
                try:
                    (staging / 'groups').touch()
                    (staging / 'running').touch()
                    (staging / 'prelaunch').touch()
                    authorization = (staging / 'authorization').open('a')
                    fcntl.flock(authorization, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.authorizations.append(authorization)
                    (staging / 'pid').write_text(str(os.getpid()))
                    (staging / 'token').write_text(self.token)
                    if exclusive:
                        (staging / 'exclusive').touch()
                    if long_job:
                        (staging / 'long').touch()
                    if memory and index == 0:
                        (staging / 'memory').write_text(str(memory))
                    staging.rename(path)
                    self.owned.append(path)
                finally:
                    if staging.exists():
                        shutil.rmtree(staging)
            return True

    def record_groups(self, processes, absent=()):
        """Publish cleanup ownership; failure leaves the pre-existing unknown hold."""
        with self.allocation():
            # Retain earlier contexts even if their disk publication failed.
            self.groups.update(proc.pid for proc in processes)
            self.groups.difference_update(absent)
            for path in self.owned:
                if (path / 'groups-ready').exists():
                    self.groups.update(json.loads((path / 'groups').read_text()))
                self.groups.difference_update(absent)
                (path / 'groups-ready').unlink(missing_ok=True)
                (path / 'groups').write_text(json.dumps(sorted(self.groups)))
                (path / 'groups-ready').touch()

    def launched(self):
        with self.allocation():
            for path in self.owned:
                (path / 'prelaunch').unlink(missing_ok=True)

    def revoke(self):
        # Kernel-held authority disappears even if all subsequent filesystem
        # operations fail. Admission never treats a disk marker alone as authority.
        for stream in self.authorizations:
            stream.close()
        self.authorizations.clear()

    def release(self):
        self.revoke()
        with cleanup_signals(), self.allocation():
            for path in self.owned:
                if path.exists() and (not (path / 'token').exists() or (path / 'token').read_text() == self.token):
                    if groups_empty(path):
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
def children(slots, nested=False):
    processes = []
    if nested:
        # Nested jobs share the ancestor's registered process group. They cannot
        # create an independent session or signal their siblings during cleanup.
        yield processes
        return
    for path in slots.owned:
        (path / 'running').touch()
        (path / 'quarantine').unlink(missing_ok=True)

    def stop_group(proc, sig):
        members = []
        try:
            members = group_members(proc.pid)
            if not any(not state.startswith('Z') for state, _ in members):
                return
            # An unreaped direct child reserves its PID, even if it exits between
            # this check and killpg. Never reap it until the final signal is sent.
            # A saved/reaped PID or an inspection error provides no such authority.
            verify_unreaped_leader(proc)
        except (OSError, ValueError, AttributeError, subprocess.SubprocessError) as exc:
            print(f'heavy-gate: signal withheld pgid={proc.pid}; inspection failed or generation unknown; capacity held: {exc}',
                  file=sys.stderr, flush=True)
            for _, line in members:
                print(line, file=sys.stderr, flush=True)
            return
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            publish(absent=(proc.pid,))

    def publish(absent=()):
        if not slots.owned:
            return
        try:
            slots.record_groups(processes, absent)
        except (OSError, ValueError) as exc:
            print(f'heavy-gate: group publication failed; capacity held: {exc}',
                  file=sys.stderr, flush=True)

    try:
        yield processes
    finally:
        # Keep capacity claimed through all process-group cleanup attempts.
        with cleanup_signals():
            # Revoke kernel authority first. Failed filesystem quarantine then
            # surfaces without signalling, while running still prevents reclaim.
            slots.revoke()
            for path in slots.owned:
                (path / 'running').rename(path / 'quarantine')
            publish()
            for proc in processes:
                stop_group(proc, signal.SIGTERM)
            for proc in processes:
                # Leave the leader unreaped throughout the grace period. This is
                # what pins the process-group generation through the final signal.
                if proc.returncode is None:
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        try:
                            if not any(not state.startswith('Z') for state, _ in group_members(proc.pid)):
                                break
                        except (OSError, ValueError, subprocess.SubprocessError):
                            break
                        time.sleep(0.05)
                stop_group(proc, signal.SIGKILL)
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    print(f'heavy-gate: child pgid={proc.pid} remains live; capacity held',
                          file=sys.stderr, flush=True)


# Holds the workload until the gate has published its process group. If the gate
# dies first the pipe closes and this exits without running anything.
LAUNCHER = '''import os, sys
fd = int(sys.argv[1])
go = os.read(fd, 1)
os.close(fd)
if go != b"1":
    os._exit(125)
try:
    os.execvp(sys.argv[2], sys.argv[2:])
except OSError as exc:
    sys.stderr.write("heavy-gate: cannot run %s: %s\\n" % (sys.argv[2], exc))
    os._exit(127)
'''


def spawn(slots, processes, argv, **kwargs):
    """Start argv in its own group, released only after the group is recorded."""
    read, write = os.pipe()
    try:
        proc = subprocess.Popen([sys.executable, '-I', '-S', '-c', LAUNCHER, str(read), *argv],
                                start_new_session=True, pass_fds=(read,), **kwargs)
    except BaseException:
        os.close(write)
        raise
    finally:
        os.close(read)
    processes.append(proc)
    try:
        slots.record_groups(processes)
        slots.launched()
        try:
            os.write(write, b'1')
        except BrokenPipeError:
            pass  # launcher already gone: the command never ran; wait() reports it
    except BaseException:
        # Unpublished, so the command must not run: closing the pipe stops the
        # launcher, which is reaped here and never needs a cleanup signal.
        os.close(write)
        processes.remove(proc)
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=3)
        raise
    os.close(write)
    return proc


def poll_interval():
    value = float(os.environ.get('HEAVY_GATE_POLL_SECONDS', '1'))
    if not math.isfinite(value) or value <= 0:
        raise ValueError('poll interval must be positive')
    return value


def command_timeout():
    value = os.environ.get('HEAVY_GATE_TIMEOUT_SECONDS', '1200')
    if value == 'none':
        return None
    seconds = float(value)
    if not math.isfinite(seconds) or seconds < 0:
        raise ValueError('HEAVY_GATE_TIMEOUT_SECONDS must be nonnegative and finite, or "none"')
    return seconds or None


def holds_slot():
    """Require live owner, running markers and a currently held kernel lock."""
    token = os.environ.get('HEAVY_GATE_TOKEN')
    if not token:
        return False
    root = Path.home() / '.cache/heavy-gate'
    for path in root.glob('slot-*'):
        try:
            if ((path / 'token').read_text() == token
                    and (not (path / 'groups').exists()
                         or ((path / 'running').is_file()
                             and not (path / 'quarantine').exists()))
                    and alive(int((path / 'pid').read_text()))):
                with (path / 'authorization').open('r') as stream:
                    try:
                        fcntl.flock(stream, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    except BlockingIOError:
                        return True
        except (OSError, ValueError):
            continue
    return False


def max_wait():
    try:
        value = float(os.environ.get('HEAVY_GATE_MAX_WAIT_SECONDS', '300'))
    except ValueError:
        value = -1
    if not math.isfinite(value) or value < 0:
        raise ValueError('HEAVY_GATE_MAX_WAIT_SECONDS must be nonnegative and finite')
    return value


def heavy_gate_wait_log_path():
    override = (os.environ.get('HEAVY_GATE_WAIT_LOG') or '').strip()
    if override:
        return Path(override)
    return Path.home() / '.orca' / 'logs' / 'heavy-gate-wait.log'


HEAVY_GATE_WAIT_LOG_DEFAULT_MAX_LINES = 2000
HEAVY_GATE_WAIT_LOG_DEFAULT_MAX_AGE_SECONDS = 7 * 24 * 3600


def wait_log_max_lines():
    value = (os.environ.get('HEAVY_GATE_WAIT_LOG_MAX_LINES') or '').strip()
    if value:
        try:
            lines = int(value)
            if lines > 0:
                return lines
        except ValueError:
            pass
    return HEAVY_GATE_WAIT_LOG_DEFAULT_MAX_LINES


def wait_log_max_age_seconds():
    value = (os.environ.get('HEAVY_GATE_WAIT_LOG_MAX_AGE_SECONDS') or '').strip()
    if value:
        try:
            seconds = float(value)
            if math.isfinite(seconds) and seconds > 0:
                return seconds
        except ValueError:
            pass
    return HEAVY_GATE_WAIT_LOG_DEFAULT_MAX_AGE_SECONDS


def wait_log_line_age_seconds(token, now):
    """Seconds since a log timestamp token, or None when unparsable."""
    for fmt in ('%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%dT%H:%M:%SZ'):
        try:
            stamp = datetime.datetime.strptime(token, fmt)
        except ValueError:
            continue
        if stamp.tzinfo is not None:
            return now - stamp.timestamp()
        return now - calendar.timegm(stamp.timetuple())
    return None


@contextlib.contextmanager
def heavy_gate_wait_log_lock(path):
    """Serialize append and trim on the wait log across processes."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(f'.{path.name}.lock')
    with lock_path.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def read_heavy_gate_wait_log_lines(path):
    try:
        text = path.read_bytes().decode('utf-8', errors='replace')
    except OSError:
        return None
    return [line for line in text.splitlines() if line.strip()]


def trim_heavy_gate_wait_log(path):
    """Drop aged lines and keep a tail so the wait log cannot grow without limit."""
    max_lines = wait_log_max_lines()
    max_age = wait_log_max_age_seconds()
    lines = read_heavy_gate_wait_log_lines(path)
    if not lines:
        return
    now = time.time()
    kept = []
    for line in lines:
        token = line.split(None, 1)[0]
        age = wait_log_line_age_seconds(token, now)
        if age is None or age <= max_age:
            kept.append(line)
    if len(kept) > max_lines:
        kept = kept[-max_lines:]
    if kept == lines:
        return
    temporary = path.with_name(f'.{path.name}.trim-{os.getpid()}.tmp')
    try:
        temporary.write_text('\n'.join(kept) + ('\n' if kept else ''), encoding='utf-8')
        temporary.replace(path)
    except OSError:
        with contextlib.suppress(OSError):
            temporary.unlink(missing_ok=True)


def heavy_gate_host():
    override = (os.environ.get('HEAVY_GATE_HOST') or '').strip()
    if override:
        return override
    try:
        return socket.gethostname()
    except OSError:
        return 'unknown'


def log_heavy_gate_wait(seconds):
    if not math.isfinite(seconds) or seconds < 0:
        return
    path = heavy_gate_wait_log_path()
    try:
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        line = f'{stamp} host={heavy_gate_host()} wait_s={seconds:.3f}\n'
        with heavy_gate_wait_log_lock(path):
            with path.open('a', encoding='utf-8') as stream:
                stream.write(line)
            trim_heavy_gate_wait_log(path)
    except (OSError, ValueError, UnicodeError):
        pass


def job_class():
    value = os.environ.get('HEAVY_GATE_CLASS', '')
    if value not in ('', 'short', 'long'):
        raise ValueError('HEAVY_GATE_CLASS must be "long" or "short"')
    return value


PLAYWRIGHT_DEFAULT_MIB = 8192


def declared_memory(args):
    """MiB the job declares. The flag wins over the environment. A job that
    declares nothing and runs playwright gets a default; any other gets 0."""
    flag = getattr(args, 'memory_mb', None)
    value = flag if flag is not None else os.environ.get('HEAVY_GATE_MEMORY_MB', '')
    if value == '':
        command = ' '.join(getattr(args, 'command', None) or [])
        return PLAYWRIGHT_DEFAULT_MIB if re.search(r'playwright', command) else 0
    try:
        memory = int(value)
    except ValueError:
        memory = 0
    if memory < 1:
        raise ValueError('declared memory must be a positive whole number of MiB (--memory-mb or HEAVY_GATE_MEMORY_MB)')
    return memory


def gate(args):
    timeout = command_timeout()
    memory = declared_memory(args)
    host_memory = hardware()[2] // (1024 * 1024) if memory else 0
    if memory > host_memory > 0:
        print(f'heavy-gate: declared memory {memory} MiB exceeds host memory {host_memory} MiB; '
              'it will run alone among jobs that declare memory', file=sys.stderr, flush=True)
    settings = config()
    count = settings['slots']
    if args.head_checks and os.environ.get('HEAD_CHECKS_SLOTS'):
        count = int(os.environ['HEAD_CHECKS_SLOTS'])
    if count < 1 or args.weight < 1 or args.weight > count:
        raise ValueError('weight must be positive and no greater than slots')
    if not args.command or args.command[0] != '--' or len(args.command) < 2:
        raise ValueError('usage: heavy-gate.sh [--weight N] -- <cmd...>')
    long_job = job_class() == 'long' and count > 1
    weight = min(args.weight, count - 1) if long_job else args.weight
    short_job = job_class() != 'long' and weight == 1
    slots = Slots(count)
    last_notice = -math.inf
    nested = holds_slot()
    wait_begin = None
    try:
        while not nested:
            load, free = sample()
            hot = load > settings['load_max']
            reason = (f'free memory {free:.1f}% is below 20%' if free < 20
                      else f'load {load:.2f} exceeds {settings["load_max"]:g}' if hot
                      else '')
            if hot and free >= 20 and short_job and slots.claim(weight, only_long=True):
                break
            if not reason:
                if slots.claim(weight, reserve=int(long_job), long_job=long_job,
                               memory=memory, host_memory=host_memory):
                    break
                slots.wait_record(weight)
                reason = (f'waiting for {weight} of {count - 1} slots (one is kept for short jobs)'
                          if long_job else f'waiting for {weight} of {count} slots')
                if memory:
                    reason += f' and {memory} MiB of {host_memory} MiB declared memory'
                if slots.stuck:
                    reason += ('; held with the owner gone and no proof its processes exited: '
                               + ', '.join(slots.stuck))
            if reason.startswith(('free memory', 'load ')):
                slots.stop_waiting()
            now = time.monotonic()
            if now - last_notice >= 60:
                print(f'heavy-gate: {reason}', file=sys.stderr, flush=True)
                last_notice = now
            if wait_begin is None:
                wait_begin = now
            time.sleep(poll_interval())
        if wait_begin is not None:
            log_heavy_gate_wait(time.monotonic() - wait_begin)
        with children(slots, nested=nested) as processes:
            env = dict(os.environ)
            if not nested:
                env['HEAVY_GATE_TOKEN'] = slots.token
            if args.head_checks:
                env['HEAD_CHECKS_SLOTS'] = str(count)
            if nested:
                proc = subprocess.Popen(args.command[1:], env=env)
                processes.append(proc)
            else:
                proc = spawn(slots, processes, args.command[1:], env=env)
            try:
                status = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                command = shlex.join(args.command[1:]).replace('\n', r'\n').replace('\r', r'\r')
                print(f'heavy-gate: timed out after {timeout:g}s: {command}',
                      file=sys.stderr, flush=True)
                return 124
            print(f'heavy-gate: child exited with status {status}', file=sys.stderr, flush=True)
        return status if status >= 0 else 128 - status
    finally:
        slots.stop_waiting()
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
        with children(slots) as processes:
            proc = spawn(slots, processes, ['bash', '-c', args.calibrate])
            if proc.wait() != 0:
                raise ValueError('calibration command failed; existing configuration retained')
        print(f'warmup wall_seconds={time.monotonic() - start}', flush=True)
        readings = []
        for copies in (1, 2, 3):
            peak_load, free = sample()
            peak_memory = 100 - free
            start = time.monotonic()
            with children(slots) as processes:
                for _ in range(copies):
                    spawn(slots, processes, ['bash', '-c', args.calibrate])
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
    run = commands.add_parser('gate', description=(
        'Run a command with a 1200-second (20-minute) wall clock limit after slot '
        'admission. HEAVY_GATE_TIMEOUT_SECONDS overrides the limit; 0 or "none" '
        'disables it. Timeout stops the process group (TERM, then KILL after a '
        '3-second grace), releases slots, and exits 124.'))
    run.add_argument('--weight', type=int, default=1)
    run.add_argument('--memory-mb', metavar='MIB', help='memory the job expects to use, counted while it runs')
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
