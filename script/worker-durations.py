#!/usr/bin/env python3
"""Worker wall time log and report (#1978).

The log is one JSON object per line: {"event": "start"|"end", "dispatch", "at", ...}. worker-startup.sh writes
a start line (`worker-durations.py start`), fleet-watch.py adds role and size and writes the end line.

Usage:
  worker-durations.py [report] [--log FILE]
  worker-durations.py start --dispatch ID [--title T] [--agent A]
"""
import argparse
import json
import math
import os
import sys
import time
from pathlib import Path


def log_path():
    """WORKER_DURATIONS_LOG, else beside the fleet-watch log."""
    override = (os.environ.get('WORKER_DURATIONS_LOG') or '').strip()
    if override:
        return Path(override)
    watch_log = (os.environ.get('FLEET_WATCH_LOG_PATH') or '').strip()
    folder = Path(watch_log).parent if watch_log else Path.home() / '.orca' / 'logs'
    return folder / 'worker-durations.jsonl'


def append(record, path=None):
    path = Path(path or log_path())
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a', encoding='utf-8') as handle:
        handle.write(json.dumps(record) + '\n')


def read(path=None):
    """{dispatch: merged record with 'started' and, once ended, 'ended'}. The first start and end win."""
    rows = {}
    try:
        lines = Path(path or log_path()).read_text(encoding='utf-8').splitlines()
    except FileNotFoundError:
        return rows
    for line in lines:
        try:
            record = json.loads(line)
            dispatch, event, at = record['dispatch'], record['event'], float(record['at'])
        except (ValueError, KeyError, TypeError):
            continue
        row = rows.setdefault(dispatch, {})
        stamp = {'start': 'started', 'end': 'ended'}.get(event)
        if not stamp:
            continue
        row.setdefault(stamp, at)
        for key, value in record.items():
            if key not in ('event', 'at', 'dispatch') and value:
                row[key] = value
    return rows


def _percentile(ordered, share):
    """Nearest rank."""
    return ordered[max(0, math.ceil(share * len(ordered)) - 1)]


def report(rows):
    """[(role, size, count, median minutes, p90 minutes)] over ended workers; failed starts are left out."""
    groups = {}
    for row in rows.values():
        if 'started' not in row or 'ended' not in row or row.get('outcome') == 'failed':
            continue
        key = (row.get('role') or 'unknown', row.get('size') or 'unknown')
        groups.setdefault(key, []).append(max(0.0, row['ended'] - row['started']) / 60)
    out = []
    for (role, size), minutes in sorted(groups.items()):
        minutes.sort()
        middle = len(minutes) // 2
        median = minutes[middle] if len(minutes) % 2 else (minutes[middle - 1] + minutes[middle]) / 2
        out.append((role, size, len(minutes), median, _percentile(minutes, 0.9)))
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', nargs='?', default='report', choices=('report', 'start'))
    parser.add_argument('--log', default=None)
    parser.add_argument('--dispatch')
    parser.add_argument('--title', default='')
    parser.add_argument('--agent', default='')
    args = parser.parse_args(argv)
    if args.command == 'start':
        if not args.dispatch:
            parser.error('start needs --dispatch')
        append({'event': 'start', 'dispatch': args.dispatch, 'at': time.time(),
                'title': args.title, 'agent': args.agent}, args.log)
        return 0
    rows = report(read(args.log))
    if not rows:
        print('no finished workers logged in %s' % (args.log or log_path()))
        return 0
    print('%-16s %-4s %5s %11s %8s' % ('role', 'size', 'count', 'median_min', 'p90_min'))
    for role, size, count, median, p90 in rows:
        print('%-16s %-4s %5d %11.0f %8.0f' % (role, size, count, median, p90))
    return 0


if __name__ == '__main__':
    sys.exit(main())
