* `script/fleet-watch.py` still starts a verifier for a PR on an owner-only path. It reports the path once per head, and only the ship waits for the owner.
* `script/worker-startup.sh` refuses a builder brief for a backlog line (`#<issue> L<n>`) that a merged PR title already carries.
* The coordinator skill reads the task and worker lists before it answers a status or recap question.
