# Fleet watch sender identity

Recorded on 2026-11-13 from a shell with no terminal, Orca 1.4.258. This is the #990 outcome for the Identity section of the fleet watch design.

Orca accepts a send whose `--from` is a live terminal titled `fleet-watch` and whose `--to` is `run:<id>`. The reply is exit 0 and `{"ok": true, "result": {"messageId": "<id>"}}`. That terminal is the sender identity. Fleet watch speaks as itself.

A send with no `--from` is refused. A send to `run:<id>` with no `--from` returns exit 1 and `no_active_sender_terminal`.

A send with `--from` set to the coordinator terminal also returns exit 0. That is the #989 stopgap. It speaks as the receiver. The owned terminal is the identity to keep.

Recordings are in `script/tests/fixtures/fleet-watch/orca-1.4.258/`. `python3 script/fleet-watch-record.py --dry` compares a fresh reply's keys, error codes and exit code with those files. `wrap-up.sh --fleet` runs that check.
