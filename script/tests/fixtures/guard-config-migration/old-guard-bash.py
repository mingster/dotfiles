#!/usr/bin/env python3
# Test fixture for agent-team-guard-migration.test.sh (#780): a project guard from before guard-config.json,
# with project, host and path names replaced by placeholders. Not a live hook.
"""PreToolUse guard for Bash, shared by the otherproj and example.app agent teams.

Blocks five kinds of accident:

1. Running a raw deploy script that only the pipeline wrapper may run. The check
   looks at the program a command segment executes, so `git add bin/deploy-win.sh`,
   `grep x bin/deploy-win.sh` or editing the script are allowed; `./bin/deploy-win.sh`,
   `bash bin/deploy-win.sh` or `FOO=1 sh -c "bin/deploy-win.sh"` are not.
2. Printing a secret into the session log: reading `.env` files, `secrets/`, key
   files, or echoing secret environment variables. Use `.claude/bin/env-peek.py`
   to check a value without printing it.
3. A PayPal API call other than GET and the token request.
4. Risky commands without the owner's go: a push to a production branch, any force
   push, the promote script, the schema override, and ssh, scp or rsync to the
   production host beyond a read only allowlist. The owner gives the go by running
   `bin/owner-approve.sh` in his own terminal, which writes
   ~/.config/<namespace>/approval.json (valid 30 minutes). Agents may read that file
   but never run owner-approve.sh or write the file (Bash, Write or Edit). Every
   project specific value is in the PROJECT CONFIG block below.
5. Copying or linking explicit `.env.local` operands into agent worktrees,
   including literal shell wrappers and relative destinations.
6. Running Playwright or production builds outside the shared heavy job gate, or type checks outside measure mode.
   Gate wrappers execute their children outside PreToolUse, so no environment
   escape hatch is needed.

This stops accidents and casual self approval, not a determined attacker: an agent
that rewrites this hook or hides a command inside a script gets past it.
Anything it cannot parse is let through: the deny rules in settings.json are the
backstop. Exit 0 always; a block is a JSON permissionDecision of "deny".
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time

# Scripts only the deploy wrapper may run (otherproj: other_op/bin/deploy-stage.sh; example.app has none).
BLOCKED_SCRIPTS = {
    "deploy-win.sh",
    "deploy-to-wowza.sh",
    "deploy_jar.sh",
    "push_smil.sh",
    "iis-manage.sh",
}

SECRET_FILE = re.compile(
    r"(^|[/=])("
    r"\.env(\.(?!example$|sample$|template$|dist$)[A-Za-z0-9_.-]+)?"
    r"|(?<=/)[^/\s]+\.env"  # Path components, not code references such as process.env.
    r"|[^/\s]*\.(p8|pem|p12|pfx|key|keystore|jks)"
    r"|secrets/[^\s]*"
    r"|secrets"
    r"|id_(rsa|ed25519|ecdsa)"
    r")$"
)
# Any Bash command that reads under the secrets dir is denied (#4926). The one way in is running
# SIGN_IN_SCRIPT, which reads the file itself so the path never appears in a command.
SECRETS_DIR = re.compile(r"fileServer/secrets")
SECRETS_WRITE_REDIRECT = re.compile(r">>?\s*\S*fileServer/secrets\S*")
SECRETS_NONREAD = {"ls", "stat", "test", "[", "[[", "mkdir", "chmod", "chown", "touch", "rm", "rmdir", "pwd"}
SECRETS_COPIERS = {"cp", "mv", "ln", "rsync", "scp", "install"}
SIGN_IN_SCRIPT = ".claude/bin/playground-sign-in.sh"
# The documented sysAdmin account commands (docs/SECURITY/sysadmin-access.md) that take a password file as
# stdin and nothing else. The whole segment must match: no extra operand, redirect or command.
_PW = r"(?:~|\$HOME|/Users/[\w.-]+)/projects/example\.app/fileServer/secrets/sysadmin/app-devops-sysadmin-"
_SHA = r"[0-9a-f]{40}"
SECRETS_STDIN_OK = [re.compile(p) for p in (
    rf"ssh root@build\.example\.net '/var/www/sandbox\.example\.app/bin/deploy-playground\.sh {_SHA} --sysadmin-account' < {_PW}playground",
    rf"(?:\./)?bin/ensure-production-sysadmin\.sh {_SHA} < {_PW}production",
    rf"bun run ensure:agent-sysadmin < {_PW}playground",
)]
SECRET_VAR = re.compile(r"SECRET|PASSW|TOKEN|KEY|PRIVATE|CRED|DATABASE_URL|_RO_URL|DSN|AUTH", re.I)

READERS = {
    "cat", "less", "more", "head", "tail", "bat", "batcat", "strings", "xxd", "od",
    "hexdump", "base64", "nl", "tac", "sort", "uniq", "jq", "yq", "awk", "gawk",
    "cut", "diff", "column", "pr", "fold", "paste", "openssl", "plutil",
}
GREPS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
QUIET_GREP_FLAGS = re.compile(r"^-(-count|-quiet|-silent|-files-with(out)?-match(es)?|[A-Za-z]*[qclL][A-Za-z]*)$")
SHELLS = {"bash", "sh", "zsh", "fish", "dash", "ksh"}
WRAPPERS = {"sudo", "nohup", "time", "command", "exec", "nice", "caffeinate", "stdbuf"}
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

ENV_PEEK = ".claude/bin/env-peek.py <file> [KEY ...]"

# ==================================================================================
# PROJECT CONFIG for 4, the owner approval gate (example.app; facts in
# docs/agents/deploy-facts.md). Porting the gate to another project (otherproj) means
# changing this block and the variables at the top of bin/owner-approve.sh; the code
# below names no project.
APPROVAL_NAMESPACE = "exampleapp"  # the approval file is ~/.config/<namespace>/approval.json
PRODUCTION_BRANCHES = {"production"}  # every branch a deploy pipeline reads as production
# Production hosts (ssh, scp, rsync targets) live in production-hosts.txt beside this file: one host or
# IPv4 per line, # comments. A missing or unreadable file fails closed (every target counts as production).
# GUARD_PRODUCTION_HOSTS overrides the path (tests only; the harness sets the hook's environment).
PRODUCTION_HOSTS_FILE = os.environ.get("GUARD_PRODUCTION_HOSTS") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "production-hosts.txt")
APPLY_SCRIPTS = {"apply-production-sql.sh", "set-production-secret.sh", "run-production-data-step.sh"}  # need promote <sha> --schema --apply
# The host commands bin/promote-production.sh and bin/rollback-production.sh send, built from the
# defaults in bin/production-target.sh: ssh target -> exact remote commands. SHA40 is the release; a
# command naming it needs `promote <sha>` or `rollback <sha>` for that sha, the others either scope.
# Anything else on these hosts (including the legacy `deploy.sh production production`) needs `host`.
_APP, _BUNDLE_ROOT, _PROD_PATH = "/var/www/example.app", "/var/www/example.app-bundle", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
_BUNDLE_DEPLOY = f"PROD_APP_DIR={_APP} BUNDLE_ROOT={_BUNDLE_ROOT} PATH={_PROD_PATH} sh {_APP}/bin/deploy.sh bundle SHA40 build-artifacts:/"
HOST_DEPLOY_COMMANDS = {
    "root@prod.example.net": [  # production host: scripts at the release, then the bundle deploy
        f"git -C {_APP} fetch --quiet origin && git -C {_APP} checkout --quiet --detach SHA40",
        _BUNDLE_DEPLOY,
        f"SKIP_DB_PUSH=1 {_BUNDLE_DEPLOY}",  # rollback
    ],
}
HOST_DEPLOY_PATTERNS = {target: [re.compile(re.escape(c).replace("SHA40", "(?P<sha>[0-9a-f]{40})")) for c in cmds]
                        for target, cmds in HOST_DEPLOY_COMMANDS.items()}
PROMOTE_SCRIPTS = {"promote-production.sh"}  # local scripts that promote <sha> to production
ROLLBACK_SCRIPTS = {"rollback-production.sh"}  # local scripts that roll production back to <sha>
SCHEMA_OVERRIDE = "SCHEMA_APPROVED"  # env override for a production schema push; needs promote --schema
# The only commands that run on a production host without approval: each part of the remote command
# (split on ; && || | and newlines, `2>&1` and `>/dev/null` removed) must be exactly one of these, with
# single spaces. No env assignment, wrapper, extra option or git: anything else needs `host`.
_P, _U, _N = r"/[A-Za-z0-9._/@+-]*", r"[A-Za-z0-9@._-]+", r"[0-9]+"  # absolute path, unit or name, number
REMOTE_READ_ONLY = [re.compile(p) for p in (
    "true", "uptime", "free( -[hm])?", "df( -h)?", "cat /etc/os-release", "pg_lsclusters",
    "pm2 (status|ls|list|jlist)", f"pm2 logs {_U} --nostream( --lines {_N})?",
    f"systemctl status {_U}", f"journalctl -u {_U} -n {_N} --no-pager",
    f"readlink {_P}", f"ls -la {_P}", f"tail -n {_N} {_P}", f"test -s {_P}",
    r'pgrep -fa "[A-Za-z0-9 ._/|\[\]-]+"',  # promote and rollback check for a running deploy or build
    f"curl -fsS http://localhost(:{_N})?{_P}",  # health check
    f"tail -n {_N}", f"tail -{_N}", f"head -n {_N}", "grep (-[iv] )?[A-Za-z0-9._-]+", "wc -l",  # after a pipe
)]
# ==================================================================================

APPROVAL_DIR = os.path.join(os.path.expanduser("~"), ".config", APPROVAL_NAMESPACE)
APPROVAL_FILE = os.path.join(APPROVAL_DIR, "approval.json")
APPROVAL_MARKERS = (f".config/{APPROVAL_NAMESPACE}", "approval.json")
APPROVAL_TTL = 30 * 60
APPROVE = "bin/owner-approve.sh"
PRODUCTION_REF = re.compile(r"refs/(heads/)?(" + "|".join(map(re.escape, PRODUCTION_BRANCHES)) + r")\b")
EDIT_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
# Programs that may name owner-approve.sh or the approval file without running or writing it.
VIEWERS = {"cat", "less", "more", "head", "tail", "bat", "nl", "wc", "ls", "stat", "file", "diff",
           "jq", "test", "[", "shellcheck"} | GREPS
SCRIPT_NAME = re.compile(r"owner-approve(?![A-Za-z0-9_-])")  # not a branch like owner-approve-docs
# git subcommands that can run a program named on their command line.
GIT_RUNS_PROGRAMS = {"filter-branch", "rebase", "bisect", "submodule", "difftool", "mergetool", "config", "alias"}
GIT_READ_ONLY = {"log", "diff", "show", "blame", "status", "grep", "ls-files", "cat-file", "shortlog"}
GH_RUNS_PROGRAMS = {"alias", "extension", "ext"}
# Options whose value is prose (a commit message, a PR body), not a path or a program.
TEXT_FLAGS = {"-m", "--message", "-b", "--body", "-t", "--title", "--subject", "--spec", "--question",
              "--reason", "--comment", "--description", "-f", "-F", "--field", "--raw-field"}
SSH_OPTS_WITH_ARG = set("BbcDEeFIiJLlmOoPpQRSWw")
SCP_OPTS_WITH_ARG = set("cDFiJlLoPSX")  # scp
SFTP_OPTS_WITH_ARG = set("BbDcFiJlLoPRSXs")  # sftp
RSYNC_OPTS_WITH_ARG = set("eBfMT@")
# ssh, scp, sftp and rsync -e take only these -o options. Any other can run a command the guard never
# sees (ProxyCommand, LocalCommand, KnownHostsCommand) or send the session to another host (HostName,
# ProxyJump, ControlPath), whatever destination the command line names.
SSH_ALLOWED_OPTIONS = {"batchmode": r"yes|no", "connecttimeout": r"[0-9]+",
                       "serveraliveinterval": r"[0-9]+", "serveralivecountmax": r"[0-9]+"}
SSH_REFUSED_FLAGS = {"ssh": set("FJS"), "scp": set("FJSD"), "sftp": set("FJSD")}  # config file, jump host,
# control socket, a program run in place of ssh or sftp-server
GIT_SSH_KEYS = {"core.sshcommand", "core.gitproxy"}  # git config that names the program git reaches a host with
GIT_SSH_ENV = re.compile(r"^(GIT_SSH|GIT_SSH_COMMAND|GIT_PROXY_COMMAND)=")

CWD = None


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def segments(command):
    """Split a command line on control operators, keeping quoted text intact."""
    out, buf, quote, i = [], [], None, 0
    while i < len(command):
        c = command[i]
        if quote:
            buf.append(c)
            if c == "\\" and quote == '"' and i + 1 < len(command):
                buf.append(command[i + 1])
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"":
            quote = c
            buf.append(c)
        elif c == "\\" and i + 1 < len(command):
            buf.append(c + command[i + 1])
            i += 1
        elif c in ";|&\n" or (c in "({" and not "".join(buf).strip()):
            out.append("".join(buf))
            buf = []
        elif c in ")}" and not quote:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(c)
        i += 1
    out.append("".join(buf))
    return [s.strip() for s in out if s.strip()]


def strip_comment(segment):
    """The segment up to a # that starts a word outside quotes. sh reads a # inside a word
    (a#b) as text, while shlex comments=True would drop the rest of the line from it."""
    quote, i = None, 0
    while i < len(segment):
        c = segment[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "\\":
            i += 1
        elif c == "#" and (i == 0 or segment[i - 1] in " \t\n;&|()<>"):
            return segment[:i]
        i += 1
    return segment


def words(segment):
    try:
        return shlex.split(strip_comment(segment))
    except ValueError:
        return segment.split()


def program_and_args(tokens):
    """Skip env assignments and wrappers; return (program, args)."""
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if ENV_ASSIGN.match(t):
            i += 1
        elif os.path.basename(t) == "env":
            i += 1
            while i < len(tokens) and (tokens[i].startswith("-") or ENV_ASSIGN.match(tokens[i])):
                if tokens[i] in {"-C", "--chdir", "-u", "--unset"}:
                    i += 1
                i += 1
            if i == len(tokens):
                return "env", []
        elif os.path.basename(t) in WRAPPERS:
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                i += 1
        elif t == "timeout":
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                i += 1
            i += 1  # the duration
        elif t == "xargs":
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                i += 1
        else:
            return t, tokens[i + 1:]
    return None, []


def substitutions(command):
    """The text inside $( ... ) and backticks, innermost first."""
    out = re.findall(r"`([^`]*)`", command)
    depth, start = 0, None
    for i, c in enumerate(command):
        if command.startswith("$(", i):
            if depth == 0:
                start = i + 2
            depth += 1
        elif c == ")" and depth:
            depth -= 1
            if depth == 0:
                out.append(command[start:i])
    return out


HEREDOC = re.compile(r"(?<!<)<<-?(?!<)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def split_heredocs(command):
    """(command without heredoc bodies, [(line that opens it, body)])."""
    lines, out, bodies, i = command.split("\n"), [], [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in HEREDOC.finditer(line):
            body = []
            while i < len(lines) and lines[i].strip() != m.group(2):
                body.append(lines[i])
                i += 1
            i += 1
            bodies.append((line, "\n".join(body)))
    return "\n".join(out), bodies


def feeds_shell(line):
    """True when a heredoc on this line ends up as a script: a shell reads it, or ssh sends it.
    Segments before the one holding << do not read it; the ones after it might (a pipe)."""
    segs = segments(line)
    start = next((i for i, seg in enumerate(segs) if "<<" in seg), 0)
    for seg in segs[start:]:
        prog, args = program_and_args(words(seg))
        base = os.path.basename(prog or "")
        if base == "ssh" or (base in SHELLS and not any(re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) for a in args)):
            return True
    return False


def check_command(command, depth=0, cwd=None):
    global CWD
    if depth > 4:
        return
    original_cwd = CWD
    if cwd is not None:
        CWD = cwd
    try:
        command, bodies = split_heredocs(command)
        for line, body in bodies:
            if feeds_shell(line):
                check_command(body, depth + 1)
        for inner in substitutions(command):
            check_command(inner, depth + 1)
        for seg in segments(command):
            check_segment(seg, depth)
            prog, args = program_and_args(words(seg))
            if prog == "cd" and args:
                destination = next((a for a in args if not a.startswith("-")), None)
                if destination:
                    CWD = os.path.normpath(os.path.join(CWD or os.getcwd(), os.path.expanduser(destination)))
    finally:
        CWD = original_cwd


def check_worktree_env(base, args, cwd=None):
    """Reject explicit env transfers using only command operands, never file contents."""
    if base not in {"cp", "ln", "rsync"}:
        return
    operands, target, i, options = [], None, 0, True
    valued = {"--suffix", "--chmod", "--chown", "--exclude", "--include",
              "--filter", "--exclude-from", "--include-from", "--files-from", "--rsh"}
    while i < len(args):
        arg = args[i]
        if options and arg == "--":
            options = False
        elif options and base in {"cp", "ln"} and arg in {"-t", "--target-directory"}:
            i += 1
            target = args[i] if i < len(args) else None
        elif options and base in {"cp", "ln"} and arg.startswith("--target-directory="):
            target = arg.split("=", 1)[1]
        elif options and base in {"cp", "ln"} and re.fullmatch(r"-[A-Za-z]*t", arg):
            i += 1
            target = args[i] if i < len(args) else None
        elif options and base in {"cp", "ln"} and arg.startswith("-t") and not arg.startswith("--"):
            target = arg[2:]
        elif options and (arg in valued or (base == "rsync" and arg in {"-e", "-f", "-B", "-T"})):
            i += 1
        elif options and arg.startswith("-"):
            pass
        else:
            operands.append(arg)
        i += 1
    if not operands:
        return
    if target is not None:
        sources, destination = operands, target
    elif len(operands) > 1:
        sources, destination = operands[:-1], operands[-1]
    elif base == "ln":
        sources, destination = operands, "."
    else:
        return
    def env_local(path):
        return os.path.basename(path.rstrip("/")).lower() == ".env.local"
    if not any(env_local(p) for p in sources) and not env_local(destination):
        return
    # Resolve lexical paths only; remote rsync targets are handled by the host gate.
    if base == "rsync" and ":" in destination.split("/", 1)[0]:
        return
    path = os.path.normpath(os.path.join(cwd or CWD or os.getcwd(), os.path.expanduser(destination)))
    # Match the default case-insensitive macOS filesystem without resolving links.
    folded_path = path.lower()
    in_worktree = "/orca/workspaces/" in folded_path or "/.claude/worktrees/" in folded_path
    # Expansion cannot be resolved safely without executing shell code. Refuse an
    # explicit env transfer to a dynamic destination instead of guessing its target.
    if in_worktree or re.search(r"[$`*?]", path):
        deny("Copying or linking .env.local into an agent worktree is blocked. "
             "Worktrees must use placeholder configuration; never copy or symlink the local env file.")

def check_secrets_dir(segment, base, args):
    """Deny a segment that reads fileServer/secrets: readers, interpreters, redirects, copies out, cd."""
    text = SECRETS_WRITE_REDIRECT.sub("", segment)
    if not SECRETS_DIR.search(text) or base in SECRETS_NONREAD:
        return
    if any(p.fullmatch(segment.strip()) for p in SECRETS_STDIN_OK):
        return
    if base in SECRETS_COPIERS:
        operands, target_dir, i = [], False, 0
        while i < len(args):
            a = args[i]
            if a in {"-t", "--target-directory"}:
                target_dir, i = True, i + 1
            elif a.startswith("--target-directory=") or (a.startswith("-t") and not a.startswith("--")):
                target_dir = True
            elif not a.startswith("-"):
                operands.append(a)
            i += 1
        sources = operands if target_dir else operands[:-1]
        if not any(SECRETS_DIR.search(a) for a in sources):
            return
    deny(f"{base} would read a file under fileServer/secrets into the session log. Agents never read the "
         f"secrets dir. The only exception is the Playground sign in: run `{SIGN_IN_SCRIPT} <url> <email>`, "
         "which types the password into the form without printing it. Anything else, ask Elon.")


KILL_FORMS = ("Stop a port owner with kill $(lsof -ti tcp:<port> -sTCP:LISTEN), or a job you started "
              "with kill on the pid you saved from $! in its own pidfile.")


def check_pattern_kill(segment, base, args):
    # A name or command line match also hits agent sessions and Orca shells, whose
    # arguments carry long briefs; pkill -f "next dev" killed Orca twice (#4989).
    tokens = words(segment)
    while tokens and tokens[0] in {"if", "then", "else", "elif", "do", "while", "until", "!"}:
        tokens = tokens[1:]
    inner, _ = program_and_args(tokens)
    base = os.path.basename(inner) if inner else base
    if base in {"pkill", "killall"}:
        deny(f"{base} kills every process whose name or command line matches, Orca and other "
             f"sessions included. {KILL_FORMS}")
    if base == "kill" and re.search(r"pgrep|pidof|\bgrep\b", segment):
        deny(f"kill on a pgrep, pidof or grep result is a pattern kill. {KILL_FORMS}")
    if base == "kill" and "xargs" in (os.path.basename(w) for w in words(segment)):
        deny(f"xargs kill takes its pids from a pipe the guard cannot see. {KILL_FORMS}")


def check_segment(segment, depth=0):
    if depth > 4:
        return
    prog, args = program_and_args(words(segment))
    if not prog:
        return
    base = os.path.basename(prog)

    transfer_cwd = CWD
    tokens = words(segment)
    # env --chdir changes only this invocation, not the following shell segment.
    for i, token in enumerate(tokens):
        if os.path.basename(token) == "env":
            for j in range(i + 1, len(tokens)):
                arg = tokens[j]
                if arg in {"-C", "--chdir"} and j + 1 < len(tokens):
                    transfer_cwd = os.path.join(CWD or os.getcwd(), os.path.expanduser(tokens[j + 1]))
                    break
                if arg.startswith("--chdir="):
                    transfer_cwd = os.path.join(CWD or os.getcwd(), os.path.expanduser(arg.split("=", 1)[1]))
                    break
            break
    check_worktree_env(base, args, transfer_cwd)
    check_pattern_kill(segment, base, args)

    # 4. Owner approval gate.
    check_risky(segment, base, args, depth)

    # 6. Heavy jobs must acquire the shared machine budget.
    try:
        heavy_tokens = shlex.split(segment, comments=True)
        while heavy_tokens and heavy_tokens[0] in {"if", "then", "else", "elif", "do", "while", "until", "!"}:
            heavy_tokens = heavy_tokens[1:]
        heavy_prog, heavy_args = program_and_args(heavy_tokens)
    except ValueError:
        heavy_prog, heavy_args = None, []
    heavy_base = os.path.basename(heavy_prog or "")
    if heavy_base == "bun":
        # Bun global options precede the command; some consume a separate value.
        while heavy_args and heavy_args[0].startswith("-"):
            option = heavy_args[0]
            takes_value = option in {"--cwd", "--config", "--env-file", "--preload", "--require", "--tsconfig-override"}
            heavy_args = heavy_args[2 if takes_value else 1:]
        if heavy_args[:1] == ["x"]:
            heavy_base, heavy_args = "bunx", heavy_args[1:]
    measure = heavy_base == "tsc"
    weight = None
    if heavy_base == "playwright":
        weight = 2
    elif heavy_base == "next" and heavy_args[:1] == ["build"]:
        weight = 2
    elif heavy_base == "bun":
        if heavy_args[:2] == ["run", "build"]:
            weight = 2
        elif len(heavy_args) > 1 and heavy_args[0] == "run" and heavy_args[1].startswith("test:regression"):
            weight = 2
        elif heavy_args[:2] == ["run", "tsc"]:
            measure = True
    elif heavy_base in {"bunx", "npx"}:
        if heavy_args[:1] == ["tsc"]:
            measure = True
        elif heavy_args[:1] == ["playwright"] or heavy_args[:2] == ["next", "build"]:
            weight = 2
    if measure:
        deny("Type checks must run through the shared gate in measure mode (no slot wait). "
             f"Run: ~/dotfiles/script/heavy-gate.sh --measure -- {segment}")
    elif weight:
        deny("Heavy jobs must run through the shared machine gate. "
             f"Run: ~/dotfiles/script/heavy-gate.sh --weight {weight} -- {segment}")

    # 1. Raw deploy scripts.
    if base in BLOCKED_SCRIPTS:
        deny(f"{base} runs only inside the deploy pipeline (other_op/bin/deploy-stage.sh through /deploy). "
             "Reading, grepping, editing or committing the file is fine; running it is not.")
    if base == "eval":
        check_command(" ".join(args), depth + 1)
    if base in SHELLS or base in {"source", "."}:
        idx = next((i for i, a in enumerate(args) if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a)), None)
        if idx is not None:
            if idx + 1 < len(args):
                script_text = args[idx + 1]
                positional = args[idx + 2:]
                # Inspect literal positional arguments to shell -c without running
                # shell expansion or opening any source file.
                script_text = re.sub(r"\$(?:\{([0-9])\}|([0-9]))",
                    lambda m: positional[int(m.group(1) or m.group(2))]
                    if int(m.group(1) or m.group(2)) < len(positional) else m.group(0), script_text)
                check_command(script_text, depth + 1, cwd=transfer_cwd)
        else:
            script = next((a for a in args if not a.startswith("-")), None)
            if script and os.path.basename(script) in BLOCKED_SCRIPTS:
                deny(f"{os.path.basename(script)} runs only inside the deploy pipeline (other_op/bin/deploy-stage.sh).")

    # 3. PayPal with the read only credentials: GET requests and the token request only.
    if base in {"curl", "wget", "http", "https", "xh"} and any("paypal.com/" in a for a in args):
        token = any("/oauth2/token" in a for a in args)
        method = None
        for i, a in enumerate(args):
            if a in ("-X", "--request") and i + 1 < len(args):
                method = args[i + 1].upper()
            elif a.startswith("-X") and len(a) > 2:
                method = a[2:].upper()
            elif a.startswith("--request="):
                method = a.split("=", 1)[1].upper()
        body = any(a in ("-d", "-F", "-T", "--json", "--form", "--upload-file", "--post-data") or a.startswith(("--data", "--post-")) for a in args)
        if base in {"http", "https", "xh"} and args and args[0].upper() in ("POST", "PUT", "PATCH", "DELETE"):
            method = args[0].upper()
        if not token and ((method and method not in ("GET", "HEAD")) or body):
            deny("The team calls the PayPal API with GET only (plus the oauth2/token request). Refunds, cancellations "
                 "and any other write are gated: report them to Elon, who asks the owner.")

    # 2a. Anything that reads under the secrets dir.
    check_secrets_dir(segment, base, args)

    # 2. Secrets.
    secret_args = [a for a in args if SECRET_FILE.search(a)]
    if base in READERS and secret_args:
        deny(f"{base} would print {secret_args[0]} into the session log. Use {ENV_PEEK}: it shows which "
             "keys are set, masks passwords, names the database in a connection string and prints fingerprints "
             "to compare values. Copying .env.local into agent worktrees is blocked.")
    if base in GREPS and secret_args and not any(QUIET_GREP_FLAGS.match(a) for a in args):
        deny(f"{base} on {secret_args[0]} prints secret values. Use {ENV_PEEK}, or {base} -q / -c / -l "
             "when only the presence of a key matters.")
    if base in {"sed", "gsed"} and secret_args and not any(a == "-i" or a.startswith("-i") for a in args):
        deny(f"sed on {secret_args[0]} prints secret values. Use {ENV_PEEK}.")
    if base == "printenv" and (not args or any(SECRET_VAR.search(a) for a in args)):
        deny("printenv would print secret environment variables. Test with [ -n \"${NAME:+set}\" ] "
             "or ${#NAME} for the length instead.")
    if base in {"env", "set", "export", "declare", "typeset", "compgen"} and (not args or args in (["-p"], ["-x"], ["-px"])):
        deny(f"`{base}` alone prints every environment variable, secrets included. Test one variable with "
             "[ -n \"${NAME:+set}\" ] instead.")
    if base in {"echo", "printf", "print"}:
        for m in re.finditer(r"\$(\{)?(#|!)?([A-Za-z_][A-Za-z0-9_]*)(:?[-+?=])?", segment):
            brace, hashed, name, op = m.groups()
            if SECRET_VAR.search(name) and not hashed and op not in (":+", "+"):
                deny(f"{base} would print ${name}. Use ${{{name}:+set}} to show it is set, or ${{#{name}}} for its length.")


# ---------------------------------------------------------------- 4. Owner approval gate

def owner_go(what, owner_command, why):
    deny(f"{what} needs the owner's go ({why}). Owner, run this in your own terminal: "
         f"`{owner_command}` (valid 30 minutes), then the agent reruns the same command. "
         f"Agents never run {APPROVE} or write {APPROVAL_FILE}; report the request to Elon, who asks the owner.")


def load_approval():
    """(approval, reason it is missing or invalid)."""
    try:
        with open(APPROVAL_FILE) as f:
            a = json.load(f)
    except FileNotFoundError:
        return None, "no owner approval is on file"
    except Exception:
        return None, f"{APPROVAL_FILE} is unreadable"
    now = time.time()
    exp = a.get("expires_at") if isinstance(a, dict) else None
    if not isinstance(exp, (int, float)) or isinstance(exp, bool):
        return None, f"{APPROVAL_FILE} has no expiry"
    if exp <= now:
        return None, "the last owner approval has expired"
    if exp > now + APPROVAL_TTL + 60:
        return None, f"{APPROVAL_FILE} claims more than 30 minutes, so it is ignored"
    return a, ""


def approval_for(scopes, target_ok=None):
    """(True, "") when a valid approval has one of scopes and its target passes target_ok."""
    a, why = load_approval()
    if not a:
        return False, why
    scope = a.get("scope")
    if scope not in scopes:
        return False, f"the approval on file is for `{' '.join(filter(None, [scope, a.get('target')]))}`"
    if target_ok and not target_ok(a.get("target") or ""):
        return False, f"the approval on file is for `{scope} {a.get('target')}`, not this target"
    return True, ""


def git(*args, cwd=None):
    try:
        out = subprocess.run(["git", *args], cwd=cwd or CWD, capture_output=True, text=True, timeout=5)
    except Exception:
        return None
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else None


def resolve(ref, cwd=None):
    """Full sha for a ref or sha prefix, or None."""
    if not ref or re.search(r"[$`]", ref):
        return None
    return git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", cwd=cwd)


def same_commit(ref, approved, cwd=None):
    approved = (approved or "").lower()
    if not ref or not re.fullmatch(r"[0-9a-f]{40}", approved):
        return False
    if re.fullmatch(r"[0-9a-fA-F]{7,40}", ref) and approved.startswith(ref.lower()):
        return True
    return resolve(ref, cwd) == approved


def git_subcommand(args):
    i, cdir = 0, None
    while i < len(args):
        a = args[i]
        if a in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env") and i + 1 < len(args):
            if a == "-C":
                cdir = args[i + 1]
            i += 2
        elif a.startswith(("--config-env=", "--exec-path=", "--git-dir=", "--work-tree=", "--namespace=")):
            i += 1
        elif a.startswith("-"):
            i += 1
        else:
            return a, args[i + 1:], cdir
    return None, [], cdir


def check_git_push(args, cdir):
    cwd = os.path.join(CWD, os.path.expanduser(cdir)) if cdir else CWD
    force = every = delete = False
    positional, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            positional += args[i + 1:]
            break
        if a in ("-o", "--push-option", "--repo", "--receive-pack", "--exec"):
            i += 2
            continue
        if a.startswith("--"):
            name = a.split("=", 1)[0]
            if name in ("--force", "--force-with-lease"):
                force = True
            elif name in ("--all", "--mirror", "--branches"):
                every = True
            elif name == "--delete":
                delete = True
        elif a.startswith("-") and len(a) > 1:
            force = force or "f" in a[1:]
            delete = delete or "d" in a[1:]
        else:
            positional.append(a)
        i += 1

    if every:
        deny(f"`git push {' '.join(args)}` pushes every branch, production included, and cannot be "
             f"approved. Push one named branch (git push origin <branch>). Production moves only through "
             f"/deploy after the owner runs `{APPROVE} promote <sha>` in his own terminal.")

    current = git("symbolic-ref", "--short", "-q", "HEAD", cwd=cwd)
    refspecs = positional[1:] or ["HEAD"]
    for spec in refspecs:
        plus = spec.startswith("+")
        spec = spec.lstrip("+")
        if delete:
            src, dst = "", spec
        elif ":" in spec:
            src, dst = spec.split(":", 1)
        else:
            src = dst = spec
        if dst == "HEAD":
            dst = current or "HEAD"
        branch = dst[len("refs/heads/"):] if dst.startswith("refs/heads/") else dst
        forced = force or plus
        if branch in PRODUCTION_BRANCHES:
            if not src:
                deny(f"Deleting `{branch}` is never an agent's job and {APPROVE} has no scope for it. "
                     "Report it to Elon, who asks the owner; the owner does it himself.")
            sha = resolve(src, cwd) or (src if re.fullmatch(r"[0-9a-fA-F]{7,40}", src) else "<sha>")
            scope = "rollback" if forced else "promote"
            ok, why = approval_for({scope}, lambda t: same_commit(src, t, cwd))
            if not ok:
                what = f"Force pushing (rollback) to `{branch}`" if forced else f"Pushing to `{branch}`"
                owner_go(what, f"{APPROVE} {scope} {sha}", why)
        elif forced:
            ok, why = approval_for({"force-push"}, lambda t: t == branch)
            if not ok:
                owner_go(f"A force push to `{branch}`", f"{APPROVE} force-push {branch}", why)


def remote_read_only(segment):
    """True when this part of a production host command is exactly one of REMOTE_READ_ONLY."""
    text = " ".join(re.split(r"[ \t]+", segment.strip(" \t")))
    return any(p.fullmatch(text) for p in REMOTE_READ_ONLY)


def curl_read_only(args):
    """A direct production-host curl: HTTP(S), no writes, config or credentials."""
    blocked = {"--request", "--json", "--form", "--upload-file", "--remote-name", "--dump-header",
               "--cookie-jar", "--config", "--user", "--header", "--cookie"}
    for i, arg in enumerate(args):
        url = arg.removeprefix("--url=")
        scheme = re.match(r"^([A-Za-z][A-Za-z0-9+.-]*)://", url)
        if scheme and scheme[1].lower() not in {"http", "https"}:
            return False
        if arg.startswith("--"):
            name, _, value = arg.partition("=")
            if name in blocked or name.startswith(("--data", "--trace")):
                return False
            if name == "--output":
                output = value if "=" in arg else (args[i + 1] if i + 1 < len(args) else None)
                if output != "/dev/null":
                    return False
        elif arg.startswith("-"):
            # Short options can be combined (-sSXPOST); a value consumes the rest
            # of its token, so -A's user agent must not be parsed as more flags.
            for j, flag in enumerate(arg[1:], 2):
                if flag in "XdFTODcKuHb":
                    return False
                if flag == "o":
                    output = arg[j:] or (args[i + 1] if i + 1 < len(args) else None)
                    if output != "/dev/null":
                        return False
                    break
                if flag in "Amw":
                    break
    return True


def load_production_hosts():
    """(set of lowercase hosts, None), or (None, reason) when the file is missing or unreadable."""
    try:
        with open(PRODUCTION_HOSTS_FILE, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeError) as e:
        return None, f"{PRODUCTION_HOSTS_FILE} is missing or unreadable ({type(e).__name__}), so every ssh, scp and rsync target counts as production"
    hosts = {ln.split("#", 1)[0].strip().lower() for ln in lines}
    return hosts - {""}, None


def host_deploy_command(target, remote):
    """None, or (the release sha or "") when the raw remote text is exactly one of the promote/rollback
    commands for target. The text is matched as the host's sh reads it: no comment or redirect is
    stripped first, only runs of spaces and tabs are collapsed, and any shell metacharacter outside
    the one `&&` of the checkout form refuses."""
    if not printable(remote):
        return None
    joined = " ".join(re.split(r"[ \t]+", remote.strip(" \t")))
    if re.search(r"[#;&|`$()<>\\'\"{}*?\[\]~]", joined.replace(" && ", " ", 1)):
        return None
    for pat in HOST_DEPLOY_PATTERNS.get(target.lower(), []):
        m = pat.fullmatch(joined)
        if m:
            return m.groupdict().get("sha") or ""
    return None


def printable(text):
    """True when text holds only printable ASCII, space and tab: what sh and the matcher read alike."""
    return re.fullmatch(r"[\x20-\x7e\t]*", text) is not None


def prod_host(arg):
    """True when an ssh, scp or rsync argument names a production host. The host is compared as ssh
    resolves it: case-insensitive, without user@, :port or :path, and without a trailing dot."""
    a = re.sub(r"^(ssh|scp|sftp|rsync)://", "", arg, flags=re.I)
    host = re.split(r"[:/]", a, maxsplit=1)[0].rpartition("@")[2].strip("[]").rstrip(".").lower()
    hosts, err = load_production_hosts()
    if hosts is None:
        return True  # fail closed
    return host in hosts


def take_flags(args, i, with_arg, opts):
    """Read the option word args[i] into opts as (flag, value); return the index after it."""
    a = args[i]
    for j, ch in enumerate(a[1:], 1):
        if ch in with_arg:
            value = a[j + 1:]
            if not value:
                i += 1
                value = args[i] if i < len(args) else ""
            opts.append((ch, value))
            break
        opts.append((ch, None))
    return i + 1


def ssh_argv(args):
    """(options [(flag, value)], destination index or None, remote command index) as ssh reads its
    argv: options, the destination, more options, then the command."""
    opts, dest, i = [], None, 0
    while i < len(args):
        a = args[i]
        if a == "--":
            i += 1
            if dest is None and i < len(args):
                dest, i = i, i + 1
            break
        if a.startswith("-") and len(a) > 1:
            i = take_flags(args, i, SSH_OPTS_WITH_ARG, opts)
        elif dest is None:
            dest, i = i, i + 1
        else:
            break
    return opts, dest, i


def refuse_ssh_options(prog, opts):
    for ch, value in opts:
        allowed = False
        if ch == "o":
            m = re.fullmatch(r"[ \t]*([A-Za-z]+)[ \t]*(?:=|[ \t])[ \t]*([^ \t]+)[ \t]*", value or "")
            allowed = bool(m) and re.fullmatch(SSH_ALLOWED_OPTIONS.get(m.group(1).lower(), r"(?!)"), m.group(2), re.I) is not None
        if (ch == "o" and not allowed) or ch in SSH_REFUSED_FLAGS.get(prog, ()):
            deny(f"`{prog} -{ch} {value}` can run a command or reach a host the guard never sees (ProxyCommand, "
                 "LocalCommand, HostName, a config file, a jump host, a control socket, another program), so no "
                 "approval covers it. Drop the option: -o takes only BatchMode, ConnectTimeout, ServerAliveInterval "
                 "and ServerAliveCountMax. If it is really needed, report it to Elon, who asks the owner; the owner runs it himself.")


def check_rsh(value, what):
    """rsync -e / RSYNC_RSH: the command rsync runs to reach the host. Only ssh with allowed options."""
    prog, rargs = program_and_args(words(value))
    if os.path.basename(prog or "") != "ssh":
        deny(f"{what} `{value}` runs a program other than ssh to reach the host. Use rsync -e 'ssh [-p N]'.")
    refuse_ssh_options("ssh", ssh_argv(rargs)[0])


def is_dangerous_git_config(key, value=None):
    key = key.lower()
    if key in ("core.sshcommand", "core.gitproxy"):
        return True
    if key.startswith("remote.") and (key.endswith(".uploadpack") or key.endswith(".receivepack")):
        return True
    if key.startswith("alias."):
        if value is not None:
            return value.startswith("!")
        return True
    return False

def check_git_ssh(args):
    """git -c core.sshCommand, --config-env and git config writes of it run any command as git's ssh."""
    i = 0
    while i < len(args):
        a = args[i]
        key = ""
        val = None
        if a in ("-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env") and i + 1 < len(args):
            if a in ("-c", "--config-env"):
                parts = args[i + 1].split("=", 1)
                key = parts[0].lower()
                val = parts[1] if len(parts) > 1 else ""
            i += 2
        elif a.startswith(("--config-env=", "--exec-path=", "--git-dir=", "--work-tree=", "--namespace=")):
            if a.startswith("--config-env="):
                parts = a.split("=", 2)
                key = parts[1].lower()
                val = parts[2] if len(parts) > 2 else ""
            i += 1
        elif a.startswith("-"):
            i += 1
            continue
        else:
            break
        if key and is_dangerous_git_config(key, val):
            deny(f"git `{key}` runs any command in place of ssh, on any host, so no approval covers it. "
                 "Run git without it; report a real need to Elon, who asks the owner.")
    sub, rest, _ = git_subcommand(args)
    if sub == "config":
        for a in rest:
            key = a.split("=", 1)[0].lower()
            if not key.startswith("-") and is_dangerous_git_config(key):
                deny("Setting git core.sshCommand, remote uploadpack/receivepack or aliases can run arbitrary commands. "
                     "No approval covers it; report a real need to Elon, who asks the owner.")
    if rest and any(a in ("--upload-pack", "--receive-pack") or (a == "-u" and sub == "clone") or a.startswith(("--upload-pack=", "--receive-pack=")) for a in rest):
        deny("git --upload-pack, --receive-pack and clone -u run arbitrary commands. No approval covers it.")
    if sub and sub.startswith("!"):
        deny("git aliases starting with ! run arbitrary commands. No approval covers it.")


HOST_METACHARS = re.compile(r"[$`{}*?\[\]\\'\"]")
RSYNC_LONG_WITH_ARG = {"--exclude", "--include", "--filter", "--files-from", "--exclude-from", "--include-from",
                       "--log-file", "--temp-dir", "--partial-dir", "--backup-dir", "--chmod", "--chown",
                       "--link-dest", "--compare-dest", "--copy-dest"}
XARGS_RUNS = re.compile(r"(?<![\w.-])(ssh|scp|sftp|rsync)(?![\w.-])")


def raw_words(segment):
    """The words of a segment as typed: split where shlex splits, quotes and backslashes kept."""
    s, out, buf, quote, i = strip_comment(segment), [], "", None, 0
    while i < len(s):
        c = s[i]
        if quote:
            buf += c
            if c == "\\" and quote == '"' and i + 1 < len(s):
                buf += s[i + 1]
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"":
            quote, buf = c, buf + c
        elif c == "\\" and i + 1 < len(s):
            buf += c + s[i + 1]
            i += 1
        elif c in " \t\n":
            if buf:
                out.append(buf)
            buf = ""
        else:
            buf += c
        i += 1
    if buf:
        out.append(buf)
    return out


def hidden_host(word):
    """True when the host part of a raw destination word is not a plain literal: the shell would build
    it from a variable, a substitution, a glob, a brace, an escape or a quote the guard never sees."""
    m = re.fullmatch(r"'([^']*)'|\"([^\"$`\\]*)\"", word)
    if m:  # one quoted word: its text, if that is plain
        inner = m.group(1) if m.group(1) is not None else m.group(2)
        if not HOST_METACHARS.search(inner):
            word = inner
    a = re.sub(r"^(ssh|scp|sftp|rsync)://", "", word, flags=re.I)
    return HOST_METACHARS.search(re.split(r"[:/]", a, maxsplit=1)[0]) is not None


def operands(base, args):
    """Indexes of the scp, sftp or rsync words that are not options or option values."""
    with_arg = {"scp": SCP_OPTS_WITH_ARG, "sftp": SFTP_OPTS_WITH_ARG, "rsync": RSYNC_OPTS_WITH_ARG}[base]
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return out + list(range(i + 1, len(args)))
        if base == "rsync" and a in RSYNC_LONG_WITH_ARG:
            i += 2
        elif a.startswith("--"):
            i += 1
        elif a.startswith("-") and len(a) > 1:
            i = take_flags(args, i, with_arg, [])
        else:
            out.append(i)
            i += 1
    return out


def runs_xargs(tokens):
    """True when the segment's program is xargs (behind env assignments or wrappers)."""
    return any(os.path.basename(t) == "xargs" and program_and_args(tokens[:k] + ["true"])[0] == "true"
               for k, t in enumerate(tokens))


def check_hidden_hosts(segment, base, args):
    """Refuse ssh, scp, sftp or rsync when a word that could be the destination is not a plain literal, and
    xargs running any of them (the destination comes from its input). No approval covers it."""
    tokens = words(segment)
    if runs_xargs(tokens) and XARGS_RUNS.search(" ".join(tokens)):
        deny("xargs running ssh, scp, sftp or rsync takes the destination from its input, where the guard cannot "
             "see it. No approval covers it. Write the command with the literal host instead.")
    if base not in ("ssh", "scp", "sftp", "rsync"):
        return
    raw = raw_words(segment)
    if len(raw) != len(tokens):
        deny(f"The guard cannot read the words of this {base} command, so it is refused. Write it with plain words.")
    raw_args = raw[len(tokens) - len(args):]
    for i in [ssh_argv(args)[1]] if base == "ssh" else operands(base, args):
        if i is not None and hidden_host(raw_args[i]):
            deny(f"`{raw_args[i]}` in {base} is not a plain host name: the shell would build it from $, a backtick, "
                 "braces, a glob, a backslash or quotes, so the guard cannot tell whether it is production. No "
                 "approval covers it. Write the host literally.")


GIT_REMOTE_OPS = {"fetch", "pull", "push", "clone", "ls-remote", "remote", "submodule", "archive"}
NETWORK_PROGRAMS = {"scp", "sftp", "rsync", "nc", "ncat", "netcat", "eval"}


def names_production_host(segment):
    """True when the segment text names a production host or the artifact store."""
    hosts, _ = load_production_hosts()
    tokens = sorted((hosts or set()) | {"build-artifacts"}, key=len, reverse=True)
    pattern = r"(?i)(?<![a-zA-Z0-9.-])(?:%s)\.?(?![a-zA-Z0-9.-])" % "|".join(map(re.escape, tokens))
    return re.search(pattern, segment) is not None


def check_backstop(segment, base, args):
    """A production host named anywhere in a command that executes or connects (ssh, scp, sftp, rsync, curl,
    nc, a shell -c, eval, xargs, a git remote operation) needs `host`, beyond the destination checks above.
    Other programs' text (a commit message, a PR body, sed, echo, a heredoc) is never looked at."""
    if not names_production_host(segment):
        return
    if runs_xargs(words(segment)):
        pass
    elif base == "ssh":
        dest = ssh_argv(args)[1]
        if dest is not None and prod_host(args[dest]):
            return  # check_ssh decided
    elif base == "curl":
        if curl_read_only(args):
            return
    elif base == "git":
        if git_subcommand(args)[0] not in GIT_REMOTE_OPS:
            return
    elif base in SHELLS:
        if not any(re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) for a in args):
            return
    elif base not in NETWORK_PROGRAMS:
        return
    ok, why = approval_for({"host"})
    if not ok:
        owner_go(f"`{base}` naming a production host", f"{APPROVE} host", why)


def check_ssh(args, depth):
    opts, dest, cmd = ssh_argv(args)
    refuse_ssh_options("ssh", opts)
    if dest is None or not prod_host(args[dest]):
        return
    i = dest
    remote = " ".join(args[cmd:]).strip(" \t")
    if not printable(remote):  # sh and the matcher must read the same words
        ok, why = approval_for({"host"})
        if not ok:
            owner_go("A production host command with characters outside printable ASCII", f"{APPROVE} host", why)
        return
    cleaned = re.sub(r"\d*>>?\s*/dev/null|\d*>&\d", "", remote)
    if remote and not re.search(r"[>`]|\$\(", cleaned) and all(remote_read_only(s) for s in segments(cleaned)):
        check_command(remote, depth + 1)  # secrets rules still apply on the host
        return
    sha = None
    if not opts and cmd == i + 1:  # promote and rollback pass no ssh options
        sha = host_deploy_command(args[i], " ".join(args[i + 1:]))  # raw: not stripped, no redirect removed
    if sha is not None:
        ok, _ = approval_for({"host"})
        if not ok:
            ok, why = approval_for({"promote", "rollback"}, lambda t: not sha or t.lower() == sha)
        if not ok:
            owner_go("The deploy command on the production host", f"{APPROVE} promote {sha or '<sha>'}", why)
        return
    ok, why = approval_for({"host"})
    if not ok:
        what = "An interactive ssh session" if not remote else f"`{remote}` on the production host"
        hosts, err = load_production_hosts()
        if hosts is None:
            what += f" (fail closed: {err})"
        owner_go(f"{what} (only status, logs and health checks run without approval)", f"{APPROVE} host", why)


def has_redirect(segment):
    """True when the segment redirects output to a file (outside quotes, not to /dev/null or a fd)."""
    quote, i = None, 0
    while i < len(segment):
        c = segment[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "\\":
            i += 1
        elif c == ">":
            rest = segment[i + 1:].lstrip(">").lstrip()
            if not rest.startswith(("&", "/dev/null")):
                return True
        i += 1
    return False


def prose_tokens(tokens):
    """Tokens that are text for the program, not a path: a quoted sentence or the value of a text option."""
    out = set()
    for i, t in enumerate(tokens):
        prev = tokens[i - 1] if i else ""
        if re.search(r"\s", t) or prev in TEXT_FLAGS or re.match(r"^--?[A-Za-z-]+=", t) and not t.startswith("-c"):
            out.add(i)
    return out


def text_program(base, args):
    """git, gh and orca orchestration take prose arguments and never run or write the paths they name,
    except through the options and subcommands that run a program."""
    if base == "git":
        sub = git_subcommand(args)[0]
        return sub not in GIT_RUNS_PROGRAMS and "-c" not in args and "--config-env" not in args \
            and not any(a.startswith(("--exec", "-x", "--run", "--tree-filter", "--index-filter")) for a in args)
    if base == "gh":
        return bool(args) and args[0] not in GH_RUNS_PROGRAMS
    return base == "orca" and args[:1] == ["orchestration"]


def read_only_viewer(base, args):
    if base in VIEWERS:
        return True
    if base == "git":
        return git_subcommand(args)[0] in GIT_READ_ONLY and not any(
            a.startswith(("--output", "-c", "--exec")) for a in args)
    if base in {"sed", "gsed"}:
        return not any(a == "-i" or a.startswith(("-i", "--in-place")) for a in args)
    if base == "find":
        return not any(a in ("-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprintf", "-fls")
                       for a in args)
    if base in SHELLS:  # bash -n only checks the syntax
        return "-n" in args and not any(re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) for a in args)
    return False


def check_risky(segment, base, args, depth):
    # The owner's approval: never run by an agent, the file never written by one. Text that only
    # names the script or the file (a commit message, a PR body, a branch, a read) is not use.
    tokens = words(segment)
    viewer = read_only_viewer(base, args)
    text = text_program(base, args)
    if SCRIPT_NAME.search(segment) and not (viewer or text):
        deny(f"{APPROVE} is the owner's own approval: an agent never runs it, however wrapped. "
             f"Ask Elon to have the owner run `{APPROVE} <scope>` in his own terminal. "
             "Reading, grepping or committing the script is fine.")
    if any(m in segment for m in APPROVAL_MARKERS):
        prose = prose_tokens(tokens)
        names_file = any(any(m in t for m in APPROVAL_MARKERS) and i not in prose for i, t in enumerate(tokens))
        if has_redirect(segment) or (not viewer and not (text and not names_file)):
            deny(f"{APPROVAL_FILE} is the owner's approval: only {APPROVE}, run by the owner in his own terminal, "
                 f"writes it. Agents may only read it. Ask the owner to run `{APPROVE} <scope>`.")

    # Which script this segment runs (directly or as a shell script argument).
    script, script_args = base, args
    if base in SHELLS or base in {"source", "."}:
        idx = next((i for i, a in enumerate(args) if not a.startswith("-")), None)
        script = os.path.basename(args[idx]) if idx is not None and "-n" not in args else ""
        script_args = args[idx + 1:] if idx is not None else []
    sha_arg = next((a for a in script_args if not a.startswith("-")), "") if script in PROMOTE_SCRIPTS | ROLLBACK_SCRIPTS else ""
    if script in APPLY_SCRIPTS:  # production SQL, generated secrets and data steps: promote <sha> --schema --apply
        sha = script_args[0] if script_args else "<sha>"
        a, why = load_approval()
        ok = re.fullmatch(r"[0-9a-f]{40}", sha) and a and a.get("scope") == "promote" and a.get("target") == sha \
            and a.get("schema") is True and a.get("apply") is True \
            and time.time() < a.get("expires_at", 0) <= time.time() + APPROVAL_TTL + 60
        if not ok:
            owner_go(f"{script} for {sha}", f"{APPROVE} promote {sha} --schema --apply",
                     why or "requires a matching literal release and schema/apply approval")


    tokens = words(segment)
    settings = tokens[:len(tokens) - len(args) - 1]  # the assignments before the program
    if base in {"export", "declare", "typeset", "readonly", "local"}:
        settings += args
    for t in settings:
        if GIT_SSH_ENV.match(t):
            deny(f"`{t.split('=', 1)[0]}` makes git run that command in place of ssh, on any host, so no approval "
                 "covers it. Run git without it; report a real need to Elon, who asks the owner.")
        if t.startswith("RSYNC_RSH="):
            check_rsh(t.split("=", 1)[1], "RSYNC_RSH")
    if any(t == SCHEMA_OVERRIDE or (t.startswith(SCHEMA_OVERRIDE + "=") and t != SCHEMA_OVERRIDE + "=0")
           for t in settings):
        sha = resolve(sha_arg) or sha_arg or "<sha>"
        ok, why = approval_for({"promote"}, lambda t: True)
        a, _ = load_approval()
        if not ok or not (a or {}).get("schema"):
            owner_go(f"{SCHEMA_OVERRIDE}=1 (a production schema push)", f"{APPROVE} promote {sha} --schema",
                     why or "the approval on file does not cover the schema")

    if script in PROMOTE_SCRIPTS:
        if re.search(r"[$`]", sha_arg):
            deny(f"Pass {script} the literal sha, so it can be matched against the owner's "
                 f"approval: {script} <sha>. The owner approves it with `{APPROVE} promote <sha>`.")
        sha = resolve(sha_arg) or sha_arg or "<sha>"
        ok, why = approval_for({"promote"}, lambda t: same_commit(sha_arg, t))
        if not ok:
            owner_go(f"Promoting {sha} to production", f"{APPROVE} promote {sha}", why)

    if script in ROLLBACK_SCRIPTS:
        if re.search(r"[$`]", sha_arg):
            deny(f"Pass {script} the literal sha, so it can be matched against the owner's "
                 f"approval: {script} <sha>. The owner approves it with `{APPROVE} rollback <sha>`.")
        sha = resolve(sha_arg) or sha_arg or "<sha>"
        ok, why = approval_for({"rollback"}, lambda t: same_commit(sha_arg, t))
        if not ok:
            owner_go(f"Rolling production back to {sha}", f"{APPROVE} rollback {sha}", why)

    global GATE_CWD
    GATE_CWD = CWD
    try:
        check_team_gates(base, args)
    except Exception:
        pass  # a bug in a team gate must not skip the production guards below (deny exits with SystemExit, not caught here)

    if base == "git":
        check_git_ssh(args)
        sub, rest, cdir = git_subcommand(args)
        if sub == "push":
            check_git_push(rest, cdir)

    if base == "gh" and args[:1] == ["api"] and any(PRODUCTION_REF.search(a) for a in args):
        method = next((args[i + 1] for i, a in enumerate(args)
                       if a in ("-X", "--method") and i + 1 < len(args)), None)
        fields = any(a in ("-f", "-F", "--field", "--raw-field", "--input") for a in args)
        if (method or ("POST" if fields else "GET")).upper() != "GET":
            deny("Moving a production branch through the GitHub API skips the deploy gate. Production moves only "
                 f"with git push or the promote script after the owner runs `{APPROVE} promote <sha>`.")

    check_hidden_hosts(segment, base, args)
    if base == "ssh":
        check_ssh(args, depth)
    if base in ("scp", "sftp"):
        opts, i = [], 0
        while i < len(args) and args[i] != "--":
            if args[i].startswith("-") and len(args[i]) > 1:
                i = take_flags(args, i, SCP_OPTS_WITH_ARG, opts)
            else:
                i += 1
        refuse_ssh_options(base, opts)
    if base == "rsync":
        i = 0
        while i < len(args) and args[i] != "--":
            a = args[i]
            if a.startswith("--rsh="):
                check_rsh(a.split("=", 1)[1], "rsync --rsh")
            elif a == "--rsh" and i + 1 < len(args):
                check_rsh(args[i + 1], "rsync --rsh")
                i += 1
            elif re.match(r"^-[^-]", a):
                opts = []
                i = take_flags(args, i, RSYNC_OPTS_WITH_ARG, opts) - 1
                for ch, value in opts:
                    if ch == "e":
                        check_rsh(value, "rsync -e")
            i += 1
    if base in ("scp", "rsync", "sftp") and any(prod_host(a) for a in args if not a.startswith("-") or "://" in a):
        ok, why = approval_for({"host"})
        if not ok:
            hosts, err = load_production_hosts()
            owner_go(f"{base} to or from the production host" + (f" (fail closed: {err})" if err else ""),
                     f"{APPROVE} host", why)
    check_backstop(segment, base, args)


# Team gates (#6936): role file commits, the grill gate on dispatch, an owning lead on remote workers.
# These stop accidents, not a determined agent: an agent can type the trailer or the comment itself,
# so the owner reads the diff of the files these gates guard.
# Known limits, left on purpose: `echo Owner-approved: x` in the command, `work:main` refspecs and
# `G=git; $G commit` are not chased. The gate is a reminder for honest mistakes, not a lock.
PROTECTED_PATHS = (
    ".claude/agents/",
    ".claude/model-routing.md",
    "docs/agents/issue-tracker.md",
    "docs/agents/triage-labels.md",
    "docs/agents/domain.md",
    "docs/agents/team-facts.md",
    "docs/agents/deploy-facts.md",
    "templates/agent-team/docs/agents/",
    "templates/agent-team/.claude/agents/",
)
OWNER_TRAILER = re.compile(r"Owner-approved:\s*\S", re.I)
# Also matches Elon's standing approval comment (~/dotfiles/templates/agent-team/docs/agents/team.md, Pre-build grill gate). The hook cannot tell a
# money, auth, schema or new UI page ticket from the comment, so that limit rests on Elon and review.
GRILL_APPROVAL = re.compile(r"(?is)(?=.*grill)(?=.*(owner.{0,60}approv|approv.{0,60}owner))")
GRILL_EXEMPT_LABELS = ("hotfix", "mechanical")
REMOTE_FLAGS = ("--on", "--environment", "--pairing-code")
GATE_CWD = None
RAW_COMMAND = ""


def gate_run(cmd, cwd):
    try:
        out = subprocess.run(cmd, cwd=cwd or GATE_CWD, capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    return out.stdout if out.returncode == 0 else None


def is_protected(path):
    return any(path.startswith(p) if p.endswith("/") else path == p for p in PROTECTED_PATHS)


def option_value(args, name):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return None


def deny_role_files(files, how):
    deny(f"{how} touches {', '.join(sorted(files))}, which only the owner approves. Add an "
         "`Owner-approved: <name> <date>` trailer to the commit message once the owner has said yes "
         "(never before), or take those files out of the change.")


def check_role_file_gate(base, args):
    cwd = None
    if base == "git":
        verb, rest, cdir = git_subcommand(args)
        cwd = os.path.join(CWD, os.path.expanduser(cdir)) if cdir else None
        if verb == "commit":
            files = set((gate_run(["git", "diff", "--cached", "--name-only"], cwd) or "").split())
            if "--all" in rest or any(a.startswith("-") and not a.startswith("--") and "a" in a for a in rest):
                files |= set((gate_run(["git", "diff", "--name-only"], cwd) or "").split())
            files = {f for f in files if is_protected(f)}
            message = RAW_COMMAND
            msg_file = option_value(rest, "-F") or option_value(rest, "--file")
            if files and msg_file:
                path = os.path.join(cwd or GATE_CWD, os.path.expanduser(msg_file))
                try:
                    if os.path.isfile(path):  # a FIFO or device could hang the read
                        with open(path) as f:
                            message += "\n" + f.read(65536)
                except Exception:
                    pass
            if files and not OWNER_TRAILER.search(message):
                deny_role_files(files, "This commit")
            return
        if verb != "push":
            return
    elif not (base == "gh" and args[:2] == ["pr", "create"]):
        return
    # Push or PR create: every commit not yet on origin/main that touches a protected path needs the trailer.
    shas = (gate_run(["git", "rev-list", "origin/main..HEAD"], cwd) or "").split()
    for sha in shas:
        files = {f for f in (gate_run(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", sha], cwd) or "").split()
                 if is_protected(f)}
        message = gate_run(["git", "show", "-s", "--format=%B", sha], cwd) or ""
        if files and not OWNER_TRAILER.search(message):
            deny_role_files(files, f"Commit {sha[:9]}")


SPEC_CAT = re.compile(r"\$\(\s*(?:cat\s+|<\s*)([^\s()`]+)\s*\)|`\s*cat\s+([^\s`]+)\s*`")
SHELL_EXPANSION = re.compile(r"\$[A-Za-z_{(]|`")


def brief_text(path):
    """A brief's text: the heredoc in this command that feeds it, else the file. None when neither has it."""
    needle = "worker-start" if path == "-" else path
    for opener, body in split_heredocs(RAW_COMMAND)[1]:
        if needle in opener:
            return body
    full = os.path.join(GATE_CWD or "", os.path.expanduser(os.path.expandvars(path)))
    try:
        if os.path.isfile(full):  # a FIFO or device could hang the read
            with open(full, errors="replace") as f:
                return f.read(65536)
    except OSError:
        pass
    return None


def worker_spec_text(args):
    """What this worker really gets: its arguments plus the briefs behind --spec-file and
    `--spec "$(cat file)"`, which reach the hook unexpanded. A brief the hook cannot read falls back
    to the whole command, so the grill check never gets skipped; that fallback can still deny falsely."""
    spec = option_value(args, "--spec") or ""
    if SHELL_EXPANSION.search(SPEC_CAT.sub("", spec)):
        return RAW_COMMAND
    paths = [m.group(1) or m.group(2) for m in SPEC_CAT.finditer(spec)]
    spec_file = option_value(args, "--spec-file")
    if spec_file:
        paths.append(spec_file)
    briefs = [brief_text(path) for path in paths]
    if None in briefs:
        return RAW_COMMAND
    return "\n".join([" ".join(args)] + briefs)


DOTFILES_REPO = "mingster/dotfiles"
DOTFILES_ISSUE = re.compile(r"(?:mingster/)?dotfiles#(\d{3,6})\b")


def check_worker_start(args, script=False):
    """script: start-cursor-worker.sh, whose --spec is a brief file and which demands --from itself."""
    if script:
        path = option_value(args, "--spec")
        brief = brief_text(path) if path else None
        if path and brief is None:
            deny(f"The brief `{path}` could not be read, so the grill check cannot tell which role it names. "
                 "Fix the path (or write the brief first) and start the worker again.")
        spec = "\n".join([" ".join(args), brief]) if brief is not None else RAW_COMMAND
    else:
        spec = worker_spec_text(args)
        if any(option_value(args, f) is not None or f in args for f in REMOTE_FLAGS) and not option_value(args, "--from"):
            deny("This worker starts on another host with no owning lead recorded, so its worker_done would reach nobody. "
                 "Add `--from <your terminal handle>` (the lead who receives worker_done) and start it again.")
    if "fullstack-dev" not in spec:
        return
    selector = option_value(args, "--worktree") or ""
    repo_args, repo_name = [], ""
    found = re.match(r"issue:(\d+)$", selector)
    if not found:
        found = DOTFILES_ISSUE.search(spec)
        if found:
            repo_args, repo_name = ["-R", DOTFILES_REPO], DOTFILES_REPO
        else:
            found = re.search(r"(?:example\.app#|issues/|#)(\d{3,6})\b", spec)
    if not found:
        deny("This build worker names no issue number, so the owner's approval of the grill results cannot be "
             "checked. Name the issue (`example-app#<n>`) in the spec, or use `--worktree issue:<n>`.")
    number = found.group(1)
    raw = gate_run(["gh", "issue", "view", number, *repo_args, "--json", "labels,body,comments"], None)
    try:
        issue = json.loads(raw)
    except Exception:
        # Fail open on purpose: a gh outage or rate limit must not halt every dispatch. The issue and PR review still catch it.
        return
    labels = " ".join(l.get("name", "") for l in issue.get("labels") or []).lower()
    texts = [issue.get("body") or ""] + [c.get("body") or "" for c in issue.get("comments") or []]
    if any(x in labels for x in GRILL_EXEMPT_LABELS) or any("elon take over" in t.lower() for t in texts[1:]):
        return
    if not any(GRILL_APPROVAL.search(t) for t in texts[1:]):
        deny(f"Missing: a comment on {repo_name}#{number} naming the owner's approval of the grill results "
             "(~/dotfiles/templates/agent-team/docs/agents/team.md, Pre-build grill gate). Get the owner's approval, record it on the issue, "
             "then dispatch. With no money, auth, schema change or new UI page, Elon records "
             "`Elon grill approval <date>, owner standing rule 2026-11-04` instead. "
             "Hotfix, mechanical text only and \"Elon take over\" work are exempt.")


def check_team_gates(base, args):
    check_role_file_gate(base, args)
    if base == "orca" and args[:2] == ["orchestration", "worker-start"]:
        check_worker_start(args)
    elif base == "start-cursor-worker.sh":
        check_worker_start(args, script=True)


def check_edit(tool, path):
    if not path:
        return
    real = os.path.realpath(os.path.expanduser(path))
    root = os.path.realpath(APPROVAL_DIR)
    if real == root or real.startswith(root + os.sep):
        deny(f"{tool} on {path} is blocked: {APPROVAL_FILE} is the owner's approval and only {APPROVE}, run by "
             f"the owner in his own terminal, writes it. Ask the owner to run `{APPROVE} <scope>`.")


BACKGROUND_WAIT = re.compile(r"orchestration\s+check\b[^;|]*--wait[^;|]*?(?<!&)&\s*(?:$|;|\n)")


def check_background_wait(command):
    if BACKGROUND_WAIT.search(command):
        deny("An `orca orchestration check --wait` started with a trailing shell `&` never wakes this session, so deliveries sit "
             "unread. Run it as its own Bash call with run_in_background: true, and re-arm it after each --ack.")


def main():
    global CWD
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    tool = data.get("tool_name")
    tool_input = data.get("tool_input") or {}
    CWD = data.get("cwd") or os.getcwd()
    if tool in EDIT_TOOLS:
        check_edit(tool, tool_input.get("file_path") or tool_input.get("notebook_path") or "")
        return
    if tool != "Bash":
        return
    command = tool_input.get("command") or ""
    global RAW_COMMAND
    RAW_COMMAND = command
    check_background_wait(command)
    try:
        check_command(command)
    except SystemExit:
        raise
    except Exception:
        pass

if __name__ == "__main__":
    main()
