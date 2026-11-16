Make the guard hook tests run on Python 3.9, the system python on some fleet hosts, so `script/checks-local.sh` no longer fails there.
Make the `agent-team.test.sh` dry-run check read its output without a pipe, so a fast `grep -q` no longer fails it with a broken pipe.
