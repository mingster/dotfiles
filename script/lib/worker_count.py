"""One worker count rule for the status line (fleet-workers.py) and the fleet-watch `work order:` line (#1942).

A dispatch in progress is `live` when Orca's liveness verdict is live (or absent), and `unconfirmed`
when the verdict is anything else but a finished one (for example `unverifiable`). An unconfirmed
worker may be idle on a question the coordinator never received, so it is shown, never dropped.
"""

FINISHED_VERDICTS = ('exited', 'settled')


def bucket(in_progress, verdict):
    """'live', 'unconfirmed' or None (not a dispatch in progress)."""
    if not in_progress or verdict in FINISHED_VERDICTS:
        return None
    return 'live' if verdict in (None, 'live') else 'unconfirmed'


def tally(buckets):
    """(live, unconfirmed) from an iterable of bucket() results."""
    found = list(buckets)
    return found.count('live'), found.count('unconfirmed')


def label(live, unconfirmed):
    """'3' when all are live, '3+2?' with two unconfirmed."""
    return '%d+%d?' % (live, unconfirmed) if unconfirmed else str(live)
