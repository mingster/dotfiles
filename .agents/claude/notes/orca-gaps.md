# orca-gaps

## 2026-10-25

Orca gap: a worker's first worker_done settles its dispatch. A correction pass sent later by terminal cannot send a second worker_done ("No recipient or active Dispatch Run could be resolved"), so the coordinator never hears the result. Workaround until the runtime supports follow-up reports on a settled dispatch: after a terminal-sent correction pass, read the worker's terminal on each wake, or dispatch the correction as a new task.

## 2026-11-17

Orca gap (#1159): a remote worker's `worker_done` is accepted on the worker's own Orca server (exit 0, `lifecycle=completed`), and the message is relayed to the coordinator's server as `worker_mail`. The coordinator's server rejects the relayed copy with `worker_done references unknown dispatch ctx_...` because its reconciliation looks the dispatch up in `dispatch_contexts`, while a remote dispatch is stored in `remote_dispatches`. The rejection is on the coordinator side, so the worker's own CLI never prints it. Workaround: the coordinator releases the worker with `worker-release` and reads the result from the PR. Upstream report: stablyai/orca#43618.
