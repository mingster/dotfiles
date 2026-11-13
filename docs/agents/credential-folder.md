# Credential folder: root owned, one gate, receivers never trust the worker account

Read this before changing `script/secrets-gate.sh`, `script/secrets-gate-setup.sh`, `script/secrets-sync.sh`, `script/secrets-refs.sh`, or anything that reads the credential folder. Decision: issue 922 (owner answers Q1 A, Q2 A, Q3 B). This is the second design, after two FAIL Verdicts on PR 936.

## The rule

On every host, no process running as the worker account can read the folder or write as root. The daily sync still runs unattended from the source host.

Workers and the owner share one OS account, so anything that logs in as that account, or runs through a passwordless sudo entry that takes input, is reachable by a worker. The first design let each receiver accept the push as that account and then raise to root with a passwordless entry. Both reviews broke it. The fix is not a better receive script. The fix is that a receiver never involves the shared account at all.

## Design

| Piece | Where | Who can change it |
|---|---|---|
| The folder | A path only root controls, default `/opt/secrets-gate/folder`. Owner root, mode 700. | root |
| The gate | `/opt/secrets-gate/secrets-gate` with `secrets-gate.conf` (folder, hosts, deploy list) beside it | root |
| Source host: sync | `sudo -n /opt/secrets-gate/secrets-gate sync`, the only passwordless sudoers entry anywhere (exact command, no wildcard) | root |
| Source host: ssh | Root's own key `/opt/secrets-gate/id_ed25519` and root owned `known_hosts`. ssh runs with `-F /dev/null`, strict host keys, `root@<host>` | root |
| Receiver host: login | `root@<host>` with the gate key. Root's `authorized_keys` holds one line: `restrict,command="/opt/secrets-gate/secrets-gate receive" <gate key>` | root |
| Receiver host: sshd | Drop in with `PermitRootLogin forced-commands-only` | root |

A receiver has no sudoers entry and no step that runs as the worker account. A worker on a receiver cannot start `receive`: only the holder of the gate key can, and that key is mode 600 root on the source. A worker on the source can start `sync`, which takes no input except `--dry-run` (not passwordless) and pushes only to the hosts in the root owned config.

The gate commands (anything else is refused with exit 2):

| Command | What it does | Approval |
|---|---|---|
| `fingerprint <file>` | Size and 8 hex fingerprint of one regular file in the folder. Never the content. | Touch ID or password |
| `sync` | Pushes the folder to `root@<host>` for each fleet host. Prints file names only. | Passwordless (the one entry) |
| `sync --dry-run` | Lists the files and hosts. Contacts no host (the receiver ignores client options, so a real rsync dry run cannot be asked of it). | Touch ID or password |
| `receive` | The rsync server side. Only as the forced command. Takes no argument. Ignores the client's command line. | Forced command only |
| `deploy-read <name>` | Prints one file named on the config's deploy list. | Touch ID or password |
| `check-path <path>` | Exit 0 when the path is root controlled. Setup uses it. | none, prints no content |

## Why the gate stays safe

- Every use checks the folder first: the path and every parent is a real directory (no link) owned by root and not writable by group or others, the folder is root mode 700, and no symbolic link sits anywhere inside it. A parent the owner account can write would let a worker rename the folder and plant a link, so such a path is refused. This is why the folder does not stay under a home folder.
- `receive` starts `rsync --server -rt` itself with a fixed list (no `-l`, `-K`, `-L`, `-o`, `-g`, `-D`, `--delete`) into a fresh staging folder inside the root 700 folder, then moves regular files only into place with `mv -f --`. Directories are made one component at a time and the parent is checked again just before each move. Links and special files are dropped. Nothing is ever deleted.
- The gate starts as `#!/bin/bash`, calls `/usr/bin/id`, and under root re-executes itself with an empty environment and `PATH=/usr/bin:/bin:/usr/sbin:/sbin` before anything else. `SECRETS_GATE_CONF`, `SG_RSYNC` and `SG_TRUST_UID` are ignored under root. The sudoers drop in sets `env_reset` and `secure_path` too. Globbing is off, and every `mv`, `mkdir`, `rm`, `cat` and `chmod` puts `--` before names.
- The sync's ssh reads nothing the worker account can edit: `-F /dev/null`, one root owned key, one root owned `known_hosts`, `StrictHostKeyChecking=yes`, `ProxyCommand=none`, and host names checked against a plain pattern (no leading dash, no `user@`).

## Limits to know

- A worker can run the passwordless `sync`. It prints file names, never contents, and sends only to the configured hosts with the pinned host keys.
- The sync no longer deletes. A rotated or retired credential stays on every receiver until the owner removes it there with `sudo rm`.
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

Undo on a host: `sudo chown -R "$USER" <folder> && sudo chmod -R u+rwX,go-rwx <folder>`, remove `/opt/secrets-gate`, `/etc/sudoers.d/secrets-gate`, `/etc/ssh/sshd_config.d/100-secrets-gate.conf` and the gate line in root's `authorized_keys`.

## Scripts moved onto the gate

`script/secrets-sync.sh` calls `sudo -n gate sync` (flags use plain `sudo`). `env-peek.py`, when it cannot open a file, asks `sudo gate fingerprint <file>`, so the fingerprint covers the whole file and there are no per key lines. `script/secrets-pack.sh` and `script/secrets-unpack.sh` are not moved: after setup the owner runs them with `sudo`.

## Searching for who uses the folder

`script/secrets-refs.sh <dir> <pattern>` lists `file:line` for every match under `<dir>` and never prints the matched text. It skips any directory named `secrets`. The Bash guard lets this one script, called directly, take the folder name as its pattern. Everything else that names the folder stays denied. Use it to survey the riben.life deploy and host scripts.

## Tests

`script/tests/secrets-gate.test.sh`, `secrets-gate-setup.test.sh`, `secrets-sync.test.sh`, `secrets-refs.test.sh`, and the guard cases in `templates/agent-team/.claude/hooks/tests/test_guard_bash.py`. They use fake folders in a temp dir, a fake `sudo`, and a fake `ssh` that acts as sshd with a forced command. They replay every attack from the two Verdicts on PR 936: option injection into receive, two pushes with a symlink then keep dirlinks, a link planted before setup, leading dash and glob names, a hostile user ssh config, and the environment before the root reset.
