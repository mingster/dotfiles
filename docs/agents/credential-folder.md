# Credential folder: root owned, one gate, receivers never trust the worker account

Read this before changing `script/secrets-gate.sh`, `script/secrets-gate-setup.sh`, `script/secrets-sync.sh`, `script/secrets-refs.sh`, `script/set-env-key.py`, or anything that reads the credential folder. Decision: issue 922 (owner answers Q1 A, Q2 A, Q3 B). This is the second design, after two FAIL Verdicts on PR 936. The fixed helper runner (`run`) is issue 1888 (owner answer Q1 A).

## The rule

On every host, no process running as the worker account can read the folder or write as root. The daily sync still runs unattended from the source host.

Workers and the owner share one OS account, so anything that logs in as that account, or runs through a passwordless sudo entry, is reachable by a worker. A passwordless entry is safe only when what it runs is fixed by root: `sync` takes no input, and `run` starts only helpers root installed. The first design let each receiver accept the push as that account and then raise to root with a passwordless entry. Both reviews broke it. The fix is not a better receive script. The fix is that a receiver never involves the shared account at all.

## Design

| Piece | Where | Who can change it |
|---|---|---|
| The folder | A path only root controls, default `/opt/secrets-gate/folder`. Owner root, mode 700. | root |
| The gate | `/opt/secrets-gate/secrets-gate` with `secrets-gate.conf` (folder, hosts, deploy list) beside it | root |
| Source host: sync | `sudo -n /opt/secrets-gate/secrets-gate sync`, passwordless (exact command, no wildcard) | root |
| Every host: helpers | `/opt/secrets-gate/helpers/<name>`, root mode 755, run by `sudo -n /opt/secrets-gate/secrets-gate run <name> [args]` (passwordless, `run *`) | root |
| Source host: ssh | Root's own key `/opt/secrets-gate/id_ed25519` and root owned `known_hosts`. ssh runs with `-F /dev/null`, strict host keys, `root@<host>` | root |
| Receiver host: login | `root@<host>` with the gate key. Root's `authorized_keys` holds one line: `restrict,command="/opt/secrets-gate/secrets-gate receive" <gate key>` | root |
| Receiver host: sshd | Drop in with `PermitRootLogin forced-commands-only` | root |

A receiver's only sudoers entry is `run *`, and `receive` never runs as the worker account. A worker on a receiver cannot start `receive`: only the holder of the gate key can, and that key is mode 600 root on the source. A worker on the source can start `sync`, which takes no input except `--dry-run` (not passwordless) and pushes only to the hosts in the root owned config. A worker on any host can start a helper, but only one root installed in the helpers folder.

The gate commands (anything else is refused with exit 2):

| Command | What it does | Approval |
|---|---|---|
| `fingerprint <file>` | Size and 8 hex fingerprint of one regular file in the folder. Never the content. | Touch ID or password |
| `sync` | Mirrors the folder to `root@<host>` for each fleet host, removals included. Prints file names only. | Passwordless (the one entry) |
| `sync --dry-run` | Lists the files and hosts. Contacts no host (the receiver ignores client options, so a real rsync dry run cannot be asked of it). | Touch ID or password |
| `receive` | The rsync server side. Only as the forced command. Takes no argument. Ignores the client's command line. | Forced command only |
| `deploy-read <name>` | Prints one file named on the config's deploy list. | Touch ID or password |
| `check-path <path>` | Exit 0 when the path is root controlled. Setup uses it. | none, prints no content |
| `run <helper> [args...]` | Runs `/opt/secrets-gate/helpers/<helper>` with the args, in an empty environment holding `PATH`, `SECRETS_GATE_FOLDER` (the folder) and, from sudo, `SECRETS_GATE_CALLER_UID`, `SECRETS_GATE_CALLER_USER` and `SECRETS_GATE_CALLER_HOME`. The helper prints what it chooses. | Passwordless (`run *`, every host) |

`run` refuses with exit 2 a name that is not plain (`[A-Za-z0-9._-]`, no leading dot or dash, so no `..` or `/`), a helper that is missing, a link, not a regular executable file, not owned by root, or writable by group or others, and a helpers folder that is a link or sits in a path that is not root controlled. The folder check runs first, as for every command.

## Why the gate stays safe

- Every use checks the folder first: the path and every parent is a real directory (no link) owned by root and not writable by group or others, the folder is root mode 700, and no symbolic link sits anywhere inside it. A parent the owner account can write would let a worker rename the folder and plant a link, so such a path is refused. This is why the folder does not stay under a home folder.
- `receive` starts `rsync --server -rt` itself with a fixed list (no `-l`, `-K`, `-L`, `-o`, `-g`, `-D`, `--delete`) into a fresh staging folder inside the root 700 folder, then moves regular files only into place with `mv -f --`. Directories are made one component at a time and the parent is checked again just before each move. Links and special files are dropped.
- The receiver folder mirrors the push (issue 1926, owner decision). Before moving files in, `receive` removes everything that is not a regular file also in the staging folder (a link is removed, its target untouched), then empty directories. Other `.stage.*` folders are left alone. When rsync fails or no file is staged, nothing is deleted and `receive` exits non zero.
- The gate starts as `#!/bin/bash`, calls `/usr/bin/id`, and under root re-executes itself with an empty environment and `PATH=/usr/bin:/bin:/usr/sbin:/sbin` before anything else. `SECRETS_GATE_CONF`, `SG_RSYNC` and `SG_TRUST_UID` are ignored under root. The sudoers drop in sets `env_reset` and `secure_path` too. Globbing is off, and every `mv`, `mkdir`, `rm`, `cat` and `chmod` puts `--` before names.
- The sync's ssh reads nothing the worker account can edit: `-F /dev/null`, one root owned key, one root owned `known_hosts`, `StrictHostKeyChecking=yes`, `ProxyCommand=none`, and host names checked against a plain pattern (no leading dash, no `user@`).

## Limits to know

- A worker can run the passwordless `sync`. It prints file names, never contents, and sends only to the configured hosts with the pinned host keys.
- A worker can run any installed helper as root with arguments, stdin and a working directory it chooses. Each helper must be safe on its own: check its arguments, print only safe output (a fingerprint, a yes or no, a result), and never print a credential or write where the caller points. Review a helper like a sudoers entry before installing it.
- Setup adds and updates helpers but never removes one. A helper dropped from `--helpers <dir>` stays runnable until the owner removes it with `sudo rm /opt/secrets-gate/helpers/<name>`.
- The sync mirrors. A file that exists only in a receiver's folder is removed on the next sync, so keep host only files somewhere else. A file removed or lost on the source is removed everywhere too.
- The wipe guard sees only what the receiver's rsync reports. With the macOS built in rsync, a source file that is listed but cannot be opened (a disk error, or a file renamed during the push) does not make the receiver's rsync fail, so the receiver drops its copy of that one file. The next good sync puts it back.
- A receiver runs its installed copy of the gate. It mirrors only after the owner reruns setup there with the new script.
- An empty source folder removes nothing: the receiver refuses a push with no file. Remove the last file on a receiver by hand with `sudo rm`.
- Every sync resends all files (the receiver stages into an empty folder). The folder is small.
- Setup cannot undo a copy a worker already made before it ran. If a worker could read the folder before setup, rotate the credentials.
- Deploy scripts that read the folder by path no longer work (root 700). Move them onto `deploy-read <name>` (add the name with `--deploy`) or `fingerprint`.

## Owner steps (once per host)

The owner runs these. Agents never run setup, sudo or an sshd change. Always start with the dry run: it prints each step, the sudoers text, the `authorized_keys` line and the sshd text, and runs no sudo.

Source host (holds the master copy, runs the daily sync):

1. `cd ~/dotfiles && git pull`
2. Decide the folder path. It must be in a path only root can change, default `/opt/secrets-gate/folder`. Setup refuses a path with a link in it, a parent that is not root owned, or a parent others can write.
3. `bash script/secrets-gate-setup.sh --dry-run --role source --hosts "host1 host2"` and read the plan.
4. `bash script/secrets-gate-setup.sh --role source --hosts "host1 host2"`. It asks for the password the first time (Touch ID after). It creates the folder (root, 700), the gate's ssh key and a `known_hosts` from `ssh-keyscan`, and prints the host key fingerprints: compare them with the hosts.
5. Copy the existing credential files into the folder with sudo (`sudo cp -R -P <old folder>/. /opt/secrets-gate/folder/`) (files copied by sudo are root owned), check them, then remove the old copy.
6. Check: `sudo /opt/secrets-gate/secrets-gate fingerprint <a file name in the folder>` prints one line. Check the sync: `bash script/secrets-sync.sh --dry-run` (Touch ID), then `bash script/secrets-sync.sh` (no prompt).

Every receiver host:

1. `cd ~/dotfiles && git pull`
2. On the source host read the gate key: `sudo cat /opt/secrets-gate/id_ed25519.pub`.
3. `bash script/secrets-gate-setup.sh --dry-run --role receiver --pubkey "<that line>"` and read the plan.
4. The same command without `--dry-run`. It installs the gate, root's `authorized_keys` line and the sshd drop in `/etc/ssh/sshd_config.d/100-secrets-gate.conf` (`PermitRootLogin forced-commands-only`), and checks the config with `sshd -t`. If `/etc/ssh/sshd_config` has no `Include /etc/ssh/sshd_config.d/*.conf` line it says so: add it above the first `Match` line.
5. Remote Login must be on (macOS: System Settings, General, Sharing). sshd reads the drop in on the next connection (macOS). On Linux: `sudo systemctl reload ssh`.
6. Check: `sudo sshd -T | grep -i permitrootlogin` says `forced-commands-only`. Then from the source: `bash script/secrets-sync.sh`.

A receiver that is not set up yet is skipped with a warning by the push, so the order of hosts does not matter. Do the source host first.

Optional on the source host: `--deploy "name1 name2"` sets the file names `deploy-read` may print.

Both roles write the sudoers drop in `/etc/sudoers.d/secrets-gate` (checked with `visudo -cf` before install): `run *` on every host, plus `sync` on the source. `receive` stays in root's `authorized_keys` only.

Helpers (any host, after the steps above): put the helper scripts in one folder, then run the same setup command with `--helpers <that folder>`, for example `bash script/secrets-gate-setup.sh --dry-run --role receiver --pubkey "<gate key line>" --helpers <folder>`, read the plan, and run it again without `--dry-run`. Each regular file becomes `/opt/secrets-gate/helpers/<name>` (root, 755). A link, a name with a leading dot or dash, or anything that is not a regular file stops setup before any sudo. Check: `sudo -n /opt/secrets-gate/secrets-gate run <name>` runs with no prompt.

Undo on a host: `sudo chown -R "$USER" <folder> && sudo chmod -R u+rwX,go-rwx <folder>`, remove `/opt/secrets-gate` (helpers included), `/etc/sudoers.d/secrets-gate`, `/etc/ssh/sshd_config.d/100-secrets-gate.conf` and the gate line in root's `authorized_keys`.

## Scripts moved onto the gate

`script/secrets-sync.sh` calls `sudo -n gate sync` (flags use plain `sudo`). `env-peek.py`, when it cannot open a file, asks `sudo gate fingerprint <file>`, so the fingerprint covers the whole file and there are no per key lines. `script/secrets-pack.sh` and `script/secrets-unpack.sh` are not moved: after setup the owner runs them with `sudo`.

## Searching for who uses the folder

`script/secrets-refs.sh <dir> <pattern>` lists `file:line` for every match under `<dir>` and never prints the matched text. It skips any directory named `secrets`. The Bash guard lets this one script, called directly, take the folder name as its pattern. Everything else that names the folder stays denied. Use it to survey the deploy and host scripts of a project.

## Editing one host in a credential file

Owner decision 2026-11-28 (#2083): a one line fix that is not a secret, such as a retired database host inside a connection string, asks for permission instead of waiting for the owner to type it. `script/set-env-key.py <file> <KEY> --replace-host <old> <new>` swaps the host inside one key's URL value in place. It keeps the mode, the owner and every other byte, and prints only the key, the two hosts and the file, never a value. It refuses a key that is missing, set twice or not a URL, a host that does not match, and anything that is not a plain host name.

The Bash guard answers "ask", not "deny", only when the whole command is that script (the dotfiles copy, by real path, optionally after `python3`) with plain words, or a whole command that matches a `secrets_edit_ask` pattern in the project's `guard-config.json` (a fixed root action on a host, for a file another OS user owns). A second command, pipe, redirect, expansion, quote or glob keeps the deny, and a `secrets_edit_ask` pattern found inside a larger command is denied. The worker relays the exact command to the coordinator, who gets the owner's yes for it. Headless runs (`claude -p`) refuse an "ask", so nothing runs there without a person.

## Tests

`script/tests/secrets-gate.test.sh`, `secrets-gate-setup.test.sh`, `secrets-sync.test.sh`, `secrets-refs.test.sh`, `set-env-key.test.sh`, and the guard cases in `templates/agent-team/.claude/hooks/tests/test_guard_bash.py`. They use fake folders in a temp dir, a fake `sudo`, and a fake `ssh` that acts as sshd with a forced command. They replay every attack from the two Verdicts on PR 936: option injection into receive, two pushes with a symlink then keep dirlinks, a link planted before setup, leading dash and glob names, a hostile user ssh config, and the environment before the root reset.
