`script/wrap-up.sh` now verifies post removal state after worktree removal, local branch deletion, terminal close, and browser kill, recording a failure via `fail_item` if any target remains present.
