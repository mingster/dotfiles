guard-bash: the rollback approval is waived before `pre_go_live_host.until`, like the host and promote approvals, so `rollback-production.sh <sha>` runs without an approval until then.
