# Credential folder: root owned, one gate

Read this before changing `script/secrets-gate.sh`, `script/secrets-gate-setup.sh`, `script/secrets-sync.sh`, `script/secrets-refs.sh`, or anything that reads the credential folder. Decision: issue 922 (owner answers Q1 A, Q2 A, Q3 B).

## What changed

Workers and the owner share one OS account, so the credential folder was protected only by the Bash guard's text checks. Now the folder is `root:wheel` mode 700 and the only way in is one root owned program, the gate, installed at `/opt/secrets-gate/secrets-gate` with its root owned config `/opt/secrets-gate/secrets-gate.conf`.

The gate has a fixed command list and refuses everything else (exit 2):

| Command | What it does | How it is approved |
|---|---|---|
| `fingerprint <file>` | Prints the file's size and an 8 hex fingerprint. Never the content. | Touch ID or password |
| `sync [--dry-run] [--delete]` | Pushes the folder to the fleet hosts (rsync over ssh as the owner account). Prints file names only. | Plain `sync` is passwordless (one sudoers entry). Flags need Touch ID. |
| `receive --server ...` | The rsync server side on a fleet host. Writes only into the configured folder, accepts only plain rsync flags. | Passwordless on a host set up with `--role receiver` |
| `deploy-read <name>` | Prints one file named on the config's deploy list. | Touch ID or password |

Paths for `fingerprint` and `deploy-read` must be regular files inside the folder (no `..`, no symlinks, nothing outside).

Scripts moved onto the gate: `script/secrets-sync.sh` (calls `sudo -n gate sync`) and `env-peek.py` (when it cannot open a file, it asks `sudo gate fingerprint <file>`). Through the gate the fingerprint covers the whole file, so there are no per key lines.

`script/secrets-pack.sh` and `script/secrets-unpack.sh` are not moved. Pack reads the folder, so after setup the owner runs it with `sudo`.

Limits to know: the account is still shared. A worker can run the passwordless `sync` (it prints file names only). A worker can also run the passwordless `receive` on a receiver host, which can only write into the folder, never read it. Everything else asks the owner.

## Owner steps (once per host)

The owner runs these. Agents never run setup or sudo. Always start with the dry run, it prints each step and runs no sudo.

Source host (the one holding the master copy and running the daily sync):

1. `cd ~/dotfiles && git pull`
2. `bash script/secrets-gate-setup.sh --dry-run` and read the plan.
3. `bash script/secrets-gate-setup.sh` (asks for the password the first time, then Touch ID works for sudo on macOS).
4. Check: `sudo /opt/secrets-gate/secrets-gate fingerprint <a file name in the folder>` prints one line, and `ls <folder>` now says permission denied.
5. Check the sync: `bash script/secrets-sync.sh --dry-run` (Touch ID), then `bash script/secrets-sync.sh` (no prompt).

Every other fleet host (receives the folder):

1. `cd ~/dotfiles && git pull`
2. `bash script/secrets-gate-setup.sh --dry-run --role receiver --dir <the folder path on this host>`
3. The same command without `--dry-run`.
4. From the source host: `bash script/secrets-sync.sh --dry-run`, then `bash script/secrets-sync.sh`.

A fleet host without the gate still receives the push the old way (the source host prepares its owner owned folder), so the order of hosts does not matter. Do the source host first.

Optional on the source host: `--deploy "name1 name2"` sets the file names `deploy-read` may print.

Undo on a host: `sudo chown -R "$USER" <folder> && sudo chmod -R u+rwX,go-rwx <folder>`, then remove `/opt/secrets-gate` and `/etc/sudoers.d/secrets-gate`.

## Searching for who uses the folder

`script/secrets-refs.sh <dir> <pattern>` lists `file:line` for every match under `<dir>` and never prints the matched text. It skips any directory named `secrets`. The Bash guard lets this one script take the folder name as its pattern. Everything else that names the folder stays denied. Use it to survey the riben.life deploy and host scripts.

## Tests

`script/tests/secrets-gate.test.sh`, `secrets-gate-setup.test.sh`, `secrets-sync.test.sh`, and the guard cases in `templates/agent-team/.claude/hooks/tests/test_guard_bash.py`. They use fake folders in a temp dir and a fake `sudo`.
