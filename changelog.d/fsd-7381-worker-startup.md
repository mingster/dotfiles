Add `script/worker-startup.sh` for daily host checks (fast-forward main, node and bun pins, conditional bun install) and `--run` to start workers via Orca, with `script/tests/worker-startup.test.sh`.

Harden pin handling: compare node before requiring asdf; one state file per lock path and `bun install` only where the hash changed; bun install fetches with an explicit `curl` (override `CURL`) so failures are visible without `pipefail`; usage gate honors optional `PYTHON3`.
