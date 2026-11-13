# API keys and tokens live in the keychain

Read this before adding a key or token to any shell startup file, or when a tool says it cannot find one.

## Rule

Startup files (`.zshenv`, `.zshrc`, `.zlogin`, and the `~/.zprofile`, `~/.zshenv.local`, `~/.bash*` files on a host) export no variable ending in `_KEY`, `_TOKEN` or `_SECRET`. A key in the shell environment is inherited by every process and shows in a process listing.

A tool that needs a key gets it for that one command with `bin/with-keychain`:

```sh
with-keychain GEMINI_API_KEY -- gemini
```

It reads each name from the login keychain (account is your user name, service is the name), exports it to that command only, and writes nothing to disk. On macOS `.zshrc` defines a `gemini` function that does this. Other hosts have no keychain helper, so `gemini` runs unwrapped there.

## Where each key was set

`.zshrc` sourced `~/dotfiles/.env`, a git ignored file inside the dotfiles folder. It set three names: `GEMINI_API_KEY`, `CONTEXT7_API_KEY`, `GITHUB_PERSONAL_ACCESS_TOKEN`. No tracked startup file set any key. `~/.zshenv.local`, `~/.zprofile`, `~/.bashrc` and `~/.bash_profile` set none on the host checked. Check the other hosts with `grep -o -E '^[[:space:]]*(export )?[A-Za-z_]*(KEY|TOKEN|SECRET)[A-Za-z_]*=' <file>` (names only).

## Owner steps, per key

1. Rotate the key at its provider (Gemini, GitHub, Context7). The old values were shown in an agent session on 2026-11-13.
2. Store the new value without typing it into a shell history line:
   `security add-generic-password -U -a "$USER" -s GEMINI_API_KEY -w` (it prompts for the value). Repeat with `-s CONTEXT7_API_KEY` and `-s GITHUB_PERSONAL_ACCESS_TOKEN`.
3. Delete the old line from `~/dotfiles/.env` (or delete the file).
4. Point the tool at the wrapper:
   * Gemini CLI: already wrapped by the `gemini` function in `.zshrc`.
   * GitHub and Context7 MCP servers: in the MCP config (`~/.claude/settings.local.json`, generated per machine) set the server `command` to `with-keychain`, with `args` of `["GITHUB_PERSONAL_ACCESS_TOKEN", "CONTEXT7_API_KEY", "--", "<original command>", ...]`. Name only the keys that server needs (GitHub: `GITHUB_PERSONAL_ACCESS_TOKEN`, Context7: `CONTEXT7_API_KEY`).
   * `gh` keeps its own token in the keychain; it needs no variable.
5. Open a new shell and confirm `env | grep -c -E '_(KEY|TOKEN|SECRET)='` prints 0 (it prints a count, never a value).

## Other places

A key set in a file outside dotfiles (for example `~/dotfiles/.env` itself, or a project `.env.local`) is the owner's to move. This repo does not read or edit those files.
