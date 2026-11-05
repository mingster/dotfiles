#!/usr/bin/env python3
"""PreToolUse guard for Bash, from the shared agent team template.

Blocks these kinds of accident:

1. Running a raw deploy script that only the pipeline wrapper may run. The check
   looks at the program a command segment executes, so `git add bin/deploy-win.sh`,
   `grep x bin/deploy-win.sh` or editing the script are allowed; `./bin/deploy-win.sh`,
   `bash bin/deploy-win.sh` or `FOO=1 sh -c "bin/deploy-win.sh"` are not.
2. Printing a secret into the session log: reading `.env` files, `secrets/`, key
   files, or echoing secret environment variables. Use `.claude/bin/env-peek.py`
   to check a value without printing it.
3. A PayPal API call other than GET and the token request.
4. Running tests, type checks or builds outside the shared heavy job gate.
   Gate wrappers execute their children outside PreToolUse, so no environment
   escape hatch is needed.

Anything it cannot parse is let through: the deny rules in settings.json are the
backstop. Exit 0 always; a block is a JSON permissionDecision of "deny".
"""
import json
import os
import re
import shlex
import subprocess
import sys

# Scripts only the deploy wrapper may run (none by default; list the project's raw deploy scripts here).
BLOCKED_SCRIPTS: set[str] = set()

SECRET_FILE = re.compile(
    r"(^|[/=])("
    r"\.env(\.(?!example$|sample$|template$|dist$)[A-Za-z0-9_.-]+)?"
    r"|[^/\s]*\.(p8|pem|p12|pfx|key|keystore|jks)"
    r"|secrets/[^\s]*"
    r"|secrets"
    r"|id_(rsa|ed25519|ecdsa)"
    r")$"
)
# Any Bash command that reads under the secrets dir is denied (#4926). SECRETS_DIR matches the
# project's secrets path; set SIGN_IN_SCRIPT to the one script allowed to read a secret file for the
# agent (it reads the file itself, so the path never appears in a command), or None for no exception.
SECRETS_DIR = re.compile(r"(^|[/\s='\"<(])secrets(/|$|[\s'\")])")
SECRETS_WRITE_REDIRECT = re.compile(r">>?\s*\S*secrets/\S*")
SECRETS_NONREAD = {"ls", "stat", "test", "[", "[[", "mkdir", "chmod", "chown", "touch", "rm", "rmdir", "pwd"}
SECRETS_COPIERS = {"cp", "mv", "ln", "rsync", "scp", "install"}
SIGN_IN_SCRIPT = None
# Compiled patterns for commands that may take a secret file as stdin and nothing else. The whole
# segment must match. Empty by default.
SECRETS_STDIN_OK = []
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


def words(segment):
    try:
        return shlex.split(segment, comments=True)
    except ValueError:
        return segment.split()


def program_and_args(tokens):
    """Skip env assignments and wrappers; return (program, args)."""
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if ENV_ASSIGN.match(t):
            i += 1
        elif t == "env":
            i += 1
            while i < len(tokens) and (tokens[i].startswith("-") or ENV_ASSIGN.match(tokens[i])):
                i += 1
            if i == len(tokens):
                return "env", []
        elif t in WRAPPERS:
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


def check_secrets_dir(segment, base, args):
    """Deny a segment that reads the secrets dir: readers, interpreters, redirects, copies out, cd."""
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
    exception = (f" The only exception is `{SIGN_IN_SCRIPT}`, which reads the file itself without printing it."
                 if SIGN_IN_SCRIPT else "")
    deny(f"{base} would read a file under the secrets dir into the session log. Agents never read the "
         f"secrets dir.{exception} Anything else, ask Elon.")


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


# Team gates (#6936): role file commits, the grill gate on dispatch, an owning lead on remote workers.
# These stop accidents, not a determined agent: an agent can type the trailer or the comment itself,
# so the owner reads the diff of the files these gates guard.
PROTECTED_PATHS = (".claude/agents/", "docs/agents/", ".claude/model-routing.md")
OWNER_TRAILER = re.compile(r"Owner-approved:\s*\S", re.I)
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


def git_verb(args):
    i = 0
    while i < len(args):
        if args[i] in ("-C", "-c"):
            i += 2
        elif args[i].startswith("-"):
            i += 1
        else:
            return args[i], args[i + 1:]
    return None, []


def deny_role_files(files, how):
    deny(f"{how} touches {', '.join(sorted(files))}, which only the owner approves. Add an "
         "`Owner-approved: <name> <date>` trailer to the commit message once the owner has said yes "
         "(never before), or take those files out of the change.")


def check_role_file_gate(base, args):
    if base == "git":
        verb, rest = git_verb(args)
        if verb == "commit":
            files = set((gate_run(["git", "diff", "--cached", "--name-only"], None) or "").split())
            if "--all" in rest or any(a.startswith("-") and not a.startswith("--") and "a" in a for a in rest):
                files |= set((gate_run(["git", "diff", "--name-only"], None) or "").split())
            files = {f for f in files if is_protected(f)}
            if files and not OWNER_TRAILER.search(RAW_COMMAND):
                deny_role_files(files, "This commit")
            return
        if verb != "push":
            return
    elif not (base == "gh" and args[:2] == ["pr", "create"]):
        return
    # Push or PR create: every commit not yet on origin/main that touches a protected path needs the trailer.
    shas = (gate_run(["git", "rev-list", "origin/main..HEAD"], None) or "").split()
    for sha in shas:
        files = {f for f in (gate_run(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", sha], None) or "").split()
                 if is_protected(f)}
        message = gate_run(["git", "show", "-s", "--format=%B", sha], None) or ""
        if files and not OWNER_TRAILER.search(message):
            deny_role_files(files, f"Commit {sha[:9]}")


# `dotfiles#<n>` names an issue in the dotfiles repo. Set DOTFILES_REPO to `<owner>/dotfiles` for this project.
DOTFILES_REPO = os.environ.get("DOTFILES_REPO") or "OWNER/dotfiles"
DOTFILES_ISSUE = re.compile(r"(?:[\w.-]+/)?dotfiles#(\d{3,6})\b")


def brief_text(path):
    """A brief file's text, or None when it cannot be read."""
    full = os.path.join(GATE_CWD or "", os.path.expanduser(os.path.expandvars(path)))
    try:
        if os.path.isfile(full):  # a FIFO or device could hang the read
            with open(full, errors="replace") as f:
                return f.read(65536)
    except OSError:
        pass
    return None


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
        spec = RAW_COMMAND
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
            found = re.search(r"(?:issues/|#)(\d{3,6})\b", spec)
    if not found:
        deny("This build worker names no issue number, so the owner's approval of the grill results cannot be "
             "checked. Name the issue (`#<n>`) in the spec, or use `--worktree issue:<n>`.")
    number = found.group(1)
    raw = gate_run(["gh", "issue", "view", number, *repo_args, "--json", "labels,body,comments"], None)
    try:
        issue = json.loads(raw)
    except Exception:
        return  # gh is down or the issue is unreadable: the gate cannot judge, so it lets the command through
    labels = " ".join(l.get("name", "") for l in issue.get("labels") or []).lower()
    texts = [issue.get("body") or ""] + [c.get("body") or "" for c in issue.get("comments") or []]
    if any(x in labels for x in GRILL_EXEMPT_LABELS) or any("elon take over" in t.lower() for t in texts[1:]):
        return
    if not any(GRILL_APPROVAL.search(t) for t in texts[1:]):
        deny(f"Missing: a comment on {repo_name}#{number} naming the owner's approval of the grill results "
             "(docs/agents/team.md, Pre-build grill gate). Get the owner's approval, record it on the issue, "
             "then dispatch. Hotfix, mechanical text only and \"Elon take over\" work are exempt.")


def check_team_gates(base, args):
    check_role_file_gate(base, args)
    if base == "orca" and args[:2] == ["orchestration", "worker-start"]:
        check_worker_start(args)
    elif base == "start-cursor-worker.sh":
        check_worker_start(args, script=True)


def check_segment(segment, depth=0):
    if depth > 3:
        deny("Shell command nesting exceeds the guard inspection limit. Split the command into separate calls.")
    prog, args = program_and_args(words(segment))
    if not prog:
        return
    base = os.path.basename(prog)
    check_pattern_kill(segment, base, args)
    check_team_gates(base, args)

    # 4. Heavy jobs must acquire the shared machine budget.
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
    weight = None
    if heavy_base in {"tsc", "playwright"}:
        weight = 2 if heavy_base == "playwright" else 1
    elif heavy_base == "next" and heavy_args[:1] == ["build"]:
        weight = 2
    elif heavy_base == "bun":
        if heavy_args[:1] == ["test"]:
            # One *.test.ts(x) file is a cheap red run; a second path, a directory or a bare run stays gated.
            operands = [a for a in heavy_args[1:] if not a.startswith("-")]
            if not (len(operands) == 1 and re.search(r"\.test\.tsx?$", operands[0])):
                weight = 1
        elif heavy_args[:2] in (["run", "test"], ["run", "tsc"]):
            weight = 1
        elif heavy_args[:2] == ["run", "build"] or (
                len(heavy_args) > 1 and heavy_args[0] == "run" and heavy_args[1].startswith("test:regression")):
            weight = 2
    elif heavy_base in {"bunx", "npx"}:
        if heavy_args[:1] == ["tsc"]:
            weight = 1
        elif heavy_args[:1] == ["playwright"] or heavy_args[:2] == ["next", "build"]:
            weight = 2
    if weight:
        deny("Heavy jobs must run through the shared machine gate. "
             f"Run: ~/dotfiles/script/heavy-gate.sh --weight {weight} -- {segment}")

    # 1. Raw deploy scripts.
    if base in BLOCKED_SCRIPTS:
        deny(f"{base} runs only inside the deploy pipeline (the deploy wrapper through /deploy). "
             "Reading, grepping, editing or committing the file is fine; running it is not.")
    if base in SHELLS or base in {"source", "."}:
        if "-c" in args:
            idx = args.index("-c")
            if idx + 1 < len(args):
                script = args[idx + 1]
                for text in [script, *substitutions(script)]:
                    for seg in segments(text):
                        check_segment(seg, depth + 1)
        else:
            script = next((a for a in args if not a.startswith("-")), None)
            if script and os.path.basename(script) in BLOCKED_SCRIPTS:
                deny(f"{os.path.basename(script)} runs only inside the deploy pipeline (the deploy wrapper).")

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
             "to compare values. Copying the file (cp) is fine.")
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


BACKGROUND_WAIT = re.compile(r"orchestration\s+check\b[^;|]*--wait[^;|]*?(?<!&)&\s*(?:$|;|\n)")


def check_background_wait(command):
    if BACKGROUND_WAIT.search(command):
        deny("An `orca orchestration check --wait` started with a trailing shell `&` never wakes this session, so deliveries sit "
             "unread. Run it as its own Bash call with run_in_background: true, and re-arm it after each --ack.")


def substitutions(command):
    """Inspect active expansions; single-quoted and escaped text is data."""
    out, quote, i = [], None, 0
    while i < len(command):
        c = command[i]
        if quote == "'":
            if c == "'":
                quote = None
        elif c == "\\" and i + 1 < len(command):
            i += 1
        elif c == "'" and quote is None:
            quote = "'"
        elif c == '"':
            quote = None if quote == '"' else '"'
        elif c == "`":
            end = i + 1
            while end < len(command):
                if command[end] == "\\" and end + 1 < len(command):
                    end += 2
                    continue
                if command[end] == "`":
                    break
                end += 1
            body = command[i + 1:end]
            out.append(body)
            out.extend(substitutions(body))
            i = end
        elif command.startswith("$(", i):
            # Retain the existing conservative parenthesis scan for active
            # substitutions; do not relax nested/ambiguous shell syntax here.
            depth, start, end = 1, i + 2, i + 2
            while end < len(command) and depth:
                if command.startswith("$(", end):
                    depth += 1
                    end += 2
                    continue
                if command[end] == ")":
                    depth -= 1
                end += 1
            body = command[start:end - 1] if not depth else command[start:]
            out.append(body)
            out.extend(substitutions(body))
            i = end - 1
        i += 1
    return out


REPORT_HEREDOC = re.compile(
    r"^\s*cat\s+>\s*[A-Za-z0-9_./-]+\s+<<(-?)\s*(['\"])([A-Za-z_][A-Za-z0-9_]*)\2\s*$"
)


def report_command_text(command):
    """Remove literal data only for a standalone quoted cat-to-file heredoc.

    Only a leading report (or consecutive leading reports) has a proven
    standalone header. Once other command text appears, retain everything:
    a later matching line may belong to a multiline quote or substitution.
    Keep headers and following commands, so executable text is checked.
    """
    lines = command.splitlines(keepends=True)
    out, i = [], 0
    while i < len(lines):
        match = REPORT_HEREDOC.fullmatch(lines[i].rstrip("\r\n"))
        out.append(lines[i])
        i += 1
        if not match:
            if lines[i - 1].strip():
                out.extend(lines[i:])
                break
            continue
        end = i
        while end < len(lines):
            delimiter = lines[end].rstrip("\r\n")
            if match[1]:
                delimiter = delimiter.lstrip("\t")
            if delimiter == match[3]:
                break
            end += 1
        if end < len(lines):
            out.append("\n")
            i = end + 1
    return "".join(out)

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if data.get("tool_name") != "Bash":
        return
    command = (data.get("tool_input") or {}).get("command") or ""
    global GATE_CWD, RAW_COMMAND
    GATE_CWD, RAW_COMMAND = data.get("cwd") or os.getcwd(), command
    check_background_wait(command)
    try:
        command = report_command_text(command)
        for text in [command, *substitutions(command)]:
            for seg in segments(text):
                check_segment(seg)
    except SystemExit:
        raise
    except Exception:
        return


if __name__ == "__main__":
    main()
