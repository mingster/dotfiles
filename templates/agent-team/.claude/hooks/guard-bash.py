#!/usr/bin/env python3
"""PreToolUse guard for Bash and file edit tools, from the shared agent team template.

Blocks these kinds of accident:

1. Running a raw deploy script that only the pipeline wrapper may run. The check
   looks at the program a command segment executes, so `git add bin/deploy-win.sh`,
   `grep x bin/deploy-win.sh` or editing the script are allowed; `./bin/deploy-win.sh`,
   `bash bin/deploy-win.sh` or `FOO=1 sh -c "bin/deploy-win.sh"` are not.
2. Printing a secret into the session log: reading `.env` files, `secrets/`, key
   files, or echoing secret environment variables. Use `.claude/bin/env-peek.py`
   to check a value without printing it.
3. A PayPal API call other than GET and the token request.
4. Risky production commands without the owner's go (`check_risky`): a push to a
   configured stage or production branch, any force push, promote/rollback/apply
   scripts, schema overrides, and ssh, scp, sftp or rsync to a configured
   production host beyond a read-only allowlist. Project values are loaded from
   `<project>/.claude/hooks/guard-config.json` (defaulting to empty when absent).
5. Copying, linking, or writing `.env` / `.env.*` files in linked agent worktrees
   (`check_worktree_env`), unless listed in `worktree_env_allow`.
6. Editing template-managed agent team files directly inside an adopted project
   outside `dotfiles` when `AGENT_TEAM_SYNC` is not `1`.
7. Running Playwright or production builds outside the shared heavy job gate, or type checks outside measure mode.
   Gate wrappers execute their children outside PreToolUse, so no environment
   escape hatch is needed.

Anything it cannot parse is let through: the deny rules in settings.json are the
backstop. Exit 0 always; a block is a JSON permissionDecision of "deny".
"""
import fnmatch
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

# Project configuration loaded at startup from <project>/.claude/hooks/guard-config.json.
BLOCKED_SCRIPTS: set[str] = set()
PRODUCTION_HOSTS: set[str] = set()
BACKSTOP_HOSTS: set[str] = set()
PRODUCTION_HOSTS_ERROR: str | None = None
STAGE_BRANCHES: list[str] = []
STAGE_BRANCH_COMPONENTS: dict[str, str] = {}
PROMOTE_RULES: dict[str, dict] = {
    "deploy-stage.sh": {"free_stages": {"local", "staging", "status"}, "component": 1, "sha": 2}
}
ROLLBACK_SCRIPTS: set[str] = {"rollback-production.sh"}
APPLY_SCRIPTS: set[str] = {"apply-production-sql.sh", "set-production-secret.sh", "run-production-data-step.sh"}
SCHEMA_OVERRIDE: str = "SCHEMA_APPROVED"
APPROVAL_NAMESPACE: str = ""
APPROVAL_FILE_OVERRIDE: str = ""
SIGN_IN_SCRIPT: str | None = None
SECRETS_STDIN_OK: list[re.Pattern] = []
WORKTREE_ENV_ALLOW: list[str] = []
HOST_DEPLOY_PATTERNS: dict[str, list[re.Pattern]] = {}
CONFIG_LOADED_FROM: str | None = None

DEFAULT_SECRETS_DIR_PATTERN = r"(?:^|[/\s='\"<(])secrets(?:/|$|[\s'\"\)])"
SECRETS_DIR = re.compile(DEFAULT_SECRETS_DIR_PATTERN)
SECRETS_WRITE_REDIRECT = re.compile(r">>?\s*\S*secrets/\S*")

SECRET_FILE = re.compile(
    r"(^|[/=])("
    r"\.env(\.(?!example$|sample$|template$|dist$)[A-Za-z0-9_.-]+)?"
    r"|(?<=/)[^/\s]+\.env"
    r"|[^/\s]*\.(p8|pem|p12|pfx|key|keystore|jks)"
    r"|secrets/[^\s]*"
    r"|secrets"
    r"|id_(rsa|ed25519|ecdsa)"
    r")$"
)
SECRETS_NONREAD = {"ls", "stat", "test", "[", "[[", "mkdir", "chmod", "chown", "touch", "rm", "rmdir", "pwd"}
SECRETS_COPIERS = {"cp", "mv", "ln", "rsync", "scp", "install"}
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

APPROVAL_TTL = 30 * 60
APPROVE = "bin/owner-approve.sh"
EDIT_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
VIEWERS = {"cat", "less", "more", "head", "tail", "bat", "nl", "wc", "ls", "stat", "file", "diff",
           "jq", "test", "[", "shellcheck"} | GREPS
SCRIPT_NAME = re.compile(r"owner-approve(?![A-Za-z0-9_-])")
GIT_RUNS_PROGRAMS = {"filter-branch", "rebase", "bisect", "submodule", "difftool", "mergetool", "config", "alias"}
GIT_READ_ONLY = {"log", "diff", "show", "blame", "status", "grep", "ls-files", "cat-file", "shortlog"}
GH_RUNS_PROGRAMS = {"alias", "extension", "ext"}
TEXT_FLAGS = {"-m", "--message", "-b", "--body", "-t", "--title", "--subject", "--spec", "--question",
              "--reason", "--comment", "--description", "-f", "-F", "--field", "--raw-field"}
SSH_OPTS_WITH_ARG = set("BbcDEeFIiJLlmOoPpQRSWw")
SCP_OPTS_WITH_ARG = set("cDFiJlLoPSX")
SFTP_OPTS_WITH_ARG = set("BbDcFiJlLoPRSXs")
RSYNC_OPTS_WITH_ARG = set("eBfMT@")
SSH_ALLOWED_OPTIONS = {"batchmode": r"yes|no", "connecttimeout": r"[0-9]+",
                       "serveraliveinterval": r"[0-9]+", "serveralivecountmax": r"[0-9]+"}
SSH_REFUSED_FLAGS = {"ssh": set("FJS"), "scp": set("FJSD"), "sftp": set("FJSD")}
GIT_SSH_ENV = re.compile(r"^(GIT_SSH|GIT_SSH_COMMAND|GIT_PROXY_COMMAND)=")

_P, _U, _N = r"/[A-Za-z0-9._/@+-]*", r"[A-Za-z0-9@._-]+", r"[0-9]+"
# guard-config.json `remote_read_only` replaces this list.
DEFAULT_REMOTE_READ_ONLY = REMOTE_READ_ONLY = [re.compile(p) for p in (
    "true", "uptime", "free( -[hm])?", "df( -h)?", "cat /etc/os-release", "pg_lsclusters",
    "pm2 (status|ls|list|jlist)", f"pm2 logs {_U} --nostream( --lines {_N})?",
    f"systemctl status {_U}", f"journalctl -u {_U} -n {_N} --no-pager",
    f"readlink {_P}", f"ls -la {_P}", f"tail -n {_N} {_P}", f"test -s {_P}",
    r'pgrep -fa "[A-Za-z0-9 ._/|\[\]-]+"',
    f"curl -fsS http://localhost(:{_N})?{_P}",
    f"tail -n {_N}", f"tail -{_N}", f"head -n {_N}", "grep (-[iv] )?[A-Za-z0-9._-]+", "wc -l",
)]

CANONICAL_ROLES = {
    "elon.md",
    "architect-pm.md",
    "fullstack-dev.md",
    "qa-sdet.md",
    "secops-finops.md",
    "release-manager.md",
    "sales-marketing.md",
    "support-csm.md",
}
TEMPLATE_HOOKS = {"guard-bash.py", "strikes.py", "worker-budget.py", "session-start.md"}
TEMPLATE_BINS = {"env-peek.py", "state-of-play.sh"}
TEMPLATE_DOCS = {
    "team.md",
    "elon-dispatch.md",
    "release-manager-work.md",
    "coordinator-operations.md",
    "engineering-integration.md",
    "architect-pm-work.md",
    "qa-sdet-execution.md",
    "persistent-memory-protocol.md",
    "pstack-attribution.md",
    "process-review.md",
}
TIER2_SKILLS = {"ceo", "crew", "deploy", "elon", "poteto-mode", "staging-review", "team-audit", "tl"}

GATE_CWD = None
RAW_COMMAND = ""


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def find_guard_config(start_dir):
    env_cfg = os.environ.get("GUARD_CONFIG")
    if env_cfg and os.path.isfile(env_cfg):
        return env_cfg
    cur = os.path.abspath(start_dir or os.getcwd())
    while True:
        candidate = os.path.join(cur, ".claude", "hooks", "guard-config.json")
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return None


def load_guard_config(start_dir):
    global BLOCKED_SCRIPTS, PRODUCTION_HOSTS, PRODUCTION_HOSTS_ERROR, BACKSTOP_HOSTS
    global STAGE_BRANCHES, STAGE_BRANCH_COMPONENTS, PROMOTE_RULES, ROLLBACK_SCRIPTS
    global APPLY_SCRIPTS, SCHEMA_OVERRIDE, APPROVAL_NAMESPACE, APPROVAL_FILE_OVERRIDE
    global SIGN_IN_SCRIPT, SECRETS_STDIN_OK, WORKTREE_ENV_ALLOW, SECRETS_DIR, SECRETS_WRITE_REDIRECT
    global CONFIG_LOADED_FROM, HOST_DEPLOY_PATTERNS, REMOTE_READ_ONLY

    BLOCKED_SCRIPTS = set()
    PRODUCTION_HOSTS = set()
    BACKSTOP_HOSTS = set()
    PRODUCTION_HOSTS_ERROR = None
    STAGE_BRANCHES = []
    STAGE_BRANCH_COMPONENTS = {}
    PROMOTE_RULES = {
        "deploy-stage.sh": {"free_stages": {"local", "staging", "status"}, "component": 1, "sha": 2}
    }
    ROLLBACK_SCRIPTS = {"rollback-production.sh"}
    APPLY_SCRIPTS = {"apply-production-sql.sh", "set-production-secret.sh", "run-production-data-step.sh"}
    SCHEMA_OVERRIDE = "SCHEMA_APPROVED"
    APPROVAL_NAMESPACE = ""
    APPROVAL_FILE_OVERRIDE = os.environ.get("GUARD_APPROVAL_FILE") or ""
    SIGN_IN_SCRIPT = None
    SECRETS_STDIN_OK = []
    WORKTREE_ENV_ALLOW = []
    HOST_DEPLOY_PATTERNS = {}
    REMOTE_READ_ONLY = DEFAULT_REMOTE_READ_ONLY
    SECRETS_DIR = re.compile(DEFAULT_SECRETS_DIR_PATTERN)
    SECRETS_WRITE_REDIRECT = re.compile(r">>?\s*\S*secrets/\S*")
    CONFIG_LOADED_FROM = None

    cfg_path = find_guard_config(start_dir)
    cfg = {}
    if cfg_path:
        CONFIG_LOADED_FROM = os.path.dirname(os.path.dirname(os.path.dirname(cfg_path)))
        try:
            with open(cfg_path, encoding="utf-8") as f:
                loaded = json.load(f)
            if isinstance(loaded, dict):
                cfg = loaded
            else:
                print(f"guard-bash.py: {cfg_path}: expected JSON object, got {type(loaded).__name__}; ignoring", file=sys.stderr)
        except Exception as e:
            PRODUCTION_HOSTS_ERROR = f"{cfg_path} is unreadable ({type(e).__name__})"
            print(f"guard-bash.py: {cfg_path}: {type(e).__name__}; ignoring", file=sys.stderr)

    def cfg_expect(key, expected_types, type_label):
        if key not in cfg or cfg[key] is None:
            return None
        val = cfg[key]
        if not isinstance(val, expected_types):
            print(f"guard-bash.py: {cfg_path}: ignoring '{key}' (expected {type_label}, got {type(val).__name__})", file=sys.stderr)
            return None
        return val

    hosts_env = os.environ.get("GUARD_PRODUCTION_HOSTS")
    if hosts_env:
        try:
            with open(hosts_env, encoding="utf-8") as f:
                for ln in f.read().splitlines():
                    h = ln.split("#", 1)[0].strip().lower()
                    if h:
                        PRODUCTION_HOSTS.add(h)
        except Exception as e:
            PRODUCTION_HOSTS_ERROR = f"{hosts_env} is missing or unreadable ({type(e).__name__})"

    for h in cfg_expect("production_hosts", list, "list") or []:
        if isinstance(h, str) and h.strip():
            PRODUCTION_HOSTS.add(h.strip().lower())

    # Hosts that are not ssh destinations the guard reads as production, but that a command naming them
    # (the backstop below) still needs `host` for, such as an artifact store the deploy pulls from.
    for h in cfg_expect("backstop_hosts", list, "list") or []:
        if isinstance(h, str) and h.strip():
            BACKSTOP_HOSTS.add(h.strip().lower())

    for key in ("stage_branches", "production_branches"):
        val = cfg_expect(key, (list, dict), "list or object")
        if isinstance(val, dict):
            for br, comp in val.items():
                if br not in STAGE_BRANCHES:
                    STAGE_BRANCHES.append(br)
                if isinstance(comp, str):
                    STAGE_BRANCH_COMPONENTS[br] = comp
        elif isinstance(val, list):
            for br in val:
                if isinstance(br, str) and br.strip() and br.strip() not in STAGE_BRANCHES:
                    STAGE_BRANCHES.append(br.strip())

    raw_promote = cfg_expect("promote_scripts", (list, dict), "list or object")
    if isinstance(raw_promote, dict):
        for name, rule in raw_promote.items():
            base = os.path.basename(name)
            if isinstance(rule, dict):
                raw_free = rule.get("free_stages")
                free_stages = {s for s in raw_free if isinstance(s, str)} if isinstance(raw_free, list) else set()
                PROMOTE_RULES[base] = {
                    "free_stages": free_stages,
                    "component": rule.get("component"),
                    "sha": rule.get("sha", 0),
                }
            else:
                PROMOTE_RULES[base] = {"free_stages": set(), "component": None, "sha": 0}
    elif isinstance(raw_promote, list):
        for item in raw_promote:
            if isinstance(item, str) and item.strip():
                base = os.path.basename(item.strip())
                if base not in PROMOTE_RULES:
                    PROMOTE_RULES[base] = {"free_stages": set(), "component": None, "sha": 0}

    for item in cfg_expect("rollback_scripts", list, "list") or []:
        if isinstance(item, str) and item.strip():
            ROLLBACK_SCRIPTS.add(os.path.basename(item.strip()))

    for item in cfg_expect("apply_scripts", list, "list") or []:
        if isinstance(item, str) and item.strip():
            APPLY_SCRIPTS.add(os.path.basename(item.strip()))

    raw_schema = cfg_expect("schema_override", str, "string")
    if raw_schema and raw_schema.strip():
        SCHEMA_OVERRIDE = raw_schema.strip()

    raw_ns = cfg_expect("approval_namespace", str, "string")
    if raw_ns and raw_ns.strip():
        APPROVAL_NAMESPACE = raw_ns.strip()

    raw_app_file = cfg_expect("approval_file", str, "string")
    if raw_app_file and raw_app_file.strip():
        APPROVAL_FILE_OVERRIDE = os.path.expanduser(raw_app_file.strip())

    for item in cfg_expect("blocked_scripts", list, "list") or []:
        if isinstance(item, str) and item.strip():
            BLOCKED_SCRIPTS.add(os.path.basename(item.strip()))

    raw_secrets_dir = cfg_expect("secrets_dir", (str, list), "string or list")
    extra_dirs = []
    if isinstance(raw_secrets_dir, str) and raw_secrets_dir.strip():
        extra_dirs.append(raw_secrets_dir.strip().strip("/"))
    elif isinstance(raw_secrets_dir, list):
        for d in raw_secrets_dir:
            if isinstance(d, str) and d.strip():
                extra_dirs.append(d.strip().strip("/"))
    if extra_dirs:
        escaped = [re.escape(d) for d in extra_dirs]
        dir_union = "|".join([DEFAULT_SECRETS_DIR_PATTERN] + [rf"(?:^|[/\s='\"<(])(?:{e})(?:/|$|[\s'\"\)])" for e in escaped])
        SECRETS_DIR = re.compile(dir_union)
        redir_union = "|".join(["secrets/"] + [rf"{e}/?" for e in escaped])
        SECRETS_WRITE_REDIRECT = re.compile(rf">>?\s*\S*(?:{redir_union})\S*")

    raw_sign_in = cfg_expect("sign_in_script", str, "string")
    if raw_sign_in and raw_sign_in.strip():
        SIGN_IN_SCRIPT = raw_sign_in.strip()

    for pat in cfg_expect("secrets_stdin_ok", list, "list") or []:
        if isinstance(pat, str) and pat.strip():
            try:
                SECRETS_STDIN_OK.append(re.compile(pat))
            except re.error:
                pass

    for item in cfg_expect("worktree_env_allow", list, "list") or []:
        if isinstance(item, str) and item.strip():
            WORKTREE_ENV_ALLOW.append(item.strip())

    # ssh target -> the exact remote commands the promote and rollback scripts send. SHA40 stands for the
    # release sha: such a command needs `promote <sha>` or `rollback <sha>` for that sha.
    for target, cmds in (cfg_expect("host_deploy_commands", dict, "object") or {}).items():
        if isinstance(cmds, list):
            HOST_DEPLOY_PATTERNS[target.strip().lower()] = [
                re.compile(re.escape(c).replace("SHA40", "(?P<sha>[0-9a-f]{40})"))
                for c in cmds if isinstance(c, str) and c.strip()]

    raw_read_only = cfg_expect("remote_read_only", list, "list")
    if raw_read_only is not None:
        REMOTE_READ_ONLY = []
        for pat in raw_read_only:
            if isinstance(pat, str) and pat.strip():
                try:
                    REMOTE_READ_ONLY.append(re.compile(pat))
                except re.error:
                    pass


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


def is_sign_in_invocation(prog, args):
    if not SIGN_IN_SCRIPT:
        return False
    target_base = os.path.basename(SIGN_IN_SCRIPT)
    base = os.path.basename(prog or "")
    if prog == SIGN_IN_SCRIPT or base == target_base:
        script_args = args
    elif base in SHELLS or base in {"source", "."}:
        idx = next((i for i, a in enumerate(args) if not a.startswith("-")), None)
        if idx is None:
            return False
        script = args[idx]
        if script != SIGN_IN_SCRIPT and os.path.basename(script) != target_base:
            return False
        script_args = args[idx + 1:]
    else:
        return False
    return not any(SECRETS_DIR.search(a) or SECRET_FILE.search(a) for a in script_args)


def check_secrets_dir(segment, base, args, prog=None):
    """Deny a segment that reads the secrets dir: readers, interpreters, redirects, copies out, cd."""
    text = SECRETS_WRITE_REDIRECT.sub("", segment)
    if not SECRETS_DIR.search(text) or base in SECRETS_NONREAD:
        return
    if any(p.fullmatch(segment.strip()) for p in SECRETS_STDIN_OK):
        return
    if is_sign_in_invocation(prog or base, args):
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


# ---------------------------------------------------------------- Worktree .env protection

def is_linked_worktree(path):
    folded = path.lower()
    if "/orca/workspaces/" in folded or "/.claude/worktrees/" in folded:
        return True
    cur = os.path.abspath(path)
    while True:
        git_marker = os.path.join(cur, ".git")
        if os.path.isfile(git_marker):
            return True
        if os.path.isdir(git_marker):
            return False
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return False


def is_protected_env_name(path_str):
    base = os.path.basename(path_str.rstrip("/"))
    low = base.lower()
    if low in {".env.example", ".env.sample", ".env.template", ".env.dist"}:
        return False
    if not (low == ".env" or low.startswith(".env.")):
        return False
    norm = re.sub(r"^(?:\./)+", "", path_str.replace("\\", "/"))
    for allowed in WORKTREE_ENV_ALLOW:
        al = re.sub(r"^(?:\./)+", "", allowed.lower())
        if low == al or norm.lower() == al or norm.lower().endswith("/" + al) or fnmatch.fnmatchcase(low, al):
            return False
    return True


def deny_worktree_env():
    deny("Copying, linking, or writing `.env` / `.env.local` in an agent worktree is blocked. "
         "Worktrees must use placeholder configuration or an entry in `.claude/hooks/guard-config.json` (`worktree_env_allow`).")


def extract_redirect_targets(segment):
    targets = []
    quote, i = None, 0
    while i < len(segment):
        c = segment[i]
        if quote:
            if c == "\\" and quote == '"' and i + 1 < len(segment):
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "\\" and i + 1 < len(segment):
            i += 1
        elif c == ">":
            i += 1
            if i < len(segment) and segment[i] == ">":
                i += 1
            while i < len(segment) and segment[i] in " \t":
                i += 1
            if i < len(segment) and segment[i] != "&":
                start = i
                q2 = None
                while i < len(segment):
                    ch = segment[i]
                    if q2:
                        if ch == q2:
                            q2 = None
                    elif ch in "'\"":
                        q2 = ch
                    elif ch in " \t\n;&|()<>":
                        break
                    i += 1
                tok = segment[start:i].strip("'\"")
                if tok and tok != "/dev/null":
                    targets.append(tok)
                continue
        i += 1
    return targets


def check_worktree_env(segment, base, args, cwd=None):
    eff_cwd = cwd or GATE_CWD or os.getcwd()
    # Check shell redirects (> .env, >> .env.local) and tee in linked worktrees
    for redir in extract_redirect_targets(segment):
        if is_protected_env_name(redir):
            full = os.path.normpath(os.path.join(eff_cwd, os.path.expanduser(redir)))
            if is_linked_worktree(full) or is_linked_worktree(eff_cwd) or re.search(r"[$`*?]", full):
                deny_worktree_env()
    if base == "tee":
        for a in args:
            if not a.startswith("-") and is_protected_env_name(a):
                full = os.path.normpath(os.path.join(eff_cwd, os.path.expanduser(a)))
                if is_linked_worktree(full) or is_linked_worktree(eff_cwd):
                    deny_worktree_env()

    if base not in {"cp", "ln", "rsync", "mv", "install"}:
        return
    operands, target, i, options = [], None, 0, True
    valued = {"--suffix", "--chmod", "--chown", "--exclude", "--include",
              "--filter", "--exclude-from", "--include-from", "--files-from", "--rsh"}
    while i < len(args):
        arg = args[i]
        if options and arg == "--":
            options = False
        elif options and base in {"cp", "ln", "mv", "install"} and arg in {"-t", "--target-directory"}:
            i += 1
            target = args[i] if i < len(args) else None
        elif options and base in {"cp", "ln", "mv", "install"} and arg.startswith("--target-directory="):
            target = arg.split("=", 1)[1]
        elif options and base in {"cp", "ln", "mv", "install"} and re.fullmatch(r"-[A-Za-z]*t", arg):
            i += 1
            target = args[i] if i < len(args) else None
        elif options and base in {"cp", "ln", "mv", "install"} and arg.startswith("-t") and not arg.startswith("--"):
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
    if not any(is_protected_env_name(p) for p in sources) and not is_protected_env_name(destination):
        return
    if base == "rsync" and ":" in destination.split("/", 1)[0]:
        return
    path = os.path.normpath(os.path.join(eff_cwd, os.path.expanduser(destination)))
    if is_linked_worktree(path) or re.search(r"[$`*?]", path):
        deny_worktree_env()


# ---------------------------------------------------------------- Template-managed path gate

def find_project_root(path):
    cur = os.path.abspath(path)
    if not os.path.isdir(cur):
        cur = os.path.dirname(cur)
    while True:
        if os.path.exists(os.path.join(cur, ".git")) or os.path.isdir(os.path.join(cur, ".claude")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return os.path.abspath(GATE_CWD or os.getcwd())


def is_dotfiles_repo(root):
    if not root:
        return False
    norm = os.path.abspath(root).replace("\\", "/")
    if os.path.isdir(os.path.join(root, "templates", "agent-team")):
        return True
    if "/orca/workspaces/dotfiles/" in norm or norm.endswith("/dotfiles"):
        return True
    return False


def is_adopted_project(root):
    if not root or is_dotfiles_repo(root):
        return False
    for marker in (
        os.path.join(root, ".claude", "hooks", "guard-config.json"),
        os.path.join(root, ".claude", "settings.project.json"),
        os.path.join(root, ".claude", "settings.json"),
        os.path.join(root, ".claude", "hooks"),
        os.path.join(root, ".agents", "skills"),
    ):
        if os.path.exists(marker):
            return True
    return False


def relative_project_path(target_path, cwd=None):
    base_cwd = cwd or GATE_CWD or os.getcwd()
    expanded = os.path.expanduser(target_path.strip("'\""))
    full = os.path.normpath(os.path.join(base_cwd, expanded))
    root = find_project_root(full)
    if is_dotfiles_repo(root) or "/templates/agent-team/" in full.replace("\\", "/"):
        return None, root
    try:
        rel = os.path.relpath(full, root).replace("\\", "/")
    except ValueError:
        return None, root
    if rel.startswith("../"):
        return None, root
    return rel, root


def is_template_managed_rel(rel):
    if not rel:
        return False
    rel = re.sub(r"^(?:\./)+", "", rel)
    if rel in {".claude/settings.json", ".claude/model-routing.md"}:
        return True
    parts = rel.split("/")
    if len(parts) == 3 and parts[0] == ".claude" and parts[1] == "agents":
        return parts[2] in CANONICAL_ROLES
    if len(parts) == 3 and parts[0] == ".claude" and parts[1] == "hooks":
        return parts[2] in TEMPLATE_HOOKS
    if len(parts) == 3 and parts[0] == ".claude" and parts[1] == "bin":
        return parts[2] in TEMPLATE_BINS
    if len(parts) == 3 and parts[0] == "docs" and parts[1] == "agents":
        return parts[2] in TEMPLATE_DOCS
    if len(parts) == 2 and parts[0] == "bin" and re.fullmatch(r"changelog-compile[^/]*\.sh", parts[1]):
        return True
    if len(parts) >= 3 and parts[0] in {".agents", ".claude", ".cursor"} and parts[1] == "skills":
        return parts[2] in TIER2_SKILLS
    return False


def deny_template_managed(rel):
    deny(
        f"`{rel}` is a template managed path in an adopted project and cannot be edited directly. "
        "Edit the project extension file instead: `.claude/hooks/guard-config.json`, "
        "`.claude/settings.project.json`, `docs/agents/team-facts.md` (`## Role facts`), "
        "or update `dotfiles/templates/agent-team/` (with an `Owner-approved:` trailer when required) "
        "and sync with `AGENT_TEAM_SYNC=1`."
    )


def sync_enabled(_segment=""):
    return os.environ.get("AGENT_TEAM_SYNC") == "1"


def check_template_managed_bash(segment, base, args, cwd=None):
    if sync_enabled():
        return
    eff_cwd = cwd or GATE_CWD or os.getcwd()
    candidates = list(extract_redirect_targets(segment))
    if base in {"cp", "mv", "ln", "install", "rsync"}:
        opts_done = False
        operands = []
        target_dir = None
        i = 0
        while i < len(args):
            a = args[i]
            if not opts_done and a == "--":
                opts_done = True
            elif not opts_done and a in {"-t", "--target-directory"} and i + 1 < len(args):
                target_dir = args[i + 1]
                i += 1
            elif not opts_done and a.startswith("--target-directory="):
                target_dir = a.split("=", 1)[1]
            elif not opts_done and a.startswith("-"):
                pass
            else:
                operands.append(a)
            i += 1
        if target_dir:
            for op in operands:
                candidates.append(os.path.join(target_dir, os.path.basename(op)))
        elif len(operands) >= 2:
            candidates.append(operands[-1])
            if base == "mv":
                candidates.extend(operands[:-1])
    elif base in {"tee", "rm", "rmdir", "touch", "chmod", "chown", "truncate"}:
        candidates.extend(a for a in args if not a.startswith("-"))
    elif base in {"sed", "gsed"} and any(a == "-i" or a.startswith(("-i", "--in-place")) for a in args):
        candidates.extend(a for a in args if not a.startswith("-"))

    for cand in candidates:
        rel, _ = relative_project_path(cand, eff_cwd)
        if is_template_managed_rel(rel):
            deny_template_managed(rel)


# ---------------------------------------------------------------- 4. Owner approval gate

def approval_file_candidates():
    if APPROVAL_FILE_OVERRIDE:
        return [APPROVAL_FILE_OVERRIDE]
    home_cfg = os.path.join(os.path.expanduser("~"), ".config")
    out = []
    if APPROVAL_NAMESPACE:
        out.append(os.path.join(home_cfg, APPROVAL_NAMESPACE, "approval.json"))
    if CONFIG_LOADED_FROM:
        proj_name = os.path.basename(os.path.abspath(CONFIG_LOADED_FROM))
        p = os.path.join(home_cfg, proj_name, "approval.json")
        if p not in out:
            out.append(p)
    for found in sorted(glob.glob(os.path.join(home_cfg, "*", "approval.json"))):
        if found not in out:
            out.append(found)
    default_p = os.path.join(home_cfg, "agent-team", "approval.json")
    if default_p not in out:
        out.append(default_p)
    return out


def primary_approval_file():
    cands = approval_file_candidates()
    return cands[0] if cands else os.path.join(os.path.expanduser("~"), ".config", "agent-team", "approval.json")


def owner_go(what, owner_command, why):
    app_file = primary_approval_file()
    deny(f"{what} needs the owner's go ({why}). Owner, run this in your own terminal: "
         f"`{owner_command}` (valid 30 minutes), then the agent reruns the same command. "
         f"Agents never run {APPROVE} or write {app_file}; report the request to Elon, who asks the owner.")


def load_approval():
    """(approval, reason it is missing or invalid)."""
    last_reason = "no owner approval is on file"
    now = time.time()
    for path in approval_file_candidates():
        if not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                a = json.load(f)
        except Exception:
            last_reason = f"{path} is unreadable"
            continue
        exp = a.get("expires_at") if isinstance(a, dict) else None
        if not isinstance(exp, (int, float)) or isinstance(exp, bool):
            last_reason = f"{path} has no expiry"
            continue
        if exp <= now:
            last_reason = "the last owner approval has expired"
            continue
        if exp > now + APPROVAL_TTL + 60:
            last_reason = f"{path} claims more than 30 minutes, so it is ignored"
            continue
        return a, ""
    return None, last_reason


def approval_for(scopes, target_ok=None):
    a, why = load_approval()
    if not a:
        return False, why
    scope = a.get("scope")
    if scope not in scopes:
        return False, f"the approval on file is for `{' '.join(filter(None, [scope, a.get('target')]))}`"
    if target_ok and not target_ok(a.get("target") or ""):
        return False, f"the approval on file is for `{scope} {a.get('target')}`, not this target"
    return True, ""


def git_out(*args, cwd=None):
    try:
        out = subprocess.run(["git", *args], cwd=cwd or GATE_CWD, capture_output=True, text=True, timeout=5)
    except Exception:
        return None
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else None


def resolve(ref, cwd=None):
    if not ref or re.search(r"[$`]", ref):
        return None
    return git_out("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", cwd=cwd)


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


def matches_stage_branch(branch):
    for pat in STAGE_BRANCHES:
        if branch == pat or fnmatch.fnmatchcase(branch, pat):
            return True
    return False


def check_git_push(args, cdir):
    cwd = os.path.join(GATE_CWD or os.getcwd(), os.path.expanduser(cdir)) if cdir else GATE_CWD
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

    if every and STAGE_BRANCHES:
        deny(f"`git push {' '.join(args)}` pushes every branch, stage and production included, and cannot be "
             f"approved. Push one named branch (git push origin <branch>). Production moves only through "
             f"/deploy after the owner runs `{APPROVE} promote <sha>` in his own terminal.")

    current = git_out("symbolic-ref", "--short", "-q", "HEAD", cwd=cwd)
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
        if matches_stage_branch(branch):
            if not src:
                deny(f"Deleting `{branch}` is never an agent's job and {APPROVE} has no scope for it. "
                     "Report it to Elon, who asks the owner; the owner does it himself.")
            sha = resolve(src, cwd) or (src if re.fullmatch(r"[0-9a-fA-F]{7,40}", src) else "<sha>")
            scope = "rollback" if forced else "promote"
            ok, why = approval_for({scope}, lambda t: same_commit(src, t, cwd))
            if not ok:
                what = f"Force pushing (rollback) to `{branch}`" if forced else f"Pushing to `{branch}`"
                owner_go(what, f"{APPROVE} {scope} {sha}", why)
        elif forced and branch == "main":
            ok, why = approval_for({"force-push"}, lambda t: t == branch)
            if not ok:
                owner_go(f"A force push to `{branch}`", f"{APPROVE} force-push {branch}", why)


def remote_read_only(segment):
    text = " ".join(re.split(r"[ \t]+", segment.strip(" \t")))
    return any(p.fullmatch(text) for p in REMOTE_READ_ONLY)


def curl_read_only(args):
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


def printable(text):
    return re.fullmatch(r"[\x20-\x7e\t]*", text) is not None


def host_deploy_command(target, remote):
    """None, or (the release sha or "") when the raw remote text is exactly one of the host_deploy_commands
    for target. No comment or redirect is stripped, only runs of spaces and tabs are collapsed, and any
    shell metacharacter outside the one `&&` of the checkout form refuses."""
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


def prod_host(arg):
    if PRODUCTION_HOSTS_ERROR:
        return True
    if not PRODUCTION_HOSTS:
        return False
    a = re.sub(r"^(ssh|scp|sftp|rsync)://", "", arg, flags=re.I)
    host = re.split(r"[:/]", a, maxsplit=1)[0].rpartition("@")[2].strip("[]").rstrip(".").lower()
    return host in PRODUCTION_HOSTS


def take_flags(args, i, with_arg, opts):
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
    m = re.fullmatch(r"'([^']*)'|\"([^\"$`\\]*)\"", word)
    if m:
        inner = m.group(1) if m.group(1) is not None else m.group(2)
        if not HOST_METACHARS.search(inner):
            word = inner
    a = re.sub(r"^(ssh|scp|sftp|rsync)://", "", word, flags=re.I)
    return HOST_METACHARS.search(re.split(r"[:/]", a, maxsplit=1)[0]) is not None


def operands_indices(base, args):
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
    return any(os.path.basename(t) == "xargs" and program_and_args(tokens[:k] + ["true"])[0] == "true"
               for k, t in enumerate(tokens))


def check_hidden_hosts(segment, base, args):
    if not PRODUCTION_HOSTS and not PRODUCTION_HOSTS_ERROR:
        return
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
    for i in [ssh_argv(args)[1]] if base == "ssh" else operands_indices(base, args):
        if i is not None and i < len(raw_args) and hidden_host(raw_args[i]):
            deny(f"`{raw_args[i]}` in {base} is not a plain host name: the shell would build it from $, a backtick, "
                 "braces, a glob, a backslash or quotes, so the guard cannot tell whether it is production. No "
                 "approval covers it. Write the host literally.")


GIT_REMOTE_OPS = {"fetch", "pull", "push", "clone", "ls-remote", "remote", "submodule", "archive"}
NETWORK_PROGRAMS = {"scp", "sftp", "rsync", "nc", "ncat", "netcat", "eval"}


def names_production_host(segment):
    if not PRODUCTION_HOSTS and not BACKSTOP_HOSTS:
        return False
    tokens = sorted(PRODUCTION_HOSTS | BACKSTOP_HOSTS, key=len, reverse=True)
    pattern = r"(?i)(?<![a-zA-Z0-9.-])(?:%s)\.?(?![a-zA-Z0-9.-])" % "|".join(map(re.escape, tokens))
    return re.search(pattern, segment) is not None


def check_backstop(segment, base, args):
    if not names_production_host(segment):
        return
    if runs_xargs(words(segment)):
        pass
    elif base == "ssh":
        dest = ssh_argv(args)[1]
        if dest is not None and prod_host(args[dest]):
            return
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
    remote = " ".join(args[cmd:]).strip(" \t")
    if not printable(remote):
        ok, why = approval_for({"host"})
        if not ok:
            owner_go("A production host command with characters outside printable ASCII", f"{APPROVE} host", why)
        return
    cleaned = re.sub(r"\d*>>?\s*/dev/null|\d*>&\d", "", remote)
    if remote and not re.search(r"[>`]|\$\(", cleaned) and all(remote_read_only(s) for s in segments(cleaned)):
        for seg in segments(remote):
            check_segment(seg, depth + 1)
        return
    sha = None
    if not opts and cmd == dest + 1:  # promote and rollback pass no ssh options
        sha = host_deploy_command(args[dest], " ".join(args[dest + 1:]))
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
        if PRODUCTION_HOSTS_ERROR:
            what += f" (fail closed: {PRODUCTION_HOSTS_ERROR})"
        owner_go(f"{what} (only status, logs and health checks run without approval)", f"{APPROVE} host", why)


def has_redirect(segment):
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
    out = set()
    for i, t in enumerate(tokens):
        prev = tokens[i - 1] if i else ""
        if re.search(r"\s", t) or prev in TEXT_FLAGS or (re.match(r"^--?[A-Za-z-]+=", t) and not t.startswith("-c")):
            out.add(i)
    return out


def text_program(base, args):
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
    if base in SHELLS:
        return "-n" in args and not any(re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) for a in args)
    return False


def promote_invocation(script, script_args):
    rule = PROMOTE_RULES.get(script)
    if rule is None:
        return None
    pos = [a for a in script_args if not a.startswith("-")]
    free = rule.get("free_stages") or set()
    if free:
        if pos and pos[0] in free:
            return None
        comp_idx = rule.get("component")
        sha_idx = rule.get("sha", 2)
        comp = pos[comp_idx] if comp_idx is not None and comp_idx < len(pos) else ""
        sha = pos[sha_idx] if sha_idx is not None and sha_idx < len(pos) else (pos[-1] if len(pos) > 1 else "")
        return {"component": comp, "sha": sha}
    sha = pos[0] if pos else ""
    return {"component": "", "sha": sha}


def check_risky(segment, base, args, depth):
    tokens = words(segment)
    viewer = read_only_viewer(base, args)
    text = text_program(base, args)
    if SCRIPT_NAME.search(segment) and not (viewer or text):
        deny(f"{APPROVE} is the owner's own approval: an agent never runs it, however wrapped. "
             f"Ask Elon to have the owner run `{APPROVE} <scope>` in his own terminal. "
             "Reading, grepping or committing the script is fine.")
    approval_markers = ["approval.json"]
    if APPROVAL_NAMESPACE:
        approval_markers.append(f".config/{APPROVAL_NAMESPACE}")
    if any(m in segment for m in approval_markers):
        prose = prose_tokens(tokens)
        names_file = any(any(m in t for m in approval_markers) and i not in prose for i, t in enumerate(tokens))
        if has_redirect(segment) or (not viewer and not (text and not names_file)):
            app_file = primary_approval_file()
            deny(f"{app_file} is the owner's approval: only {APPROVE}, run by the owner in his own terminal, "
                 f"writes it. Agents may only read it. Ask the owner to run `{APPROVE} <scope>`.")

    script, script_args = base, args
    if base in SHELLS or base in {"source", "."}:
        idx = next((i for i, a in enumerate(args) if not a.startswith("-")), None)
        script = os.path.basename(args[idx]) if idx is not None and "-n" not in args else ""
        script_args = args[idx + 1:] if idx is not None else []

    if script in APPLY_SCRIPTS:
        sha = script_args[0] if script_args else "<sha>"
        a, why = load_approval()
        ok = (re.fullmatch(r"[0-9a-f]{40}", sha) and a and a.get("scope") == "promote" and a.get("target") == sha
              and a.get("schema") is True and a.get("apply") is True)
        if not ok:
            owner_go(f"{script} for {sha}", f"{APPROVE} promote {sha} --schema --apply",
                     why or "requires a matching literal release and schema/apply approval")

    promo = promote_invocation(script, script_args)
    sha_arg = promo["sha"] if promo else (next((a for a in script_args if not a.startswith("-")), "") if script in ROLLBACK_SCRIPTS else "")

    settings = tokens[:len(tokens) - len(args) - 1]
    if base in {"export", "declare", "typeset", "readonly", "local"}:
        settings += args
    for t in settings:
        if GIT_SSH_ENV.match(t):
            deny(f"`{t.split('=', 1)[0]}` makes git run that command in place of ssh, on any host, so no approval "
                 "covers it. Run git without it; report a real need to Elon, who asks the owner.")
        if t.startswith("RSYNC_RSH="):
            check_rsh(t.split("=", 1)[1], "RSYNC_RSH")
    if any(t == SCHEMA_OVERRIDE or (t.startswith(SCHEMA_OVERRIDE + "=") and t != SCHEMA_OVERRIDE + "=0")
           for t in settings) and not (script in PROMOTE_RULES and promo is None):
        sha = resolve(sha_arg) or sha_arg or "<sha>"
        ok, why = approval_for({"promote"}, (lambda t: same_commit(sha_arg, t)) if sha_arg else None)
        a, _ = load_approval()
        if not ok or not (a or {}).get("schema"):
            owner_go(f"{SCHEMA_OVERRIDE}=1 (a production schema push)", f"{APPROVE} promote {sha} --schema",
                     why or "the approval on file does not cover the schema")

    if promo is not None:
        comp = promo.get("component") or ""
        if re.search(r"[$`]", sha_arg + comp) or not sha_arg:
            deny(f"Pass {script} the literal sha, so it can be matched against the owner's "
                 f"approval: {script} <sha>. The owner approves it with `{APPROVE} promote <sha>`.")
        sha = resolve(sha_arg) or sha_arg or "<sha>"
        ok, why = approval_for({"promote", "rollback"}, lambda t: same_commit(sha_arg, t))
        if not ok:
            owner_go(f"Promoting {sha} to production", f"{APPROVE} promote {sha}", why)

    if script in ROLLBACK_SCRIPTS:
        if re.search(r"[$`]", sha_arg) or not sha_arg:
            deny(f"Pass {script} the literal sha, so it can be matched against the owner's "
                 f"approval: {script} <sha>. The owner approves it with `{APPROVE} rollback <sha>`.")
        sha = resolve(sha_arg) or sha_arg or "<sha>"
        ok, why = approval_for({"rollback"}, lambda t: same_commit(sha_arg, t))
        if not ok:
            owner_go(f"Rolling production back to {sha}", f"{APPROVE} rollback {sha}", why)

    if base == "git":
        check_git_ssh(args)
        sub, rest, cdir = git_subcommand(args)
        if sub == "push":
            check_git_push(rest, cdir)

    if base == "gh" and args[:1] == ["api"] and STAGE_BRANCHES:
        for a in args:
            m = re.search(r"refs/(?:heads/)?([A-Za-z0-9_./-]+)", a)
            if m and matches_stage_branch(m.group(1)):
                method = next((args[i + 1] for i, x in enumerate(args)
                               if x in ("-X", "--method") and i + 1 < len(args)), None)
                fields = any(x in ("-f", "-F", "--field", "--raw-field", "--input") for x in args)
                if (method or ("POST" if fields else "GET")).upper() != "GET":
                    deny("Moving a stage or production branch through the GitHub API skips the deploy gate. "
                         f"Production moves only with git push or the promote script after the owner runs `{APPROVE} promote <sha>`.")

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
            owner_go(f"{base} to or from the production host" + (f" (fail closed: {PRODUCTION_HOSTS_ERROR})" if PRODUCTION_HOSTS_ERROR else ""),
                     f"{APPROVE} host", why)
    check_backstop(segment, base, args)


# Team gates (#6936): role file commits, the grill gate on dispatch, an owning lead on remote workers.
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
GRILL_APPROVAL = re.compile(r"(?is)(?=.*grill)(?=.*(owner.{0,60}approv|approv.{0,60}owner))")
GRILL_EXEMPT_LABELS = ("hotfix", "mechanical")
REMOTE_FLAGS = ("--on", "--environment", "--pairing-code")


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
         "(never before), or take those files out of the change. In an adopted project, edit "
         "`.claude/hooks/guard-config.json`, `.claude/settings.project.json`, `docs/agents/team-facts.md`, "
         "or `dotfiles/templates/agent-team/` instead.")


def check_role_file_gate(base, args):
    root = find_project_root(GATE_CWD or os.getcwd())
    adopted = is_adopted_project(root) and not sync_enabled(RAW_COMMAND)
    if base == "git":
        verb, rest = git_verb(args)
        if verb == "commit":
            staged = set((gate_run(["git", "diff", "--cached", "--name-only"], None) or "").split())
            if "--all" in rest or any(a.startswith("-") and not a.startswith("--") and "a" in a for a in rest):
                staged |= set((gate_run(["git", "diff", "--name-only"], None) or "").split())
            if adopted:
                managed = sorted(f for f in staged if is_template_managed_rel(f))
                if managed:
                    deny_template_managed(managed[0])
            files = {f for f in staged if is_protected(f)}
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
        changed = (gate_run(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", sha], None) or "").split()
        files = {f for f in changed if is_protected(f)}
        message = gate_run(["git", "show", "-s", "--format=%B", sha], None) or ""
        if files and not OWNER_TRAILER.search(message):
            deny_role_files(files, f"Commit {sha[:9]}")


DOTFILES_REPO = os.environ.get("DOTFILES_REPO") or "OWNER/dotfiles"
DOTFILES_ISSUE = re.compile(r"(?:[\w.-]+/)?dotfiles#(\d{3,6})\b")
BRIEF_LINT_REL = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "script", "brief-lint.sh")
)


def brief_lint_script():
    if os.environ.get("BRIEF_LINT"):
        return os.environ["BRIEF_LINT"]
    if os.path.isfile(BRIEF_LINT_REL):
        return BRIEF_LINT_REL
    dotfiles = os.environ.get("DOTFILES") or os.path.expanduser("~/dotfiles")
    return os.path.join(dotfiles, "script", "brief-lint.sh")


def brief_text(path):
    """A brief file's text, or None when it cannot be read."""
    full = os.path.join(GATE_CWD or "", os.path.expanduser(os.path.expandvars(path)))
    try:
        if os.path.isfile(full):
            with open(full, errors="replace") as f:
                return f.read(65536)
    except OSError:
        pass
    return None


def check_brief_lint(brief):
    lint = brief_lint_script()
    if not os.path.isfile(lint):
        deny(f"brief-lint.sh is missing at {lint} (fail closed); see ~/.agents/skills/triage/AGENT-BRIEF.md.")
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix="guard-brief-", suffix=".md")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(brief or "")
        out = subprocess.run(["bash", lint, tmp], capture_output=True, text=True, timeout=10)
    except Exception:
        deny("brief-lint.sh could not run (fail closed); see ~/.agents/skills/triage/AGENT-BRIEF.md.")
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    if out.returncode != 0:
        raw = (out.stdout or out.stderr or "").strip()
        missing = [
            line.split("brief-lint: missing ", 1)[1].strip()
            for line in raw.splitlines()
            if line.startswith("brief-lint: missing ")
        ]
        parts = ", ".join(missing) if missing else raw
        deny(f"Brief is incomplete (missing: {parts}). {raw}\n"
             "Follow ~/.agents/skills/triage/AGENT-BRIEF.md.")


def check_grill_gate(args, spec):
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
        return
    labels = " ".join(l.get("name", "") for l in issue.get("labels") or []).lower()
    texts = [issue.get("body") or ""] + [c.get("body") or "" for c in issue.get("comments") or []]
    if any(x in labels for x in GRILL_EXEMPT_LABELS) or any("elon take over" in t.lower() for t in texts[1:]):
        return
    if not any(GRILL_APPROVAL.search(t) for t in texts[1:]):
        deny(f"Missing: a comment on {repo_name}#{number} naming the owner's approval of the grill results "
             "(~/dotfiles/templates/agent-team/docs/agents/team.md, Pre-build grill gate). Get the owner's approval, record it on the issue, "
             "then dispatch. Hotfix, mechanical text only and \"Elon take over\" work are exempt.")


def check_worker_start(args, script=False):
    if script:
        path = option_value(args, "--spec") or option_value(args, "--spec-file")
        brief = brief_text(path) if path else None
        if path and brief is None:
            deny(f"The brief `{path}` could not be read, so the grill check cannot tell which role it names. "
                 "Fix the path (or write the brief first) and start the worker again.")
        spec = "\n".join([" ".join(args), brief]) if brief is not None else RAW_COMMAND
    else:
        if any(option_value(args, f) is not None or f in args for f in REMOTE_FLAGS) and not option_value(args, "--from"):
            deny("This worker starts on another host with no owning lead recorded, so its worker_done would reach nobody. "
                 "Add `--from <your terminal handle>` (the lead who receives worker_done) and start it again.")
        spec_file = option_value(args, "--spec-file")
        if spec_file is not None:
            brief = brief_text(spec_file)
            if brief is None:
                deny(f"The brief `{spec_file}` could not be read. Fix the path (or write the brief first) and start the worker again; "
                     "see ~/.agents/skills/triage/AGENT-BRIEF.md.")
            spec = "\n".join([RAW_COMMAND, brief])
        else:
            brief = option_value(args, "--spec")
            spec = RAW_COMMAND
    check_grill_gate(args, spec)
    check_brief_lint(brief)


def check_team_gates(base, args):
    check_role_file_gate(base, args)
    if base == "orca" and args[:2] == ["orchestration", "worker-start"]:
        check_worker_start(args)
    elif base == "start-cursor-worker.sh":
        check_worker_start(args, script=True)


def check_segment(segment, depth=0, cwd=None):
    if depth > 3:
        deny("Shell command nesting exceeds the guard inspection limit. Split the command into separate calls.")
    tokens = words(segment)
    prog, args = program_and_args(tokens)
    if not prog:
        return
    base = os.path.basename(prog)

    transfer_cwd = cwd or GATE_CWD
    for i, token in enumerate(tokens):
        if os.path.basename(token) == "env":
            for j in range(i + 1, len(tokens)):
                arg = tokens[j]
                if arg in {"-C", "--chdir"} and j + 1 < len(tokens):
                    transfer_cwd = os.path.join(transfer_cwd or os.getcwd(), os.path.expanduser(tokens[j + 1]))
                    break
                if arg.startswith("--chdir="):
                    transfer_cwd = os.path.join(transfer_cwd or os.getcwd(), os.path.expanduser(arg.split("=", 1)[1]))
                    break
            break

    check_worktree_env(segment, base, args, transfer_cwd)
    check_template_managed_bash(segment, base, args, transfer_cwd)
    check_pattern_kill(segment, base, args)
    check_team_gates(base, args)
    check_risky(segment, base, args, depth)

    # Heavy jobs must acquire the shared machine budget.
    try:
        heavy_tokens = shlex.split(segment, comments=True)
        while heavy_tokens and heavy_tokens[0] in {"if", "then", "else", "elif", "do", "while", "until", "!"}:
            heavy_tokens = heavy_tokens[1:]
        heavy_prog, heavy_args = program_and_args(heavy_tokens)
    except ValueError:
        heavy_prog, heavy_args = None, []
    heavy_base = os.path.basename(heavy_prog or "")
    if heavy_base == "bun":
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
        deny(f"{base} runs only inside the deploy pipeline (the deploy wrapper through /deploy). "
             "Reading, grepping, editing or committing the file is fine; running it is not.")
    if base == "eval":
        for text in [" ".join(args), *substitutions(" ".join(args))]:
            for seg in segments(text):
                check_segment(seg, depth + 1, cwd=transfer_cwd)
    if base in SHELLS or base in {"source", "."}:
        idx = next((i for i, a in enumerate(args) if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a)), None)
        if idx is not None:
            if idx + 1 < len(args):
                script = args[idx + 1]
                positional = args[idx + 2:]
                if positional:
                    script = re.sub(
                        r"\$(?:\{([0-9])\}|([0-9]))",
                        lambda m: positional[int(m.group(1) or m.group(2))]
                        if int(m.group(1) or m.group(2)) < len(positional) else m.group(0),
                        script,
                    )
                for text in [script, *substitutions(script)]:
                    cur_cwd = transfer_cwd
                    for seg in segments(text):
                        check_segment(seg, depth + 1, cwd=cur_cwd)
                        p2, a2 = program_and_args(words(seg))
                        if p2 == "cd" and a2:
                            dest = next((x for x in a2 if not x.startswith("-")), None)
                            if dest:
                                cur_cwd = os.path.normpath(os.path.join(cur_cwd or os.getcwd(), os.path.expanduser(dest)))
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
    check_secrets_dir(segment, base, args, prog=prog)
    if any(p.fullmatch(segment.strip()) for p in SECRETS_STDIN_OK) or is_sign_in_invocation(prog, args):
        return

    # 2. Secrets.
    secret_args = [a for a in args if SECRET_FILE.search(a) or SECRETS_DIR.search(a)]
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


def check_edit(tool, path):
    if not path:
        return
    expanded = os.path.expanduser(path)
    full = os.path.normpath(os.path.join(GATE_CWD or os.getcwd(), expanded))
    real = os.path.realpath(full)
    cfg_root = os.path.realpath(os.path.join(os.path.expanduser("~"), ".config"))
    if (real == cfg_root or real.startswith(cfg_root + os.sep)) and os.path.basename(real) == "approval.json":
        app_file = primary_approval_file()
        deny(f"{tool} on {path} is blocked: {app_file} is the owner's approval and only {APPROVE}, run by "
             f"the owner in his own terminal, writes it. Ask the owner to run `{APPROVE} <scope>`.")

    if is_protected_env_name(full) and (is_linked_worktree(full) or is_linked_worktree(GATE_CWD or os.getcwd())):
        deny_worktree_env()

    if not sync_enabled():
        rel, _ = relative_project_path(full, GATE_CWD)
        if is_template_managed_rel(rel):
            deny_template_managed(rel)


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
    """Remove literal data only for a standalone quoted cat-to-file heredoc."""
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
    if not isinstance(data, dict):
        return
    tool = data.get("tool_name")
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    global GATE_CWD, RAW_COMMAND
    raw_cwd = data.get("cwd")
    GATE_CWD = raw_cwd if isinstance(raw_cwd, str) and raw_cwd else os.getcwd()
    load_guard_config(GATE_CWD)
    if tool in EDIT_TOOLS:
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        check_edit(tool, path if isinstance(path, str) else "")
        return
    if tool != "Bash":
        return
    raw_cmd = tool_input.get("command")
    command = raw_cmd if isinstance(raw_cmd, str) else ""
    RAW_COMMAND = command
    check_background_wait(command)
    try:
        command = report_command_text(command)
        for text in [command, *substitutions(command)]:
            cur_cwd = GATE_CWD
            for seg in segments(text):
                check_segment(seg, cwd=cur_cwd)
                prog, args = program_and_args(words(seg))
                if prog == "cd" and args:
                    dest = next((a for a in args if not a.startswith("-")), None)
                    if dest:
                        cur_cwd = os.path.normpath(os.path.join(cur_cwd or os.getcwd(), os.path.expanduser(dest)))
    except SystemExit:
        raise
    except Exception:
        return


if __name__ == "__main__":
    main()
