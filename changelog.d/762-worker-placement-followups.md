Worker placement stays local when --worktree-path is given, the cursor branch passes the usage gate first, and an all-unmapped refusal says no host has a repo mapping.
- A failing or timed out load sensor now makes `worker-placement.py` return a refusal, so `worker-startup.sh` prints `worker-placement: refused (load sensor ...)` and exits 4 instead of dying with a generic failure.
