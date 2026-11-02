### Fixed

- orca-team close scripts read the flat worker JSON of current Orca (state, stage, liveness, terminal, workspace), with the older nested shape as a fallback. A worker that `succeeded`, or whose stage is `released`, or whose liveness is `exited`, now counts as finished, so its pane closes itself.
- After a confirmed release, `worker-pane-close.sh` again closes the leftover coordinator pane and the worker's Setup terminal. It never closes the agent terminal (native release owns it), the caller's own terminal, or a terminal of a live dispatch.
- `worker-panes.sh`, `worker-watch.sh`, `worker-finish.sh`, `wrap-up.sh`, `merge-cleanup.sh` and `worker-watchdog.sh` read the same flat rows.
