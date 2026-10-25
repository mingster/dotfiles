# orca-gaps

## 2026-10-25

Orca gap: a worker's first worker_done settles its dispatch. A correction pass sent later by terminal cannot send a second worker_done ("No recipient or active Dispatch Run could be resolved"), so the coordinator never hears the result. Workaround until the runtime supports follow-up reports on a settled dispatch: after a terminal-sent correction pass, read the worker's terminal on each wake, or dispatch the correction as a new task.
