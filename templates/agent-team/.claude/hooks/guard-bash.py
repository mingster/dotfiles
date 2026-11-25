#!/usr/bin/env python3
"""PreToolUse guard for Bash and file edit tools, from the shared agent team template.

Blocks these kinds of accident:

1. Running a raw deploy script that only the pipeline wrapper may run. The check
   looks at the program a command segment executes, so `git add bin/deploy-win.sh`,
   `grep x bin/deploy-win.sh` or editing the script are allowed; `./bin/deploy-win.sh`,
   `bash bin/deploy-win.sh` or `FOO=1 sh -c "bin/deploy-win.sh"` are not.
2. Printing a secret into the session log: reading `.env` files, `secrets/`, key
   files, or echoing secret environment variables. Use `python3 "$HOME/.claude/bin/env-peek.py"`
   to check a value without printing it.
3. A PayPal API call other than GET and the token request.
4. Risky production commands without the owner's go (`check_risky`): a push to a
   configured stage or production branch, any force push, promote/rollback/apply
   scripts, schema overrides, and ssh, scp, sftp or rsync to a configured
   production host beyond a read-only allowlist. release-manager may push the
   production branch with no owner go only after `git fetch origin main` in the
   project whose guard config loaded, when
   `refs/remotes/origin/main:docs/agents/deploy-facts.md` has exactly one
   unindented `Production data: production holds only test data` line outside a
   code fence or HTML comment, and no line says a real or live store exists. A
   failed fetch, a `cd`, `pushd`, `git -C`, `--git-dir`, `--work-tree`, `GIT_*`
   env, `-c`, or a URL remote aimed at another repo keeps the go. A force push
   stays gated. Project values are loaded from
   `<project>/.claude/hooks/guard-config.json` (defaulting to empty when absent).
5. Copying, linking, or writing `.env` / `.env.*` files in linked agent worktrees
   (`check_worktree_env`), unless listed in `worktree_env_allow`.
6. Editing template-managed agent team files directly inside an adopted project
   outside `dotfiles` when `AGENT_TEAM_SYNC` is not `1`.
7. Running Playwright or production builds outside the shared heavy job gate, or type checks outside measure mode.
   Gate wrappers execute their children outside PreToolUse, so no environment
   escape hatch is needed.
8. Feeding commands to a shell or interpreter where the guard cannot read them
   (`check_indirection`): a shell reading a pipe, here-string or heredoc, `bash -c "$(...)"`,
   or `python3 -c` / `perl -e` / `node -e` code that starts a process.
9. A glob, brace, variable or substitution that can build a path under an exact_only script
   directory or a credential directory, and `find -exec`, `find -execdir` or `xargs` that
   search one of those directories (`check_hidden_script_paths`). `$?`, `$#`, `$$`, `$!`
   and `$-` are never path expansions. Another variable counts only in a path word.

Anything it cannot parse is let through: the deny rules in settings.json are the
backstop. Exit 0 always; a block is a JSON permissionDecision of "deny".
"""
from __future__ import annotations

import datetime
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
PRODUCTION_BRANCHES: list[str] = []
STAGE_BRANCH_COMPONENTS: dict[str, str] = {}
PROMOTE_RULES: dict[str, dict] = {
    "deploy-stage.sh": {"free_stages": {"local", "staging", "status"}, "component": 1, "sha": 2}
}
ROLLBACK_SCRIPTS: set[str] = {"rollback-production.sh"}
APPLY_SCRIPTS: set[str] = {"apply-production-sql.sh", "set-production-secret.sh", "run-production-data-step.sh"}
# The one apply script that skips the approval before the go-live date (UTC, ISO) in guard-config.json
# `pre_go_live_secrets.until`. The script itself refuses to overwrite an existing key.
PRE_GO_LIVE_SCRIPT = "set-production-secret.sh"
PRE_GO_LIVE_UNTIL: str | None = None
# `pre_go_live_host.until` (ISO date, compared with today in Asia/Taipei): the `host` approval is waived before
# it. Absent or malformed means no waiver. The same date also waives approval for the promote and rollback
# scripts and the SCHEMA_APPROVED schema check. Nothing else is waived: a hand push to a production branch,
# force push, deletion, the apply scripts and credential writes keep their gates.
PRE_GO_LIVE_HOST_UNTIL: str | None = None


def pre_go_live_command(script_args):
    """Only `<sha> --host prod-1 STORE_DOCUMENTS_<NAME>`, `<sha> --host prod-1 LINE_EGRESS_IP` or a `--copy-to-standby` run skips the approval."""
    rest = script_args[1:]
    if "--copy-to-standby" in rest:
        return True
    if rest[:2] != ["--host", "prod-1"]:
        return False
    return len(rest) == 3 and re.fullmatch(r"STORE_DOCUMENTS_[A-Z0-9_]+|LINE_EGRESS_IP", rest[2]) is not None
SCHEMA_OVERRIDE: str = "SCHEMA_APPROVED"
APPROVAL_NAMESPACE: str = ""
APPROVAL_FILE_OVERRIDE: str = ""
SIGN_IN_SCRIPT: str | None = None
SECRETS_DIR_EXCEPTIONS: list[str] = []
EXACT_ONLY_SCRIPTS: list[str] = []
SECRETS_DIR_RELPATHS: list[str] = []
FORCE_PUSH_BRANCHES: list[str] = ["main"]
SECRETS_STDIN_OK: list[re.Pattern] = []
WORKTREE_ENV_ALLOW: list[str] = []
HOST_DEPLOY_PATTERNS: dict[str, list[re.Pattern]] = {}
PROMOTE_STEPS: dict | None = None
CONFIG_LOADED_FROM: str | None = None
GRILL_APPROVERS: set[str] = set()

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
# The owner's approval signing secret sits beside the approval file (`~/.config/<namespace>/approval-secret`).
# Named distinctly from SECRET_FILE above, which matches env and key files.
APPROVAL_SECRET_PATH = re.compile(r"\.config/[^/\s'\"]+/approval-secret")
APPROVAL_SECRET_BARE = re.compile(r"(?:^|[/=])approval-secret$")
APPROVAL_SECRET_ENV = "AGENT_APPROVAL_SECRET"
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

ENV_PEEK = 'python3 "$HOME/.claude/bin/env-peek.py" <file> [KEY ...]'

APPROVAL_TTL = 30 * 60
MERGE_TTL_MAX = 24 * 60 * 60  # `merge <hours>` opens an admin merge window of up to 24 hours
HOST_TTL_MAX = 336 * 60 * 60  # `host <hours>` opens a host access window of up to 14 days
SCOPE_TTL_MAX = {"merge": MERGE_TTL_MAX, "host": HOST_TTL_MAX}
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
# `remote_read_only_commands` adds command names, with or without arguments, and never replaces it.
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
}
TIER2_SKILLS = {"ceo", "deploy", "elon", "poteto-mode", "team-audit"}

GATE_CWD = None
RAW_COMMAND = ""
CODE_COMMAND = ""  # RAW_COMMAND without the quoted text sink heredocs: what an interpreter on stdin could run
HOOK_INPUT: dict = {}


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
    global STAGE_BRANCHES, PRODUCTION_BRANCHES, STAGE_BRANCH_COMPONENTS, PROMOTE_RULES, ROLLBACK_SCRIPTS
    global APPLY_SCRIPTS, SCHEMA_OVERRIDE, APPROVAL_NAMESPACE, APPROVAL_FILE_OVERRIDE
    global SIGN_IN_SCRIPT, SECRETS_STDIN_OK, WORKTREE_ENV_ALLOW, SECRETS_DIR, SECRETS_WRITE_REDIRECT
    global CONFIG_LOADED_FROM, HOST_DEPLOY_PATTERNS, REMOTE_READ_ONLY, SECRETS_DIR_EXCEPTIONS, FORCE_PUSH_BRANCHES
    global EXACT_ONLY_SCRIPTS, SECRETS_DIR_RELPATHS, GRILL_APPROVERS, PROMOTE_STEPS, PRE_GO_LIVE_UNTIL, PRE_GO_LIVE_HOST_UNTIL

    BLOCKED_SCRIPTS = set()
    GRILL_APPROVERS = set()
    PRODUCTION_HOSTS = set()
    BACKSTOP_HOSTS = set()
    PRODUCTION_HOSTS_ERROR = None
    STAGE_BRANCHES = []
    PRODUCTION_BRANCHES = []
    STAGE_BRANCH_COMPONENTS = {}
    PROMOTE_RULES = {
        "deploy-stage.sh": {"free_stages": {"local", "staging", "status"}, "component": 1, "sha": 2}
    }
    ROLLBACK_SCRIPTS = {"rollback-production.sh"}
    APPLY_SCRIPTS = {"apply-production-sql.sh", "set-production-secret.sh", "run-production-data-step.sh"}
    PRE_GO_LIVE_UNTIL = None
    PRE_GO_LIVE_HOST_UNTIL = None
    SCHEMA_OVERRIDE = "SCHEMA_APPROVED"
    APPROVAL_NAMESPACE = ""
    APPROVAL_FILE_OVERRIDE = os.environ.get("GUARD_APPROVAL_FILE") or ""
    SIGN_IN_SCRIPT = None
    SECRETS_DIR_EXCEPTIONS = []
    EXACT_ONLY_SCRIPTS = []
    SECRETS_DIR_RELPATHS = []
    FORCE_PUSH_BRANCHES = ["main"]
    SECRETS_STDIN_OK = []
    WORKTREE_ENV_ALLOW = []
    HOST_DEPLOY_PATTERNS = {}
    PROMOTE_STEPS = None
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
                if key == "production_branches" and isinstance(br, str) and br.strip() and br.strip() not in PRODUCTION_BRANCHES:
                    PRODUCTION_BRANCHES.append(br.strip())
        elif isinstance(val, list):
            for br in val:
                if isinstance(br, str) and br.strip() and br.strip() not in STAGE_BRANCHES:
                    STAGE_BRANCHES.append(br.strip())
                if key == "production_branches" and isinstance(br, str) and br.strip() and br.strip() not in PRODUCTION_BRANCHES:
                    PRODUCTION_BRANCHES.append(br.strip())

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

    raw_go_live = cfg_expect("pre_go_live_secrets", dict, "object")
    until = (raw_go_live or {}).get("until")
    if isinstance(until, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", until):
        PRE_GO_LIVE_UNTIL = until

    raw_host_go_live = cfg_expect("pre_go_live_host", dict, "object")
    host_until = (raw_host_go_live or {}).get("until")
    if isinstance(host_until, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", host_until):
        PRE_GO_LIVE_HOST_UNTIL = host_until

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
    SECRETS_DIR_RELPATHS = list(extra_dirs)
    if extra_dirs:
        escaped = [re.escape(d) for d in extra_dirs]
        dir_union = "|".join([DEFAULT_SECRETS_DIR_PATTERN] + [rf"(?:^|[/\s='\"<(])(?:{e})(?:/|$|[\s'\"\)])" for e in escaped])
        SECRETS_DIR = re.compile(dir_union)
        redir_union = "|".join(["secrets/"] + [rf"{e}/?" for e in escaped])
        SECRETS_WRITE_REDIRECT = re.compile(rf">>?\s*\S*(?:{redir_union})\S*")

    raw_sign_in = cfg_expect("sign_in_script", str, "string")
    if raw_sign_in and raw_sign_in.strip():
        SIGN_IN_SCRIPT = raw_sign_in.strip()

    # Sentences naming the scripts that may read the secrets dir, shown in its deny in place of the sign in one.
    for item in cfg_expect("secrets_dir_exceptions", list, "list") or []:
        if isinstance(item, str) and item.strip():
            SECRETS_DIR_EXCEPTIONS.append(item.strip())

    # Repo relative scripts that look in the secrets dir themselves and print no value. Each runs only as
    # the whole command (check_exact_only_scripts). Drop a NUL, or any entry whose path cannot be resolved.
    # Resolving that entry later raises, and main() then allows every Bash command.
    for item in cfg_expect("exact_only_scripts", list, "list") or []:
        if not isinstance(item, str):
            continue
        rel = item.strip()
        if not rel or "\0" in rel:
            continue
        try:
            rel = os.path.normpath(rel)
            if CONFIG_LOADED_FROM:
                os.path.realpath(rel if os.path.isabs(rel) else os.path.join(CONFIG_LOADED_FROM, rel))
        except Exception:
            continue
        EXACT_ONLY_SCRIPTS.append(rel)

    # Branch globs a force push needs the owner's `force-push <branch>` for; ["*"] guards every branch.
    # Config only adds: `main` stays guarded whatever the list says.
    for b in cfg_expect("force_push_branches", list, "list") or []:
        if isinstance(b, str) and b.strip() and b.strip() not in FORCE_PUSH_BRANCHES:
            FORCE_PUSH_BRANCHES.append(b.strip())

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

    # Read-only inspection and Prisma client regeneration a promote approval covers on the release host.
    # app_dir is the app checkout; read_hosts may be inspected, write_hosts may also regenerate the client.
    steps = cfg_expect("promote_host_steps", dict, "object")
    if steps and isinstance(steps.get("app_dir"), str) and re.fullmatch(r"/[A-Za-z0-9._/-]*[A-Za-z0-9_]", steps["app_dir"]) \
            and ".." not in steps["app_dir"].split("/"):
        names = lambda key: {h.strip().lower() for h in steps.get(key) or [] if isinstance(h, str) and h.strip()}
        write_hosts = names("write_hosts")
        PROMOTE_STEPS = {"app": steps["app_dir"], "read_hosts": names("read_hosts") | write_hosts,
                         "write_hosts": write_hosts}

    raw_read_only = cfg_expect("remote_read_only", list, "list")
    if raw_read_only is not None:
        REMOTE_READ_ONLY = []
        for pat in raw_read_only:
            if isinstance(pat, str) and pat.strip():
                try:
                    REMOTE_READ_ONLY.append(re.compile(pat))
                except re.error:
                    pass
    else:
        REMOTE_READ_ONLY = list(DEFAULT_REMOTE_READ_ONLY)
    for name in cfg_expect("remote_read_only_commands", list, "list") or []:
        if isinstance(name, str) and name.strip() and not any(ch.isspace() for ch in name):
            REMOTE_READ_ONLY.append(re.compile(re.escape(name.strip()) + r"(?: .*)?"))
    for login in cfg_expect("grill_approvers", list, "list") or []:
        if isinstance(login, str) and login.strip():
            GRILL_APPROVERS.add(login.strip().lower())


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


def is_refs_invocation(prog, args, cwd=None):
    """~/dotfiles/script/secrets-refs.sh <dir> <pattern>: prints file:line, never the matched text, so the pattern
    may name the secrets dir. Only that script (by real path), exactly two plain arguments, and a <dir> that
    neither names the secrets dir nor expands."""
    if len(args) != 2 or any(a.startswith("-") for a in args):
        return False
    if SECRETS_DIR.search(args[0]) or SECRET_FILE.search(args[0]) or any(ch in args[0] for ch in "*?[{$`"):
        return False
    try:
        canonical = os.path.realpath(os.path.expanduser("~/dotfiles/script/secrets-refs.sh"))
        joined = os.path.expanduser(prog or "")
        if not os.path.isabs(joined):
            joined = os.path.join(cwd or os.getcwd(), joined)
        return os.path.isfile(canonical) and os.path.realpath(joined) == canonical
    except (OSError, ValueError):
        return False


def check_secrets_dir(segment, base, args, prog=None, cwd=None):
    """Deny a segment that reads the secrets dir: readers, interpreters, redirects, copies out, cd."""
    text = SECRETS_WRITE_REDIRECT.sub("", segment)
    if not SECRETS_DIR.search(text) or base in SECRETS_NONREAD:
        return
    if any(p.fullmatch(segment.strip()) for p in SECRETS_STDIN_OK):
        return
    if is_sign_in_invocation(prog or base, args) or is_refs_invocation(prog or base, args, cwd):
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
    if SECRETS_DIR_EXCEPTIONS:
        exception = " The exceptions: " + " ".join(SECRETS_DIR_EXCEPTIONS)
    else:
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


def approval_root():
    return os.environ.get("GUARD_APPROVAL_ROOT") or "/usr/local/etc/agent-team"


def approval_read_paths():
    """Where load_approval looks. When the root owned folder exists (script/approval-root-setup.sh ran), only
    files in it count, so a file a worker writes under ~/.config never grants anything."""
    cands = approval_file_candidates()
    root = approval_root()
    if APPROVAL_FILE_OVERRIDE or not os.path.isdir(root):
        return cands
    out = []
    for c in cands:
        p = os.path.join(root, os.path.basename(os.path.dirname(c)), "approval.json")
        if p not in out:
            out.append(p)
    for found in sorted(glob.glob(os.path.join(root, "*", "approval.json"))):
        if found not in out:
            out.append(found)
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
    for path in approval_read_paths():
        if not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                a = json.load(f)
        except Exception:
            last_reason = f"{path} is unreadable"
            continue
        exp = a.get("expires_at") if isinstance(a, dict) else None
        if not isinstance(exp, (int, float)) or isinstance(exp, bool) or exp != exp:  # exp != exp: NaN
            last_reason = f"{path} has no expiry"
            continue
        if exp <= now:
            last_reason = "the last owner approval has expired"
            continue
        if exp > now + SCOPE_TTL_MAX.get(a.get("scope"), APPROVAL_TTL) + 60:
            last_reason = f"{path} claims a longer window than its scope allows, so it is ignored"
            continue
        return a, ""
    return None, last_reason


def host_waived():
    """True before `pre_go_live_host.until`, compared with today in Asia/Taipei (UTC+8, no DST)."""
    if PRE_GO_LIVE_HOST_UNTIL is None:
        return False
    taipei = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
    return taipei.strftime("%Y-%m-%d") < PRE_GO_LIVE_HOST_UNTIL


def approval_for(scopes, target_ok=None, pre_go_live=False):
    if ("host" in scopes or pre_go_live) and host_waived():
        return True, ""
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
                cdir = os.path.join(cdir, args[i + 1]) if cdir else args[i + 1]
            i += 2
        elif a.startswith("-C") and len(a) > 2:
            cdir = os.path.join(cdir, a[2:]) if cdir else a[2:]
            i += 1
        elif a.startswith(("--config-env=", "--exec-path=", "--git-dir=", "--work-tree=", "--namespace=")):
            i += 1
        elif a.startswith("-"):
            i += 1
        else:
            return a, args[i + 1:], cdir
    return None, [], cdir


def matches_branch_list(branch, patterns):
    for pat in patterns:
        if branch == pat or fnmatch.fnmatchcase(branch, pat):
            return True
    return False


def matches_stage_branch(branch):
    return matches_branch_list(branch, STAGE_BRANCHES)


def is_production_branch(branch):
    """A branch the test-data exemption can cover. `production_branches` wins when set.
    Otherwise a stage branch whose last segment is `production` (`production`, `web2/production`)."""
    if PRODUCTION_BRANCHES:
        return matches_branch_list(branch, PRODUCTION_BRANCHES)
    return branch.rsplit("/", 1)[-1] == "production"


PRODUCTION_DATA_LINE = re.compile(
    r"(?im)^\*[ \t]+Production data:[ \t]*(production holds only test data|a real store is live)[ \t]*\.?[ \t]*$"
)
# A conditional in the template ("once a real store is live, it needs the go") is the rule,
# not a claim that a store already exists. An assertion that one does keeps the owner's go.
POLICY_CONDITION = re.compile(
    r"(?i)\b(?:once|when|if|after)\s+a\s+real\s+store\s+is\s+live\b"
)
LIVE_CLAIM = re.compile(
    r"(?i)\b(?:"
    r"real\s+(?:store|(?:customer\s+)?data|customers?|users?|orders?|traffic|transactions?|payments?)"
    r"|live\s+(?:store|data|customers?|users?|orders?|traffic)"
    r"|(?:store|production|product|site|app)\s+is\s+(?:now\s+)?live"
    r"|paying\s+(?:customers?|users?)"
    r"|went\s+live|gone\s+live|launched"
    r")\b"
)


def guard_facts_root():
    """The project whose guard config loaded. `git -C` does not move it."""
    cfg = find_guard_config(GATE_CWD or os.getcwd())
    if not cfg:
        return None
    parent = os.path.dirname(os.path.abspath(cfg))
    if os.path.basename(parent) == "hooks" and os.path.basename(os.path.dirname(parent)) == ".claude":
        return os.path.dirname(os.path.dirname(parent))
    return find_project_root(parent)


def strip_hidden_markup(text):
    """Drop HTML comments and fenced blocks so a status line inside them does not count."""
    text = re.sub(r"(?s)<!--.*?-->", "", text)
    text = re.sub(r"(?s)<!--.*\Z", "", text)
    for fence in ("```", "~~~"):
        text = re.sub("(?s)" + re.escape(fence) + ".*?" + re.escape(fence), "", text)
        text = re.sub("(?s)" + re.escape(fence) + r".*\Z", "", text)
    return text


def states_real_store_is_live(text):
    """True when a line says a real or live store exists.

    The template's conditional ("once a real store is live") is not that claim.
    A sentence that only uses "when" to assert the store is already live still is.
    """
    for line in text.splitlines():
        if LIVE_CLAIM.search(POLICY_CONDITION.sub("", line)):
            return True
    return False


def fetch_origin_main(root):
    """Fetch origin's main and require the remote-tracking ref to follow it.

    A local update of refs/remotes/origin/main must not outvote the remote.
    A failed fetch keeps the owner's go.
    """
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    try:
        fetched = subprocess.run(
            ["git", "-C", root, "fetch", "origin", "main"],
            capture_output=True, text=True, timeout=8, env=env,
        )
    except Exception:
        return False
    if fetched.returncode != 0:
        return False
    tip = git_out("rev-parse", "--verify", "FETCH_HEAD", cwd=root)
    tracked = git_out("rev-parse", "--verify", "refs/remotes/origin/main", cwd=root)
    return bool(tip and tracked and tip == tracked)


def production_holds_test_data():
    """True only after a fresh fetch, for one test-data status line on refs/remotes/origin/main.

    An indented, fenced, or HTML-commented status line does not count. Any line that
    says a real or live store exists keeps the owner's go. A missing blob or a failed
    fetch does too."""
    root = guard_facts_root()
    if not root or not fetch_origin_main(root):
        return False
    shown = gate_run(["git", "-C", root, "show", "refs/remotes/origin/main:docs/agents/deploy-facts.md"], None)
    if shown is None:
        return False
    if states_real_store_is_live(shown):
        return False
    found = [m.group(1).lower() for m in PRODUCTION_DATA_LINE.finditer(strip_hidden_markup(shown))]
    return found == ["production holds only test data"]


def first_brief(transcript_path):
    """The session's first real user message. Tool results and meta lines are not the brief."""
    if not isinstance(transcript_path, str) or not transcript_path:
        return ""
    try:
        with open(transcript_path, encoding="utf-8", errors="replace") as f:
            raw = f.read(65536)
    except OSError:
        return ""
    for line in raw.splitlines():
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if not isinstance(obj, dict) or obj.get("type") != "user" or obj.get("isMeta") or obj.get("toolUseResult"):
            continue
        msg = obj.get("message")
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if isinstance(content, list):
            if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
                continue
            parts = [b.get("text") for b in content if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)]
            if parts:
                return "\n".join(parts)
        elif isinstance(content, str):
            return content
    return ""


def agreed_session_role(text):
    """The brief's `Role:` line and title, when they name the same role.

    A path such as `agents/<role>.md` does not assign the role. A disagreement returns
    nothing, so a production exemption that needs one role does not fire."""
    if not text:
        return ""
    named = re.search(r"(?m)^Role:\s*([a-z0-9-]+)\b", text)
    title = re.search(r"(?m)^#\s*([a-z0-9-]+)\s+-\s+\S", text)
    if not named or not title or named.group(1) != title.group(1):
        return ""
    return named.group(1)


def session_role():
    """The role the worker brief assigns. `Role:` and the title must agree."""
    cached = getattr(session_role, "cached", None)
    if cached is not None:
        return cached[0]
    text = first_brief(HOOK_INPUT.get("transcript_path") if isinstance(HOOK_INPUT, dict) else "")
    role = agreed_session_role(text)
    session_role.cached = (role,)
    return role


def stamped_worker_role(text):
    """The role in the brief's first line, `Worker role: <role>`, which worker-startup.sh stamps (#1328).
    No stamp (a coordinator hand start) returns nothing, so nothing is refused."""
    first = (text or "").lstrip("\ufeff").split("\n", 1)[0].rstrip("\r")
    named = re.fullmatch(r"Worker role: ([a-z0-9-]+)", first)
    return named.group(1) if named else ""


def is_builder_stamp(role):
    return role in ("builder", "fullstack-dev") or role.startswith("fullstack-dev-")


def brief_allowed_files(text):
    """The paths the brief's `Allowed files:` line or `## Allowed files` section names. CRLF is stripped."""
    allowed, sec = set(), ""
    for line in (text or "").splitlines():
        line = line.rstrip("\r")
        body = ""
        for prefix in ("**Allowed files:**", "Allowed files:"):
            if line.startswith(prefix):
                sec, body = "inline", line[len(prefix):]
                break
        else:
            if line.startswith("## Allowed files"):
                sec = "heading"
                continue
            if line.startswith("## "):
                sec = ""
            elif not line.strip():
                if sec != "heading":
                    sec = ""
            elif sec:
                body = line
        for tok in re.split(r"[\s,`\"']+", body):
            tok = re.sub(r"^(?:\./)+", "", tok).rstrip(".;:)")
            if tok:
                allowed.add(tok)
    return allowed


def git_root_of(path):
    cur = os.path.dirname(os.path.abspath(path))
    while True:
        if os.path.exists(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def check_builder_owner_path(tool, full):
    """A builder is refused an Edit or Write on an owner gated path its brief does not allow (#1328)."""
    text = first_brief(HOOK_INPUT.get("transcript_path") if isinstance(HOOK_INPUT, dict) else "")
    if not is_builder_stamp(stamped_worker_role(text)):
        return
    root = git_root_of(full)
    if not root:
        return
    rel = os.path.relpath(os.path.realpath(full), os.path.realpath(root)).replace("\\", "/")
    if rel.startswith("../") or rel in brief_allowed_files(text):
        return
    if rel in ship_protected({rel}):
        deny(f"{tool} on `{rel}` is refused: that path needs the owner, and this brief's `Allowed files:` does not name it. "
             "Take it out of the change, or ask the coordinator to widen the brief.")


GIT_ENV_ASSIGN = re.compile(r"^GIT_[A-Za-z0-9_]*=")


def git_option_values(args, flag):
    out, i = [], 0
    prefix = flag + "="
    while i < len(args):
        a = args[i]
        if a == flag and i + 1 < len(args):
            out.append(args[i + 1])
            i += 2
            continue
        if a.startswith(prefix):
            out.append(a[len(prefix):])
            i += 1
            continue
        if a in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env") and i + 1 < len(args):
            i += 2
            continue
        if a.startswith(("--git-dir=", "--work-tree=", "--namespace=", "--config-env=", "--exec-path=")):
            i += 1
            continue
        if a.startswith("-"):
            i += 1
            continue
        break
    return out


def git_has_config_override(args):
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            break
        if a in ("-c", "--config-env") or a.startswith("--config-env="):
            return True
        if a.startswith("-c") and not a.startswith("--"):
            return True
        if a in ("-C", "--git-dir", "--work-tree", "--namespace") and i + 1 < len(args):
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        break
    return False


def command_moves_git_target():
    """True when the command sets any GIT_* variable or changes directories with pushd/popd/cd -."""
    for text in [RAW_COMMAND, *substitutions(RAW_COMMAND)]:
        for seg in segments(text):
            tokens = words(seg)
            while tokens and tokens[0] in {"if", "then", "else", "elif", "do", "while", "until", "!"}:
                tokens = tokens[1:]
            if any(GIT_ENV_ASSIGN.match(t) for t in tokens):
                return True
            prog, args = program_and_args(tokens)
            base = os.path.basename(prog or "")
            if base in {"pushd", "popd"}:
                return True
            if base == "cd" and (not args or any(a == "-" for a in args)):
                return True
    return False


def _abs_under(base, path):
    expanded = os.path.expanduser(path)
    if os.path.isabs(expanded):
        return expanded
    return os.path.normpath(os.path.join(base, expanded))


def push_repo_is_guard(segment_cwd, cdir, git_args):
    """The test-data waiver applies only when the push stays in the guard's own repo."""
    if command_moves_git_target() or git_has_config_override(git_args or []):
        return False
    root = guard_facts_root()
    if not root:
        return False
    guard_top = git_out("rev-parse", "--show-toplevel", cwd=root)
    guard_git = git_out("rev-parse", "--absolute-git-dir", cwd=root)
    if not guard_top or not guard_git:
        return False
    base = segment_cwd or GATE_CWD or os.getcwd()
    for git_dir in git_option_values(git_args or [], "--git-dir"):
        if os.path.realpath(_abs_under(base, git_dir)) != os.path.realpath(guard_git):
            return False
    for work_tree in git_option_values(git_args or [], "--work-tree"):
        if os.path.realpath(_abs_under(base, work_tree)) != os.path.realpath(guard_top):
            return False
    if cdir:
        base = _abs_under(base, cdir)
    top = git_out("rev-parse", "--show-toplevel", cwd=base)
    if not top or os.path.realpath(top) != os.path.realpath(guard_top):
        return False
    fetch_url = git_out("remote", "get-url", "origin", cwd=root)
    push_url = git_out("remote", "get-url", "--push", "origin", cwd=base)
    return bool(fetch_url and push_url and fetch_url == push_url)


def check_git_push(args, cdir, segment_cwd=None, git_args=None):
    base = segment_cwd or GATE_CWD or os.getcwd()
    cwd = _abs_under(base, cdir) if cdir else base
    force = every = delete = repo_flag = False
    positional, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            positional += args[i + 1:]
            break
        if a in ("-o", "--push-option", "--repo", "--receive-pack", "--exec"):
            repo_flag = repo_flag or a == "--repo"
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
            elif name == "--repo":
                repo_flag = True
        elif a.startswith("-") and len(a) > 1:
            force = force or "f" in a[1:]
            delete = delete or "d" in a[1:]
        else:
            positional.append(a)
        i += 1
    if not positional:
        remote = ""
    elif len(positional) == 1 and (":" in positional[0] or positional[0] == "HEAD"):
        remote = ""
    else:
        remote = positional[0]

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
            if (not forced and is_production_branch(branch) and remote == "origin" and not repo_flag
                    and push_repo_is_guard(segment_cwd, cdir, git_args)
                    and production_holds_test_data()
                    and session_role() == "release-manager"):
                continue
            sha = resolve(src, cwd) or (src if re.fullmatch(r"[0-9a-fA-F]{7,40}", src) else "<sha>")
            scope = "rollback" if forced else "promote"
            ok, why = approval_for({scope}, lambda t: same_commit(src, t, cwd))
            if not ok:
                what = f"Force pushing (rollback) to `{branch}`" if forced else f"Pushing to `{branch}`"
                owner_go(what, f"{APPROVE} {scope} {sha}", why)
        elif forced and any(fnmatch.fnmatchcase(branch, pat) for pat in FORCE_PUSH_BRANCHES):
            ok, why = approval_for({"force-push"}, lambda t: t == branch)
            if not ok:
                owner_go(f"A force push to `{branch}`", f"{APPROVE} force-push {branch}", why)


def remote_read_only(segment):
    text = " ".join(re.split(r"[ \t]+", segment.strip(" \t")))
    if re.search(r"(?:^|[ /=])(?:\.\.|\.ssh)(?:$|[ /])", text):
        return False
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
    # The one quoted form: git's own receive-pack for a push of the release sha to the app checkout.
    # The path is plain, and the command must still equal a configured host_deploy_commands entry.
    scan = joined.replace(" && ", " ", 1)
    if re.fullmatch(r"git-receive-pack '/[A-Za-z0-9._/-]+'", joined):
        scan = ""
    if re.search(r"[#;&|`$()<>\\'\"{}*?\[\]~]", scan):
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
        if i is not None and i < len(raw_args) and hidden_host(raw_args[i]) and raw_args[i] not in LIFTED_HOST_WORDS:
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


def split_promote_chain(remote):
    """Split a remote command on `&&` outside quotes. Refuse `;` (it does not stop on a failed check),
    newlines, comments, backticks, input redirects, background `&` and `||`."""
    if not remote or not printable(remote) or "\n" in remote or "\r" in remote or "#" in remote or "`" in remote:
        return None
    out, buf, quote, i = [], [], None, 0
    while i < len(remote):
        c = remote[i]
        if quote:
            buf.append(c)
            if c == "\\" and quote == '"' and i + 1 < len(remote):
                buf.append(remote[i + 1])
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"":
            quote = c
            buf.append(c)
        elif c in "\\<;":
            return None
        elif remote.startswith("&&", i):
            part = " ".join(re.split(r"[ \t]+", "".join(buf).strip(" \t")))
            if not part:
                return None
            out.append(part)
            buf = []
            i += 1
        elif c == "&":
            if i > 0 and remote[i - 1] == ">" and i + 1 < len(remote) and remote[i + 1].isdigit():
                buf.append(c)
            else:
                return None
        elif remote.startswith("||", i) or remote.startswith("|&", i):
            return None
        else:
            buf.append(c)
        i += 1
    if quote is not None:
        return None
    last = " ".join(re.split(r"[ \t]+", "".join(buf).strip(" \t")))
    if not last:
        return None
    out.append(last)
    return out


_STEP_PATH = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


def promote_host_step(target, remote, opts, cmd_ok):
    """None, or the list of commit refs in remote when remote is a read-only inspection or
    app-checkout Prisma client regeneration covered by a promote approval. The refs bind the
    approval; a regeneration needs one, proved by a HEAD check or checkout earlier in the chain."""
    if not PROMOTE_STEPS or not cmd_ok or any(ch != "o" for ch, _ in opts):
        return None
    host = target.lower()
    if host not in PROMOTE_STEPS["read_hosts"]:
        return None
    segs = split_promote_chain(remote)
    if not segs:
        return None
    app = re.escape(PROMOTE_STEPS["app"])
    app_dir = PROMOTE_STEPS["app"]
    bundle_dir = app_dir + "-bundle"
    path_prefix = rf"(?:PATH={re.escape(_STEP_PATH)} )?"
    schema_hash_stdout = re.compile(
        path_prefix
        + r"""node -e 'process\.stdout\.write\(require\("node:crypto"\)\.createHash\("sha256"\)\.update\(require\("node:fs"\)\.readFileSync\("prisma/schema\.prisma"\)\)\.digest\("hex"\)\)'"""
    )
    client_check = re.compile(
        path_prefix
        + r"""node -e 'const fs=require\("node:fs"\),\s*crypto=require\("node:crypto"\);\s*process\.exit\("""
        + r"""(?:fs\.existsSync\("prisma/generated/client/default\.js"\)\s*&&\s*)?"""
        + r"""fs\.readFileSync\("prisma/generated/client/source-schema\.sha256",\s*"utf8"\)\s*===\s*"""
        + r"""crypto\.createHash\("sha256"\)\.update\(fs\.readFileSync\("prisma/schema\.prisma"\)\)\.digest\("hex"\)\s*\?\s*0\s*:\s*1\)'"""
    )
    schema_hash_assign = re.compile(r"""_schema_hash=\$\(""" + schema_hash_stdout.pattern + r"""\)""")
    client_write_node = re.compile(
        path_prefix
        + r"""node -e 'const fs=require\("node:fs"\),\s*crypto=require\("node:crypto"\);\s*"""
        + r"""fs\.writeFileSync\("prisma/generated/client/source-schema\.sha256",\s*"""
        + r"""crypto\.createHash\("sha256"\)\.update\(fs\.readFileSync\("prisma/schema\.prisma"\)\)\.digest\("hex"\)\)'"""
    )
    shas = [m.group(1) for m in re.finditer(r"(?<![0-9a-fA-F])([0-9a-f]{40})(?![0-9a-fA-F])", remote)]
    cwd = None
    saw_inspect = saw_regen = saw_regen_action = pending_fetch = proved = need_generate = False

    for seg in segs:
        if re.search(r"(?:^|[ /=])(?:\.\.|\.ssh)(?:$|[ /])", seg):  # nothing climbs out of the app directory
            return None
        if pending_fetch:
            m = re.fullmatch(rf"git -C {app} checkout --quiet --detach (?P<sha>[0-9a-f]{{7,40}})", seg)
            if not m:
                return None
            shas.append(m.group("sha"))
            pending_fetch = False
            saw_regen = proved = True
            continue

        m = re.fullmatch(rf"cd ({app}(?:/web|-bundle(?:/current|/schema(?:/web)?)?)?)", seg)
        if m:
            cwd = m.group(1)
            continue

        if seg == f"git -C {app_dir} fetch --quiet origin":
            if host not in PROMOTE_STEPS["write_hosts"]:
                return None
            pending_fetch = True
            saw_regen = True
            continue

        ro = re.sub(r" (?:2>&1|2>/dev/null|>/dev/null)$", "", seg)
        head_match = re.fullmatch(
            rf'(?:test|\[) "\$\(git -C {app} rev-parse HEAD\)" = "?(?P<sha>[0-9a-f]{{7,40}})"?(?: \])?',
            ro,
        )
        if head_match:
            shas.append(head_match.group("sha"))
            saw_inspect = proved = True
            continue

        if ">" not in ro and "$(" not in ro and "|" not in ro:
            m = re.fullmatch(
                rf"git -C {app}(?:/web|-bundle/schema(?:/web)?)? rev-parse (?:--(?:short|verify|quiet) )*(?P<ref>HEAD|[0-9a-f]{{7,40}})(?:\^\{{commit\}})?",
                ro,
            ) or (
                cwd in {app_dir, f"{app_dir}/web", f"{bundle_dir}/schema", f"{bundle_dir}/schema/web"}
                and re.fullmatch(r"git rev-parse (?:--(?:short|verify|quiet) )*(?P<ref>HEAD|[0-9a-f]{7,40})(?:\^\{commit\})?", ro)
            )
            if m:
                if m.group("ref") != "HEAD":
                    shas.append(m.group("ref"))
                saw_inspect = True
                continue

            gen = r"generated/client(?:/[A-Za-z0-9._/-]+)?"
            if (
                re.fullmatch(rf"ls(?: -[1ladrtFh]+)* {app}(?:-bundle)?(?:/[A-Za-z0-9._/@+-]+)?", ro)
                or (cwd == f"{app_dir}/web" and re.fullmatch(r"ls(?: -[1ladrtFh]+)* prisma(?:/generated(?:/client(?:/[A-Za-z0-9._/-]+)?)?)?", ro))
                or re.fullmatch(rf"stat {app}/web/prisma/(?:{gen}|schema\.prisma)", ro)
                or (cwd == f"{app_dir}/web" and re.fullmatch(rf"stat prisma/(?:{gen}|schema\.prisma)", ro))
                or re.fullmatch(rf"(?:test -[efds] {app}/web/prisma/(?:{gen}|schema\.prisma)|\[ -[efds] {app}/web/prisma/(?:{gen}|schema\.prisma) \])", ro)
                or (cwd == f"{app_dir}/web" and re.fullmatch(rf"(?:test -[efds] prisma/(?:{gen}|schema\.prisma)|\[ -[efds] prisma/(?:{gen}|schema\.prisma) \])", ro))
                or re.fullmatch(rf"(?:cat|head(?: -n [0-9]+| -[0-9]+)?|tail(?: -n [0-9]+| -[0-9]+)?) {app}/web/prisma/generated/client/source-schema\.sha256", ro)
                or (cwd == f"{app_dir}/web" and re.fullmatch(r"(?:cat|head(?: -n [0-9]+| -[0-9]+)?|tail(?: -n [0-9]+| -[0-9]+)?) prisma/generated/client/source-schema\.sha256", ro))
                or re.fullmatch(rf"(?:sha256sum|shasum -a 256) {app}/web/prisma/(?:schema\.prisma|generated/client/source-schema\.sha256)(?: {app}/web/prisma/(?:schema\.prisma|generated/client/source-schema\.sha256))?", ro)
                or (cwd == f"{app_dir}/web" and re.fullmatch(r"(?:sha256sum|shasum -a 256) prisma/(?:schema\.prisma|generated/client/source-schema\.sha256)(?: prisma/(?:schema\.prisma|generated/client/source-schema\.sha256))?", ro))
                or (cwd == f"{app_dir}/web" and client_check.fullmatch(ro))
                or (cwd == f"{app_dir}/web" and schema_hash_stdout.fullmatch(ro))
                or re.fullmatch(rf"readlink(?: -[fe])? {app}(?:-bundle)?/(?:current|slots/(?:blue|green)|releases/[0-9a-f]{{40}})", ro)
                or (cwd in {app_dir, bundle_dir} and re.fullmatch(r"readlink(?: -[fe])? current", ro))
            ):
                saw_inspect = True
                continue

        if host in PROMOTE_STEPS["write_hosts"]:
            if (
                re.fullmatch(rf"rm -rf {app}/web/prisma/generated/client", seg)
                or (cwd == f"{app_dir}/web" and seg == "rm -rf prisma/generated/client")
            ):
                if not proved:
                    return None
                saw_regen = need_generate = True
                continue

            if cwd == f"{app_dir}/web" and schema_hash_assign.fullmatch(seg):
                saw_regen = True
                continue

            is_generate = (
                (cwd == f"{app_dir}/web" and re.fullmatch(path_prefix + rf"(?:bunx prisma generate|bun run generate)(?: --schema(?:=| )(?:{app}/web/)?prisma/schema\.prisma)?", seg))
                or re.fullmatch(path_prefix + rf"bunx prisma generate --schema(?:=| ){app}/web/prisma/schema\.prisma", seg)
            )
            if (
                is_generate
                or re.fullmatch(path_prefix + rf"node {app}/web/scripts/link-prisma-client-default\.js", seg)
                or (cwd == f"{app_dir}/web" and re.fullmatch(path_prefix + r"node scripts/link-prisma-client-default\.js", seg))
                or re.fullmatch(rf"""printf '%s' "\$\{{?_schema_hash\}}?" > {app}/web/prisma/generated/client/source-schema\.sha256""", seg)
                or (cwd == f"{app_dir}/web" and re.fullmatch(r"""printf '%s' "\$\{?_schema_hash\}?" > prisma/generated/client/source-schema\.sha256""", seg))
                or re.fullmatch(rf"""(?:sha256sum|shasum -a 256) {app}/web/prisma/schema\.prisma \| (?:cut -d" " -f1|cut -d' ' -f1|awk '\{{print \$1\}}') > {app}/web/prisma/generated/client/source-schema\.sha256""", seg)
                or (cwd == f"{app_dir}/web" and re.fullmatch(r"""(?:sha256sum|shasum -a 256) prisma/schema\.prisma \| (?:cut -d" " -f1|cut -d' ' -f1|awk '\{print \$1\}') > prisma/generated/client/source-schema\.sha256""", seg))
                or (cwd == f"{app_dir}/web" and client_write_node.fullmatch(seg))
            ):
                if not proved:
                    return None
                if is_generate:
                    need_generate = False
                saw_regen = True
                saw_regen_action = True
                continue

        return None

    if pending_fetch or need_generate or (saw_regen and not saw_regen_action) or (not saw_inspect and not saw_regen_action):
        return None
    if saw_regen_action and not shas:  # regeneration must name the release it is for
        return None
    return shas


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
    step = promote_host_step(args[dest], remote, opts, cmd == dest + 1)
    if step is not None:
        for seg in segments(remote):
            check_segment(seg, depth + 1)  # secrets rules still apply on the host
        ok, _ = approval_for({"host"})
        if not ok:
            ok, why = approval_for({"promote"}, lambda t: bool(t) and all(same_commit(s, t) for s in step))
        if not ok:
            want_sha = next(iter(step), "<sha>")
            owner_go(f"`{remote}` on the production host",
                     f"{APPROVE} promote {want_sha}` or `{APPROVE} host", why)
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


def approval_secret_file():
    return os.path.join(os.path.dirname(primary_approval_file()), "approval-secret")


def approval_dir_glob():
    """A glob into the approval folder could match the secret file."""
    ns = re.escape(APPROVAL_NAMESPACE) if APPROVAL_NAMESPACE else r"[^/\s'\"]+"
    dirs = [r"\.config/(?:[^/\s'\"]*[*?\[][^/\s'\"]*|" + ns + ")"]
    if APPROVAL_FILE_OVERRIDE:
        dirs.append(re.escape(os.path.dirname(APPROVAL_FILE_OVERRIDE)))
    return re.compile("(?:" + "|".join(dirs) + r")/?[^\s'\"]*[*?\[]")


def names_approval_secret(text):
    if APPROVAL_SECRET_ENV in text or APPROVAL_SECRET_PATH.search(text) or APPROVAL_SECRET_BARE.search(text):
        return True
    if APPROVAL_FILE_OVERRIDE and os.path.join(os.path.dirname(APPROVAL_FILE_OVERRIDE), "approval-secret") in text:
        return True
    return bool(approval_dir_glob().search(text))


def deny_approval_secret():
    deny(f"{approval_secret_file()} and {APPROVAL_SECRET_ENV} sign the owner's sysadmin approval: an agent never "
         "reads them, with any program. Only the owner's own terminal and the server use the secret.")


def check_approval_secret(segment, base, args):
    """Deny a command that names the approval secret file or env name, or globs into the approval folder.
    Prose mentions (echo, commit messages) stay allowed, as for the approval file."""
    tokens = words(segment)
    skip = prose_tokens(tokens) if (text_program(base, args) or base in {"echo", "printf"}) else set()
    if any(i not in skip and names_approval_secret(t) for i, t in enumerate(tokens)):
        deny_approval_secret()


def check_approval_secret_read(path):
    if not path:
        return
    full = os.path.normpath(os.path.join(GATE_CWD or os.getcwd(), os.path.expanduser(path)))
    for p in {full, os.path.realpath(full)}:
        if (os.path.basename(p) == "approval-secret" and APPROVAL_SECRET_PATH.search(p)) or (
                APPROVAL_FILE_OVERRIDE and p == os.path.join(os.path.dirname(APPROVAL_FILE_OVERRIDE), "approval-secret")):
            deny_approval_secret()


def check_risky(segment, base, args, depth, segment_cwd=None):
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

    pre_go_live = (script == PRE_GO_LIVE_SCRIPT and PRE_GO_LIVE_UNTIL is not None
                   and time.strftime("%Y-%m-%d", time.gmtime()) < PRE_GO_LIVE_UNTIL
                   and pre_go_live_command(script_args))
    if script in APPLY_SCRIPTS and not pre_go_live:
        sha = script_args[0] if script_args else "<sha>"
        a, why = load_approval()
        ok = (re.fullmatch(r"[0-9a-f]{40}", sha) and a and a.get("scope") == "promote" and a.get("target") == sha
              and a.get("schema") is True and a.get("apply") is True)
        if ok and script == "run-production-data-step.sh":
            ok = len(script_args) == 2 and bool(re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", script_args[1]))
            if not ok:
                why = "run-production-data-step.sh takes only <release-sha> and <step-name>"
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
        ok, why = approval_for({"promote"}, (lambda t: same_commit(sha_arg, t)) if sha_arg else None,
                              pre_go_live=True)
        a, _ = load_approval()
        if not ok or not (host_waived() or (a or {}).get("schema")):
            owner_go(f"{SCHEMA_OVERRIDE}=1 (a production schema push)", f"{APPROVE} promote {sha} --schema",
                     why or "the approval on file does not cover the schema")

    if promo is not None:
        comp = promo.get("component") or ""
        if re.search(r"[$`]", sha_arg + comp) or not sha_arg:
            deny(f"Pass {script} the literal sha, so it can be matched against the owner's "
                 f"approval: {script} <sha>. The owner approves it with `{APPROVE} promote <sha>`.")
        sha = resolve(sha_arg) or sha_arg or "<sha>"
        ok, why = approval_for({"promote", "rollback"}, lambda t: same_commit(sha_arg, t), pre_go_live=True)
        if not ok:
            owner_go(f"Promoting {sha} to production", f"{APPROVE} promote {sha}", why)

    if script in ROLLBACK_SCRIPTS:
        if re.search(r"[$`]", sha_arg) or not sha_arg:
            deny(f"Pass {script} the literal sha, so it can be matched against the owner's "
                 f"approval: {script} <sha>. The owner approves it with `{APPROVE} rollback <sha>`.")
        sha = resolve(sha_arg) or sha_arg or "<sha>"
        ok, why = approval_for({"rollback"}, lambda t: same_commit(sha_arg, t), pre_go_live=True)
        if not ok:
            owner_go(f"Rolling production back to {sha}", f"{APPROVE} rollback {sha}", why)

    if base == "git":
        check_git_ssh(args)
        sub, rest, cdir = git_subcommand(args)
        if sub == "push":
            check_git_push(rest, cdir, segment_cwd, args)

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

    # An admin merge bypasses branch protection: only inside the owner's `merge` window.
    if base == "gh" and any(args[i:i + 2] == ["pr", "merge"] for i in range(len(args))) \
            and any(a.startswith("--admin") for a in args):
        ok, why = approval_for({"merge"})
        if not ok:
            owner_go("An admin merge (gh pr merge --admin)", f"{APPROVE} merge [<hours>]", why)

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
GRILL_LINE = re.compile(
    r"(?i)\Agrill approved:[ \t]+(coordinator|owner|elon)[ \t]+(\d{4}-\d{2}-\d{2})\Z"
)
GRILL_EXEMPT_LABELS = ("p0",)
# Fail closed. Any of these in the title, body, or a label keeps the grill gate.
# "pay" and "plan" are whole words so "payload" and "planning" stay ordinary.
MONEY_WORD = re.compile(
    r"(?i)(?:\b(?:prices?|pricing|fees?|refund\w*|payments?|pay|paid|payouts?|"
    r"charg(?:e|es|ed|ing)|costs?|costing|tuitions?|checkouts?|deposits?|"
    r"subscriptions?|plans?|discount\w*|coupons?|wallets?|balances?|"
    r"top[ -]?ups?|credits?|billing|invoices?|tax(?:es|ed|able|ing)?|"
    r"memberships?|money|ledgers?|entitlements?)\b|(?:NT|US|HK)?\$\s*\d)"
)
MONEY_ZH = re.compile(
    "價格|價錢|價目|定價|售價|付款|付費|退款|退費|收費|收款|學費|運費|費用|"
    "儲值|加值|結帳|金額|訂閱|方案|折扣|優惠|點數|金流|發票"
)
REMOTE_FLAGS = ("--on", "--environment", "--pairing-code")


def gate_run(cmd, cwd):
    try:
        out = subprocess.run(cmd, cwd=cwd or GATE_CWD, capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    return out.stdout if out.returncode == 0 else None


def is_protected(path):
    return any(path.startswith(p) if p.endswith("/") else path == p for p in PROTECTED_PATHS)


PROTECTED_PATHS_LIB_REL = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "script", "lib", "protected-paths.sh")
)
# check_owner_only_paths reads $files through jq and calls refuse; both are stubbed to report the path.
PROTECTED_PATHS_SCRIPT = (
    'source "$1" || exit 1; shift\n'
    'jq() { printf "%s\\n" "$p"; }\n'
    'refuse() { hit=1; }\n'
    'intent_acceptance_receipt() { :; }\n'
    'for p; do hit=0; check_owner_only_paths; protected_path "$p" && hit=1; [ "$hit" = 1 ] && printf "%s\\n" "$p"; done\n'
)


def ship_protected(paths):
    """The paths script/lib/protected-paths.sh (the ship.sh set) protects. Empty when that file is not found."""
    lib = os.environ.get("PROTECTED_PATHS_LIB")
    if not lib:
        lib = PROTECTED_PATHS_LIB_REL
        if not os.path.isfile(lib):
            lib = os.path.join(os.environ.get("DOTFILES") or os.path.expanduser("~/dotfiles"),
                               "script", "lib", "protected-paths.sh")
    if not paths or not os.path.isfile(lib):
        return set()
    out = gate_run(["bash", "-c", PROTECTED_PATHS_SCRIPT, "_", lib, *sorted(paths)], None)
    return set(out.split()) if out else set()


def option_value(args, name):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return None


def git_verb(args):
    """(verb, its args, the -C, --git-dir and --work-tree options that name the repo)."""
    i, repo = 0, []
    while i < len(args):
        a = args[i]
        if a in ("-C", "--git-dir", "--work-tree") and i + 1 < len(args):
            repo += [a, os.path.expanduser(args[i + 1])]
            i += 2
        elif a.startswith(("--git-dir=", "--work-tree=")):
            repo += a.split("=", 1)
            i += 1
        elif a in ("-c", "--namespace", "--config-env"):
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            return a, args[i + 1:], repo
    return None, [], repo


def commit_message_file(rest, repo):
    """The text of `commit -F <file>` / `--file`, read where git reads it (after each -C). Not a FIFO."""
    path = option_value(rest, "-F") or option_value(rest, "--file")
    if not path or path == "-":
        return ""
    folder = GATE_CWD or os.getcwd()
    for flag, value in zip(repo[::2], repo[1::2]):
        if flag == "-C":
            folder = os.path.join(folder, value)
    full = os.path.join(folder, os.path.expanduser(path))
    try:
        if os.path.isfile(full):
            with open(full, errors="replace") as f:
                return f.read(65536)
    except OSError:
        pass
    return ""


def deny_role_files(files, how):
    deny(f"{how} touches {', '.join(sorted(files))}, which only the owner approves. Add an "
         "`Owner-approved: <name> <date>` trailer to the commit message once the owner has said yes "
         "(never before; or by the coordinator when the change only copies owner-approved rules, "
         "citing the source decisions per ~/dotfiles/templates/agent-team/docs/agents/team.md, Role changes), "
         "or take those files out of the change. In an adopted project, edit "
         "`.claude/hooks/guard-config.json`, `.claude/settings.project.json`, `docs/agents/team-facts.md`, "
         "or `dotfiles/templates/agent-team/` instead.")


def matches_main(git, rel, rest):
    """True when the staged blob of `rel` equals its blob at MERGE_HEAD (a merge in progress) or origin/main.
    A file the merge deleted (absent from the index and at MERGE_HEAD) also matches.
    Not for `commit -a`, where the staged copy is not what lands."""
    if "--all" in rest or any(a.startswith("-") and not a.startswith("--") and "a" in a for a in rest):
        return False
    staged = (gate_run([*git, "rev-parse", f":{rel}"], None) or "").strip()
    if not staged:
        merging = gate_run([*git, "rev-parse", "-q", "--verify", "MERGE_HEAD"], None)
        if merging is None:
            return False
        return not (gate_run([*git, "rev-parse", f"MERGE_HEAD:{rel}"], None) or "").strip()
    for ref in ("MERGE_HEAD", "refs/remotes/origin/main"):
        theirs = (gate_run([*git, "rev-parse", f"{ref}:{rel}"], None) or "").strip()
        if theirs and theirs == staged:
            return True
    return False


def check_role_file_gate(base, args):
    root = find_project_root(GATE_CWD or os.getcwd())
    adopted = is_adopted_project(root) and not sync_enabled(RAW_COMMAND)
    git = ["git"]
    if base == "git":
        verb, rest, repo = git_verb(args)
        git += repo
        if verb == "commit":
            staged = set((gate_run([*git, "diff", "--cached", "--name-only"], None) or "").split())
            if "--all" in rest or any(a.startswith("-") and not a.startswith("--") and "a" in a for a in rest):
                staged |= set((gate_run([*git, "diff", "--name-only"], None) or "").split())
            if adopted:
                managed = sorted(f for f in staged if is_template_managed_rel(f)
                                 and not matches_main(git, f, rest))
                if managed:
                    deny_template_managed(managed[0])
            staged = {f for f in staged if not (adopted and is_template_managed_rel(f) and matches_main(git, f, rest))}
            files = {f for f in staged if is_protected(f)} | ship_protected(staged)
            if files and not OWNER_TRAILER.search(RAW_COMMAND + "\n" + commit_message_file(rest, repo)):
                deny_role_files(files, "This commit")
            return
        if verb != "push":
            return
    elif not (base == "gh" and args[:2] == ["pr", "create"]):
        return
    # Push or PR create: every commit not yet on origin/main that touches a protected path needs the trailer.
    #shas = (gate_run([*git, "rev-list", "origin/main..HEAD"], None) or "").split()
    shas = (gate_run([*git, "rev-list", "refs/remotes/origin/main..HEAD"], None) or "").split()

    for sha in shas:
        changed = (gate_run([*git, "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", sha], None) or "").split()
        files = {f for f in changed if is_protected(f)}
        message = gate_run([*git, "show", "-s", "--format=%B", sha], None) or ""
        if files and not OWNER_TRAILER.search(message):
            deny_role_files(files, f"Commit {sha[:9]}")


DOTFILES_ISSUE = re.compile(r"(?:([\w.-]+/)?dotfiles)#(\d{3,6})\b")
FIRST_REFS = re.compile(r"\bRefs\s+((?:[\w.-]+/)?[\w.-]*)#\d+")
REMOTE_REPO = re.compile(r"[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?$")


def dotfiles_repo(spec):
    """`owner/dotfiles`: DOTFILES_REPO, else the owner on a `<owner>/dotfiles#N` ref, else the dotfiles checkout's origin."""
    if os.environ.get("DOTFILES_REPO"):
        return os.environ["DOTFILES_REPO"]
    for item in DOTFILES_ISSUE.finditer(spec):
        if item.group(1):
            return item.group(1) + "dotfiles"
    url = (gate_run(["git", "-C", os.path.expanduser("~/dotfiles"), "remote", "get-url", "origin"], None) or "").strip()
    match = REMOTE_REPO.search(url)
    return match.group(1) if match else None
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


HEREDOC = re.compile(r"(?<!<)<<-?(?!<)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
SPEC_HEREDOC = re.compile(r"(?s)\$\(\s*cat\s*<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1[ \t]*\n(.*?)\n[ \t]*\2[ \t]*\n?\s*\)")
SPEC_CAT = re.compile(r"\$\(\s*(?:cat\s+|<\s*)([^\s()`]+)\s*\)|`\s*cat\s+([^\s`]+)\s*`")
SHELL_EXPANSION = re.compile(r"\$[A-Za-z_{(]|`")


def heredocs(command):
    """[(the line that opens it, its body)] for each heredoc in the command."""
    lines, out, i = command.split("\n"), [], 0
    while i < len(lines):
        line = lines[i]
        i += 1
        for m in HEREDOC.finditer(line):
            body = []
            while i < len(lines) and lines[i].strip() != m.group(2):
                body.append(lines[i])
                i += 1
            i += 1
            out.append((line, "\n".join(body)))
    return out


def brief_text(path):
    """A brief's text: the heredoc in this command that writes it (for `-`, the one that feeds
    worker-start), else the file. None when neither has it."""
    if path == "-":
        found = re.compile(r"\bworker-start\b")
    else:
        found = re.compile(r"(?<![\w./~$-])" + re.escape(path) + r"(?![\w./-])")
    for opener, body in heredocs(RAW_COMMAND):
        if found.search(opener):
            return body + "\n"
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


def money_text(text):
    return bool(MONEY_WORD.search(text) or MONEY_ZH.search(text))


def money_or_price_issue(issue):
    """A money or price word in the title, body, or any label. One match keeps the gate."""
    labels = issue.get("labels")
    if labels is None:
        labels = []
    elif not isinstance(labels, list):
        return True
    for label in labels:
        if isinstance(label, dict):
            name = str(label.get("name", ""))
        elif isinstance(label, str):
            name = label
        else:
            continue
        if money_text(name):
            return True
    return money_text("\n".join([str(issue.get("title") or ""), str(issue.get("body") or "")]))


def comment_login(comment):
    author = comment.get("author")
    if isinstance(author, dict):
        return str(author.get("login") or "").strip().lower()
    if isinstance(author, str):
        return author.strip().lower()
    return ""


def comment_is_trusted(comment):
    """Owner association or a grill_approvers login.

    On this fleet every agent posts as the owner, so this is a speed bump against a
    missing login, not proof of which agent wrote the line. team.md says so.
    """
    login = comment_login(comment)
    if not login:
        return False
    if str(comment.get("authorAssociation") or "").strip().upper() == "OWNER":
        return True
    return login in GRILL_APPROVERS


def grill_record_ok(comment):
    """An exact approval line from the repo owner or a configured coordinator login."""
    if not isinstance(comment, dict) or not GRILL_LINE.search(str(comment.get("body") or "").strip()):
        return False
    return comment_is_trusted(comment)


def elon_take_over_ok(comment):
    """The same author check as the grill record. The phrase alone is not enough."""
    if not isinstance(comment, dict):
        return False
    if "elon take over" not in str(comment.get("body") or "").lower():
        return False
    return comment_is_trusted(comment)


def load_issue(number, repo_args):
    raw = gate_run(
        ["gh", "issue", "view", number, *repo_args, "--json", "title,labels,body,comments"], None)
    if raw is None or not str(raw).strip():
        return None
    try:
        issue = json.loads(raw)
    except Exception:
        return None
    if not isinstance(issue, dict):
        return None
    return issue


def named_issues(spec, args):
    """Every issue the spec or `--worktree issue:<n>` names, in the order they appear."""
    found, seen = [], set()

    def add(number, repo_args, repo_name):
        key = (number, repo_name)
        if key in seen:
            return
        seen.add(key)
        shown = f"{repo_name}#{number}" if repo_name else f"#{number}"
        found.append((number, repo_args, shown))

    selector = option_value(args, "--worktree") or ""
    match = re.fullmatch(r"issue:(\d+)", selector)
    if match:
        add(match.group(1), [], "")
    occupied = [item.span() for item in DOTFILES_ISSUE.finditer(spec)]
    first = FIRST_REFS.search(spec)
    # A bare #N follows the repo of the brief's first Refs line when that line names the dotfiles repo.
    bare_in_dotfiles = bool(first and DOTFILES_ISSUE.fullmatch(first.group(0)[len("Refs"):].strip()))
    repo = dotfiles_repo(spec) if occupied else None
    for item in DOTFILES_ISSUE.finditer(spec):
        if repo is None:
            deny("A brief names a dotfiles issue, but the dotfiles repo is unknown. Set DOTFILES_REPO, write "
                 "`<owner>/dotfiles#<n>`, or make ~/dotfiles a checkout with an origin remote.")
        add(item.group(2), ["-R", repo], repo)
    for item in re.finditer(r"(?:issues/|#)(\d{3,6})\b", spec):
        if any(start <= item.start() < end for start, end in occupied):
            continue
        if bare_in_dotfiles and repo:
            add(item.group(1), ["-R", repo], repo)
        else:
            add(item.group(1), [], "")
    return found


def issue_is_exempt(issue):
    names = []
    for label in issue.get("labels") or []:
        if isinstance(label, dict):
            names.append(str(label.get("name") or ""))
        elif isinstance(label, str):
            names.append(label)
    if any(name.strip().lower() in GRILL_EXEMPT_LABELS for name in names):
        return True
    return any(elon_take_over_ok(comment) for comment in issue.get("comments") or [] if isinstance(comment, dict))


def check_grill_gate(args, spec):
    if "fullstack-dev" not in spec:
        return
    refs = named_issues(spec, args)
    if not refs:
        deny("This build worker names no issue number, so a money rule or price issue cannot be told apart from "
             "other work. Name the issue (`#<n>`) in the spec, or use `--worktree issue:<n>`.")
    for number, repo_args, shown in refs:
        issue = load_issue(number, repo_args)
        if issue is None:
            deny(f"Issue {shown} could not be read, so a money rule or price cannot be told apart from other work. "
                 "The build stays stopped until `gh issue view` returns the issue.")
        labels = issue.get("labels")
        comments = issue.get("comments")
        if labels is None:
            labels = []
        if comments is None:
            comments = []
        if not isinstance(labels, list) or not isinstance(comments, list):
            deny(f"Issue {shown} could not be read, so a money rule or price cannot be told apart from other work.")
        issue = dict(issue, labels=labels, comments=comments)
        if issue_is_exempt(issue) or not money_or_price_issue(issue):
            continue
        if not any(grill_record_ok(comment) for comment in comments):
            deny(f"Missing: a comment on {shown} recording the coordinator's approval of the grill results "
                 "(~/dotfiles/templates/agent-team/docs/agents/team.md, Pre-build grill gate). "
                 "The comment is one line, `Grill approved: coordinator <YYYY-MM-DD>`, "
                 "`Grill approved: owner <YYYY-MM-DD>`, or `Grill approved: elon <YYYY-MM-DD>`, "
                 "written by the coordinator or the owner. "
                 "Money rules and prices need that record before the build starts. "
                 "The owner checks the same issue at merge. "
                 "P0 and \"Elon take over\" work are exempt.")


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
            spec = "\n".join([" ".join(args), brief])
        else:
            brief, spec = inline_spec_text(option_value(args, "--spec") or "", args)
    check_grill_gate(args, spec)
    check_brief_lint(brief)


def inline_spec_text(spec, args):
    """(the brief, the text the grill gate reads) for `--spec`. `$(cat f)`, `$(< f)` and a heredoc inside
    `$(...)` reach the hook unexpanded, so read them here. Any other expansion, or a file the hook cannot
    read, falls back to the whole command, so the grill check is never skipped."""
    texts = []

    def expand(m):
        text = m.group(3) + "\n" if m.re is SPEC_HEREDOC else brief_text(m.group(1) or m.group(2))
        texts.append(text)
        return text or ""

    brief = SPEC_CAT.sub(expand, SPEC_HEREDOC.sub(expand, spec))
    rest = SPEC_CAT.sub("", SPEC_HEREDOC.sub("", spec))
    if None in texts or SHELL_EXPANSION.search(rest):
        return spec, RAW_COMMAND
    return brief, "\n".join([" ".join(args), *texts])


TEST_IDENTITY = "test@example.invalid"


def check_test_identity(base, args):
    """Refuse a commit or push signed as the test suites' identity outside a temp checkout (#844)."""
    if base != "git":
        return
    verb = git_verb(args)[0]
    if verb not in ("commit", "push"):
        return
    root = (gate_run(["git", "rev-parse", "--show-toplevel"], None) or "").strip()
    if not root:
        return
    temp = os.path.realpath(tempfile.gettempdir())
    if os.path.realpath(root).startswith(temp + os.sep):
        return
    idents = " ".join(gate_run(["git", "var", name], None) or "" for name in ("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"))
    if TEST_IDENTITY in idents or TEST_IDENTITY in RAW_COMMAND:
        deny(f"Git identity {TEST_IDENTITY} belongs to the test suites and is refused for real commits and pushes. "
             "Unset GIT_AUTHOR_EMAIL and GIT_COMMITTER_EMAIL (and any `-c user.email=`), or fix `git config user.email`, then retry.")


SETTLED_STATES = ("succeeded", "failed", "stopped", "abandoned", "rejected")


def check_settled_recipient(base, args):
    """Refuse mail to a terminal whose every dispatch is settled or released: Orca would open a
    "New messages" follow-up dispatch on that dead terminal and it would fail with terminal_exited (#1221).
    Fails open when the worker list cannot be read."""
    if base == "orca" and args[:2] == ["orchestration", "send"]:
        pass
    elif base != "orca-reply.sh":
        return
    target = option_value(args, "--to")
    if not target or not target.startswith(("term_", "ctx_", "dispatch:")):
        return
    dispatch = target.removeprefix("dispatch:")
    out = gate_run(["orca", "orchestration", "worker-list", "--json", "--limit", "100"], None)
    try:
        workers = json.loads(out)["result"]["workers"]
    except Exception:
        return
    rows = [w for w in workers if isinstance(w, dict) and (w.get("terminal") == target or w.get("dispatchId") == dispatch)]
    if rows and all(w.get("terminalState") == "released" or w.get("state") in SETTLED_STATES for w in rows):
        deny(f"{target} belongs to a settled or released dispatch, so mail to it would open a 'New messages' follow-up "
             "that fails with terminal_exited. Start a fresh dispatch for the new work instead.")


def check_team_gates(base, args):
    check_test_identity(base, args)
    check_role_file_gate(base, args)
    check_settled_recipient(base, args)
    if base == "orca" and args[:2] == ["orchestration", "worker-start"]:
        check_worker_start(args)
    elif base == "start-cursor-worker.sh":
        check_worker_start(args, script=True)


INTERPRETERS = re.compile(r"^(python[0-9.]*|perl[0-9.]*|ruby[0-9.]*|node|nodejs|php[0-9.]*)$")
INLINE_CODE_FLAG = re.compile(r"^(-[A-Za-z]*[ceEpr]|--eval|--print)$")
GLUED_PERL_CODE = re.compile(r"^-[A-Za-z]*?[eE](.+)$", re.S)  # `perl -esystem...`, `-lesystem`, `-neeval` (#1383)
STARTS_PROCESS = re.compile(r"\b(system|popen\w*|exec\w*|spawn\w*|posix_spawn\w*|subprocess|child_process|pty|"
                            r"__import__|importlib|eval|qx|Open3|shell_exec|passthru|proc_open)\b")
SHELL_OPTS_WITH_ARG = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
REDIRECT = re.compile(r"^[0-9]*(<|>|&>)")
INDIRECT = []  # set by check_indirection; main denies once no specific gate has


def shell_reads_stdin(args):
    """True when a shell (no -c) takes its commands from stdin: a pipe, here-string or heredoc."""
    i = 0
    while i < len(args):
        a = args[i]
        if a in SHELL_OPTS_WITH_ARG:
            i += 2
            continue
        if a.startswith("<<"):
            return True
        if REDIRECT.match(a):
            if a.startswith("<"):
                return False  # `sh < file` runs a file, like `sh file`
            i += 2 if re.fullmatch(r"[0-9]*(>>?|&>>?|>&)", a) else 1
            continue
        if a == "-" or a == "-s" or (a.startswith("-") and "s" in a[1:] and not a.startswith("--")):
            return True
        if not a.startswith(("-", "+")):
            return False
        i += 1
    return True


# An allowlist, not a parser (#1360). A word is plain text or one whole single quoted string, never a find
# action that runs a program or writes a file. Any command outside this grammar scans the whole command.
_PLAIN = r"[A-Za-z0-9_.,/%=+:@-]+"
_WORD = rf"(?!'?-(?:exec|ok|delete|fprint|fls))(?:{_PLAIN}|'[^'\n]*')"
_FIND_STAT = rf"find(?: {_WORD})*? -exec stat(?: {_WORD})*? \{{\}} (?:\+|\\;)"
_PYTHON_STDIN = re.compile(
    rf"(?:{_FIND_STAT}(?: > {_PLAIN})?\n)*(?:{_FIND_STAT} \| )?python3(?: -(?: {_PLAIN})*)? "
    r"<<'([A-Za-z_][A-Za-z0-9_]*)'\n")


def proven_python_stdin_body(command):
    """The heredoc body when the whole command is `find ... -exec stat {} +` lines and then one
    `python3 - <<'TAG'` heredoc that ends the command. None for any other command (fail closed)."""
    try:
        m = _PYTHON_STDIN.match(command)
        if not m:
            return None
        lines = command[m.end():].split("\n")
        end = lines.index(m.group(1))
        return None if any(lines[end + 1:]) else "\n".join(lines[:end])
    except Exception:
        return None


def check_indirection(base, args):
    if base in SHELLS:
        idx = next((i for i, a in enumerate(args) if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a)), None)
        if idx is None:
            if shell_reads_stdin(args):
                INDIRECT.append(f"`{base}` reading commands from a pipe, here-string or heredoc hides them from the "
                                "guard. Run the commands directly, or as `bash -c '<command>'`.")
        elif idx + 1 < len(args):
            for seg in segments(args[idx + 1]):
                prog = program_and_args(words(seg))[0] or ""
                if prog.startswith(("$(", "`")):
                    INDIRECT.append(f"`{base} -c` running the output of a command substitution hides the command "
                                    "from the guard. Run the inner command directly.")
    elif INTERPRETERS.match(base):
        if base.startswith("perl"):
            glued = [" ".join([m[1], *args[i + 1:]]) for i, a in enumerate(args) if (m := GLUED_PERL_CODE.match(a))]
            if any(STARTS_PROCESS.search(code) or "`" in code for code in glued):
                INDIRECT.append(f"`{base}` code that starts a process (os.system, subprocess, system, child_process "
                                "...) hides the command from the guard. Run the command directly.")
        idx = next((i for i, a in enumerate(args) if INLINE_CODE_FLAG.match(a)), None)
        operand = next((a for a in args if not a.startswith("-") and not REDIRECT.match(a)), None)
        if idx is not None:
            code = " ".join(args[idx + 1:])
        elif operand is None or "-" in args:
            code = proven_python_stdin_body(RAW_COMMAND) if base == "python3" else None
            if code is None:
                code = CODE_COMMAND
        else:
            return
        if STARTS_PROCESS.search(code) or (base.startswith(("perl", "ruby")) and "`" in code):
            INDIRECT.append(f"`{base}` code that starts a process (os.system, subprocess, system, child_process ...) "
                            "hides the command from the guard. Run the command directly.")


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
    try:
        check_team_gates(base, args)
    except Exception:
        pass  # a bug in a team gate must not skip the production guards below
    check_approval_secret(segment, base, args)
    check_risky(segment, base, args, depth, transfer_cwd)
    lead = 0
    while lead < len(tokens) and tokens[lead] in {"if", "then", "else", "elif", "do", "while", "until", "!"}:
        lead += 1
    ind_prog, ind_args = program_and_args(tokens[lead:])
    if ind_prog:
        check_indirection(os.path.basename(ind_prog), ind_args)

    # Heavy jobs must acquire the shared machine budget.
    try:
        heavy_tokens = shlex.split(segment, comments=True)
        while heavy_tokens and heavy_tokens[0] in {"if", "then", "else", "elif", "do", "while", "until", "!"}:
            heavy_tokens = heavy_tokens[1:]
        heavy_prog, heavy_args = program_and_args(heavy_tokens)
    except ValueError:
        heavy_tokens, heavy_prog, heavy_args = [], None, []
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

    # Only the coordinator calibrates the machine budget (team.md, Heavy jobs). A worker session has a role in its brief.
    if (any(os.path.basename(t) == "hw-probe.sh" for t in heavy_tokens)
            and any(t == "--calibrate" or t.startswith("--calibrate=") for t in heavy_tokens)):
        brief = first_brief(HOOK_INPUT.get("transcript_path") if isinstance(HOOK_INPUT, dict) else "")
        worker = stamped_worker_role(brief) or session_role()
        if worker and worker != "coordinator":
            deny(f"hw-probe.sh --calibrate is the coordinator's job, and this session is {worker}. "
                 "Ask the coordinator to run it at a quiet time.")

    # 1. Raw deploy scripts.
    if base in BLOCKED_SCRIPTS:
        deny(f"{base} runs only inside the deploy pipeline (the deploy wrapper through /deploy). "
             "Reading, grepping, editing or committing the file is fine; running it is not.")
    if base == "eval":
        for text in [" ".join(args), *substitutions(" ".join(args))]:
            check_hidden_script_paths(text, transfer_cwd)
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
                    check_hidden_script_paths(text, transfer_cwd)
                    cur_cwd = transfer_cwd
                    for seg in segments(text):
                        check_segment(seg, depth + 1, cwd=cur_cwd)
                        p2, a2 = program_and_args(words(seg))
                        if p2 in ("cd", "pushd") and a2:
                            dest = next((x for x in a2 if not x.startswith("-")), None)
                            if dest:
                                cur_cwd = os.path.normpath(os.path.join(cur_cwd or os.getcwd(), os.path.expanduser(dest)))
        else:
            script = next((a for a in args if not a.startswith("-")), None)
            if script and os.path.basename(script) in BLOCKED_SCRIPTS:
                deny(f"{os.path.basename(script)} runs only inside the deploy pipeline (the deploy wrapper).")
            if script and "$" in script:  # #1795: each variable in the name could be any text
                parts = re.split(r"(\$(?:\w+|\{[^}]*\}))", os.path.basename(script))
                name = re.compile("".join(".*" if p.startswith("$") else re.escape(p) for p in parts), re.I)
                hit = next((b for b in sorted(BLOCKED_SCRIPTS) if name.fullmatch(b)), None)
                if hit:
                    deny(f"`{script}` could name {hit}, which runs only inside the deploy pipeline (the deploy "
                         "wrapper). Write the script name literally.")

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
    check_secrets_dir(segment, base, args, prog=prog, cwd=cwd)
    if (any(p.fullmatch(segment.strip()) for p in SECRETS_STDIN_OK) or is_sign_in_invocation(prog, args)
            or is_refs_invocation(prog, args, cwd)):
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
    app_file = primary_approval_file()
    # A configured approval folder is the owner's as a whole: its secret and the file alike.
    app_dir = os.path.realpath(os.path.dirname(app_file)) if APPROVAL_NAMESPACE or APPROVAL_FILE_OVERRIDE else None
    if ((real == cfg_root or real.startswith(cfg_root + os.sep)) and os.path.basename(real) == "approval.json") \
            or (app_dir and (real == app_dir or real.startswith(app_dir + os.sep))):
        deny(f"{tool} on {path} is blocked: {app_file} is the owner's approval and only {APPROVE}, run by "
             f"the owner in his own terminal, writes it. Ask the owner to run `{APPROVE} <scope>`.")

    if is_protected_env_name(full) and (is_linked_worktree(full) or is_linked_worktree(GATE_CWD or os.getcwd())):
        deny_worktree_env()

    if not sync_enabled():
        rel, _ = relative_project_path(full, GATE_CWD)
        if is_template_managed_rel(rel):
            deny_template_managed(rel)

    check_builder_owner_path(tool, full)


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


# A quoted heredoc whose consumer is a text sink (`cat > f`, `cat <<'EOF' > f`, `git commit -F -`,
# `gh ... --body-file -`), after plain `&&` steps (those steps are still checked). Its body is data.
QUOTED_HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\2")
_WORD = r"[A-Za-z0-9_./=~-]+"
_PATH = r"(?:[A-Za-z0-9_./~-]|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\"(?:[^\"`$\\<>]|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)*\"|'[^'<>]*')+"
TEXT_SINK = re.compile(
    rf"(?:{_WORD}(?:[ \t]+{_WORD})*[ \t]*&&[ \t]*)*"
    rf"(?:cat[ \t]+>>?[ \t]*{_PATH}"
    r"|git[ \t]+commit(?:[ \t]+-[A-Za-z-]+)*[ \t]+(?:-F[ \t]*-|--file[ \t=]-)"
    rf"|gh(?:[ \t]+{_WORD})+[ \t]+(?:--body-file|-F)[ \t=]-)"
)


def text_sink_heredoc(line):
    """The heredoc operator match when `line` only feeds a quoted heredoc to a text sink, else None."""
    ops = list(QUOTED_HEREDOC.finditer(line))
    if len(ops) != 1:
        return None
    rest, tail = line[:ops[0].start()], line[ops[0].end():].strip()
    if tail:  # `cat <<'EOF' > f`: only one output redirect may follow the operator
        if not re.fullmatch(rf">>?[ \t]*{_PATH}", tail):
            return None
        rest += " " + tail
    if "<<" in rest or not TEXT_SINK.fullmatch(" ".join(rest.split())):
        return None
    return ops[0]


HEREDOC_OP = re.compile(r"<<(-?)[ \t]*")
SHELL_WORD = re.compile(r"[A-Za-z0-9_./-]+")


class ShellLines:
    """Shell syntax state across the shell lines of a command (never heredoc bodies): the open quote, the
    `$(` / `(` / backtick stack, `case` nesting, a `\\` continuation, pending heredocs, and `unsure`."""

    def __init__(self):
        self.quote, self.stack, self.case_stack, self.continued, self.pending, self.unsure = "", [], [], False, [], False

    def at_top_level(self):
        return not (self.unsure or self.quote or self.stack or self.case_stack or self.continued or self.pending)

    def _push(self, kind):
        self.stack.append((kind, self.quote, self.case_stack))
        self.quote, self.case_stack = "", []

    def _pop(self):
        _, self.quote, self.case_stack = self.stack.pop()

    def _delimiter(self, text, j):
        """(closing_delimiter_or_None, next_index) for a heredoc operator whose word starts at `text[j]`."""
        delim, q = "", ""
        while j < len(text):
            c = text[j]
            if q:
                if c == q:
                    q = ""
                else:
                    delim += c
            elif c in "'\"":
                q = c
            elif c == "\\" and j + 1 < len(text):
                j += 1
                delim += text[j]
            elif c in " \t;&|<>()":
                break
            else:
                delim += c
            j += 1
        return (delim if delim and not q else None), j

    def scan(self, line):
        text = line.rstrip("\r\n")
        self.continued = False
        i, n = 0, len(text)
        while i < n:
            c = text[i]
            if c == "\\" and self.quote != "'":
                if i + 1 >= n:
                    self.continued = True
                i += 2
                continue
            if self.quote == "'":
                if c == "'":
                    self.quote = ""
            elif self.quote == "`":
                if c == "`":
                    self._pop()
            elif c == "`":
                self._push("`")
                self.quote = "`"
            elif c == "$" and text[i + 1:i + 2] == "(":
                if text[i + 2:i + 3] == "(":
                    self.unsure = True
                    return
                self._push("(")
                i += 2
                continue
            elif c == "$" and text[i + 1:i + 2] in "{'\"":
                self.unsure = True
                return
            elif self.quote:
                if c == self.quote:
                    self.quote = ""
            elif c in "'\"":
                self.quote = c
            elif c == "#" and (i == 0 or text[i - 1] in " \t;&|()<>"):
                break
            elif c in "<>" and text[i + 1:i + 2] == "(":
                self.unsure = True
                return
            elif c == "(":
                if self.case_stack and len(self.stack) <= self.case_stack[-1]:
                    self.unsure = True
                    return
                self._push("(")
            elif c == ")":
                if self.case_stack and len(self.stack) <= self.case_stack[-1]:
                    pass
                elif self.stack:
                    self._pop()
                else:
                    self.unsure = True
                    return
            elif c == "<" and text.startswith("<<", i):
                op = HEREDOC_OP.match(text, i)
                if text.startswith("<<<", i) or text.startswith("<<=", i):
                    i += 3 if text.startswith("<<<", i) else 2
                    continue
                delim, end_j = self._delimiter(text, op.end())
                if delim is None:
                    self.unsure = True
                    return
                self.pending.append((bool(op[1]), delim))
                i = end_j
                continue
            elif c.isascii() and (c.isalnum() or c in "_./-"):
                word = SHELL_WORD.match(text, i)
                if word[0] == "case":
                    self.case_stack.append(len(self.stack))
                elif word[0] == "esac":
                    if not self.case_stack:
                        self.unsure = True
                        return
                    self.case_stack.pop()
                i = word.end()
                continue
            i += 1


def _strip_report_heredocs(command):
    lines = command.splitlines(keepends=True)
    shell, out, i = ShellLines(), [], 0
    while i < len(lines):
        line = lines[i]
        i += 1
        bare = line.rstrip("\r\n")
        match = text_sink_heredoc(bare) if shell.at_top_level() else None
        if match:
            end = i
            while end < len(lines):
                delimiter = lines[end].rstrip("\r\n")
                if match[1]:
                    delimiter = delimiter.lstrip("\t")
                if delimiter == match[3]:
                    break
                end += 1
            if end >= len(lines):
                return command
            out.append(bare[:match.start()].rstrip() + bare[match.end():] + "\n")
            i = end + 1
            continue
        shell.scan(line)
        if shell.unsure:
            return command
        out.append(line)
        if shell.pending and not shell.quote and not shell.continued:
            for dash, delim in shell.pending:
                while i < len(lines):
                    body = lines[i]
                    out.append(body)
                    i += 1
                    if (body.rstrip("\r\n").lstrip("\t") if dash else body.rstrip("\r\n")) == delim:
                        break
                else:
                    return command
            shell.pending = []
    return "".join(out)


def report_command_text(command):
    """Remove each closed quoted heredoc that feeds a text sink, at a top level line. Any exception or
    unsure parser state falls back to returning `command` unstripped (fail closed)."""
    try:
        return _strip_report_heredocs(command)
    except Exception:
        return command


# ---------------------------------------------------------------- Exact only scripts

EXACT_ONLY_UNSAFE = re.compile("[\n$`;|&<>(){}]")


def exact_only_program(token, rel, cwd):
    """True when token names the repo's script `rel`: relative to cwd, or by its absolute path."""
    root = CONFIG_LOADED_FROM
    if not root or os.path.isabs(rel):
        return False
    joined = token if os.path.isabs(token) else os.path.join(cwd or os.getcwd(), token)
    try:
        real_root = os.path.realpath(root)
        expected = os.path.realpath(os.path.join(root, rel))
        if os.path.islink(joined) or os.path.realpath(joined) != expected:
            return False
        return os.path.commonpath([expected, real_root]) == real_root and os.path.isfile(expected)
    except (OSError, ValueError):
        return False


def exact_only_targets():
    root = CONFIG_LOADED_FROM
    if not root:
        return set()
    return {os.path.realpath(os.path.join(root, rel)) for rel in EXACT_ONLY_SCRIPTS if not os.path.isabs(rel)}


# Programs that may name a listed script without running or moving it. Anything else mentioning the script is
# denied. Nothing with an exec or rename option belongs here (rg --pre runs a program, git mv and git rm move it).
EXACT_ONLY_READ_ONLY = {"ls", "cat", "head", "tail", "wc", "grep", "stat", "file", "diff", "shellcheck"}
EXACT_ONLY_GIT_READ_ONLY = {"add", "status", "diff", "log", "show", "ls-files", "blame"}


def exact_only_mentions(command, names, targets, cwd):
    """True when the text names a listed script anywhere: in the raw text, a dequoted word, or a symlink to it.

    Real paths and basenames compare case-insensitively, so a different case cannot hide the file.
    """
    folded_names = {name.lower() for name in names}
    folded_targets = {target.lower() for target in targets}

    def hit(token):
        if not token:
            return False
        if os.path.basename(token).lower() in folded_names:
            return True
        if token.startswith("-"):
            return False
        try:
            real = os.path.realpath(token if os.path.isabs(token) else os.path.join(cwd or os.getcwd(), token))
            return real.lower() in folded_targets
        except (OSError, ValueError):
            return False

    if any(re.search(rf"(?<![\w.-]){re.escape(name)}(?![\w.-])", command, re.IGNORECASE) for name in names):
        return True
    for text in [command, *substitutions(command)]:
        for seg in segments(text):
            if any(hit(t) for t in words(seg)):
                return True
    return False


def exact_only_allowed(tokens, rel_scripts, names, targets, cwd):
    """The whole command is the script then plain arguments, or a read-only program that only names it."""
    if exact_only_mentions(" ".join(tokens[1:]), names, targets, cwd):
        return False
    if any(exact_only_program(tokens[0], rel, cwd) for rel in rel_scripts):
        return True
    return False


def check_exact_only_scripts(command, cwd):
    """A listed script runs only as the whole command: its path, then plain arguments."""
    try:
        if not EXACT_ONLY_SCRIPTS:
            return
        names = {os.path.basename(rel) for rel in EXACT_ONLY_SCRIPTS}
        targets = exact_only_targets()
        if not exact_only_mentions(command, names, targets, cwd):
            return
        text = command.strip()
        if text and not EXACT_ONLY_UNSAFE.search(text):
            try:
                tokens = shlex.split(text)
            except ValueError:
                tokens = []
            if tokens:
                if exact_only_allowed(tokens, EXACT_ONLY_SCRIPTS, names, targets, cwd):
                    return
                if tokens[0] in EXACT_ONLY_READ_ONLY:
                    return
                if tokens[0] == "git" and len(tokens) > 1 and tokens[1] in EXACT_ONLY_GIT_READ_ONLY:
                    return
        listed = ", ".join(f"`{rel}`" for rel in EXACT_ONLY_SCRIPTS)
        deny(f"{listed} look in the secrets dir themselves, so each runs only as the whole command: the first word "
             "is its path (from the repo root, or absolute in this repo), then plain arguments. The script may not "
             "appear anywhere else, and no environment assignment, wrapper program, pipe, redirect (even glued to "
             "the path), `;`, `&&`, `||`, command substitution or other shell syntax is allowed.")
    except Exception:
        # main() allows the command when this rule raises, so the error has to deny on its own.
        deny("exact_only_scripts could not be checked, so the command is denied.")


# Active only outside single quotes. Double quotes still expand $ and backticks.
# A bare $HOME or $(...) has an empty prefix and stays allowed; a prefix under a
# protected directory does not, because the shell can turn it into that path.
_EXPANSION_META = set("*?[{$`")
_SHELL_OPERATORS = {";", "&&", "||", "|", "&"}
# $?, $#, $$, $!, and $- expand to a number or flag letters, never a path.
_NONPATH_SPECIALS = "?#$!-"


def _nonpath_special_len(command, index):
    """Length of $?, $#, $$, $!, or $-, or the ${?} form, starting at index. Otherwise 0."""
    if index >= len(command) or command[index] != "$":
        return 0
    nxt = index + 1
    if nxt >= len(command):
        return 0
    if command[nxt] in _NONPATH_SPECIALS:
        return 2
    if (nxt + 2 < len(command) and command[nxt] == "{"
            and command[nxt + 1] in _NONPATH_SPECIALS and command[nxt + 2] == "}"):
        return 4
    return 0


def hidden_script_dirs():
    """Absolute directories and repo-relative part tuples for exact_only scripts and credential dirs."""
    root = CONFIG_LOADED_FROM
    absolute = []
    relative = []
    if root:
        for rel in EXACT_ONLY_SCRIPTS:
            if not rel or os.path.isabs(rel):
                continue
            script = os.path.realpath(os.path.join(root, rel))
            absolute.append(os.path.dirname(script))
            parent = os.path.dirname(rel.replace("\\", "/"))
            parts = tuple(part.lower() for part in _path_parts(parent))
            if parts:
                relative.append(parts)
        for rel in SECRETS_DIR_RELPATHS:
            path = rel if os.path.isabs(rel) else os.path.join(root, rel)
            absolute.append(os.path.realpath(path))
            parts = tuple(part.lower() for part in _path_parts(rel))
            if parts:
                relative.append(parts)
    return absolute, relative


def _path_parts(path):
    path = os.path.expanduser(path).replace("\\", "/")
    out = []
    for piece in path.split("/"):
        if piece in ("", "."):
            continue
        if piece == "..":
            if out:
                out.pop()
            continue
        out.append(piece)
    return out


def _resolve_fold(path, cwd):
    path = os.path.expanduser(path or ".")
    if not os.path.isabs(path):
        path = os.path.join(cwd or os.getcwd(), path)
    try:
        return os.path.realpath(path).lower()
    except (OSError, ValueError):
        return os.path.normpath(path).lower()


def _expand_braces(text):
    match = re.search(r"\{([^{}]*)\}", text)
    if not match:
        return [text]
    pre, body, post = text[:match.start()], match.group(1), text[match.end():]
    choices = body.split(",") if body else [""]
    out = []
    for choice in choices:
        out.extend(_expand_braces(pre + choice + post))
    return out


def _at_or_inside(parts, pref):
    if not pref or len(parts) < len(pref):
        return False
    if tuple(parts[:len(pref)]) == pref:
        return True
    width = len(pref)
    return any(tuple(parts[i:i + width]) == pref for i in range(1, len(parts) - width + 1))


def _is_ancestor(parts, pref):
    return bool(parts) and len(parts) < len(pref) and tuple(pref[:len(parts)]) == tuple(parts)


def _directory_hit(path, cwd, absolute, relative, ancestor=False):
    """True when path is a protected directory, is inside one, or (find only) is an ancestor of one."""
    if path in ("", ".", "./"):
        folded = _resolve_fold(".", cwd)
        parts = ()
    else:
        folded = _resolve_fold(path, cwd)
        parts = tuple(part.lower() for part in _path_parts(path))
    for directory in absolute:
        other = directory.lower()
        if folded == other or folded.startswith(other + os.sep):
            return True
        if ancestor and other.startswith(folded + os.sep):
            return True
    if any(part == "secrets" for part in parts):
        return True
    for pref in relative:
        if _at_or_inside(parts, pref):
            return True
        if ancestor and _is_ancestor(parts, pref):
            return True
    return False


def _component_patterns(partial, suffix):
    head = suffix.split("/", 1)[0]
    if any(ch in head for ch in "$`"):
        # The characters before the variable still have to match a protected name.
        # A bare "*" matches every directory, so `exit=$?` and `state=$(...)` were denied.
        return [partial + "*"] if partial else ["*"]
    return _expand_braces(partial + head)


def _pattern_hits_name(patterns, name):
    folded = name.lower()
    return any(fnmatch.fnmatch(folded, pattern.lower()) for pattern in patterns)


def _generic_secrets(partial, suffix):
    """A component that can become a directory named secrets. Short globs such as s* stay allowed."""
    comp = partial + suffix.split("/", 1)[0]
    for alt in _expand_braces(comp):
        literal = []
        for ch in alt:
            if ch in _EXPANSION_META:
                break
            literal.append(ch)
        text = "".join(literal).lower()
        if text == "secrets" or text.startswith("secrets"):
            return True
        if len(text) >= 4 and "secrets".startswith(text) and "/" in suffix:
            return True
    return False


def _expansion_hits(literal, decoded, kinds, cwd, absolute, relative):
    if not kinds:
        return False
    if literal == "" and kinds <= {"$", "`"}:
        return False
    suffix = decoded[len(literal):]
    if literal == "":
        if "/" not in decoded and "**" not in decoded:
            return _directory_hit(".", cwd, absolute, relative)
        folded = decoded.lower()
        if any("/".join(pref) in folded for pref in relative if pref):
            return True
        # A slash after the meta can walk from the working directory into the protected one.
        return _directory_hit(".", cwd, absolute, relative, ancestor=True)
    anchor, partial = (literal[:-1], "") if literal.endswith("/") else literal.rpartition("/")[::2]
    if _directory_hit(anchor or ".", cwd, absolute, relative):
        return True
    anchor_parts = tuple(part.lower() for part in _path_parts(anchor)) if anchor else ()
    if any(part == "secrets" for part in anchor_parts):
        return True
    patterns = _component_patterns(partial, suffix)
    if _generic_secrets(partial, suffix):
        return True
    for pref in relative:
        if len(anchor_parts) >= len(pref) or tuple(pref[:len(anchor_parts)]) != anchor_parts:
            continue
        if _pattern_hits_name(patterns, pref[len(anchor_parts)]):
            return True
    return False


def _without_comments(command):
    """Drop unquoted comments through the end of the line. Quoted # stays data."""
    out = []
    quote = None
    i = 0
    while i < len(command):
        ch = command[i]
        if quote:
            out.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < len(command):
                out.append(command[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "\\" and i + 1 < len(command):
            out.append(ch)
            out.append(command[i + 1])
            i += 2
            continue
        elif ch == "#" and (not out or out[-1] in " \t\n;&|()<>"):
            while i < len(command) and command[i] != "\n":
                i += 1
            continue
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def _command_words(command):
    """Quote-aware words: decoded text, literal prefix, and active expansion characters."""
    command = _without_comments(command)
    words = []
    buf, literal, metas = [], [], set()
    seen = False
    quote = None
    i, n = 0, len(command)

    def finish():
        nonlocal buf, literal, metas, seen
        if buf or literal or metas:
            words.append(("".join(buf), "".join(literal), set(metas)))
        buf, literal, metas, seen = [], [], set(), False

    def take(ch, active=False):
        nonlocal seen
        buf.append(ch)
        if active:
            metas.add(ch)
            seen = True
        elif not seen:
            literal.append(ch)

    while i < n:
        ch = command[i]
        if quote == "'":
            if ch == "'":
                quote = None
            else:
                take(ch)
            i += 1
            continue
        if quote == '"':
            if ch == "\\" and i + 1 < n and command[i + 1] in "$`\"\\\n":
                nxt = command[i + 1]
                i += 2
                if nxt != "\n":
                    take(nxt)
                continue
            if ch == '"':
                quote = None
            else:
                span = _nonpath_special_len(command, i)
                if span:
                    for offset in range(span):
                        take(command[i + offset])
                    i += span
                    continue
                if ch in "$`":
                    take(ch, active=True)
                else:
                    take(ch)
            i += 1
            continue
        if quote == "`":
            if ch == "`":
                quote = None
            else:
                take(ch)
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            nxt = command[i + 1]
            i += 2
            if nxt != "\n":
                take(nxt)
            continue
        if ch == "'":
            quote = "'"
            i += 1
            continue
        if ch == '"':
            quote = '"'
            i += 1
            continue
        if ch == "`":
            take(ch, active=True)
            quote = "`"
            i += 1
            continue
        if ch in " \t\r\n":
            finish()
            i += 1
            continue
        if ch in ";|&":
            finish()
            op = ch
            if ch in "|&" and i + 1 < n and command[i + 1] == ch:
                op += ch
                i += 1
            words.append((op, op, set()))
            i += 1
            continue
        span = _nonpath_special_len(command, i)
        if span:
            for offset in range(span):
                take(command[i + offset])
            i += span
            continue
        take(ch, active=ch in _EXPANSION_META)
        i += 1
    finish()
    return words


def _annotate_cwd(words, cwd):
    cwd = cwd or os.getcwd()
    noted = []
    for i, word in enumerate(words):
        noted.append((*word, cwd))
        text, _literal, metas = word
        if text != "cd" or metas or not _at_command(words, i):
            continue
        j = i + 1
        while j < len(words) and words[j][0] not in _SHELL_OPERATORS and words[j][0].startswith("-"):
            j += 1
        if j < len(words) and words[j][0] not in _SHELL_OPERATORS and not words[j][2]:
            dest = words[j][0]
            if dest != "-":
                cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(dest)))
    return noted


def _at_command(words, index):
    j = index - 1
    while j >= 0 and words[j][0] not in _SHELL_OPERATORS and (
            ENV_ASSIGN.match(words[j][0]) or os.path.basename(words[j][0]) in WRAPPERS
            or os.path.basename(words[j][0]) == "env"):
        j -= 1
    return j < 0 or words[j][0] in _SHELL_OPERATORS


def _programs(words):
    indexes = []
    for i, word in enumerate(words):
        if word[0] in _SHELL_OPERATORS or word[0].startswith("-"):
            continue
        if _at_command(words, i):
            indexes.append(i)
    return indexes


def _find_reaches(words, start, absolute, relative):
    i = start + 1
    while i < len(words) and words[i][0] in ("-L", "-P", "-H"):
        i += 1
    paths = []
    while i < len(words) and words[i][0] not in _SHELL_OPERATORS | {"(", "!"} and not words[i][0].startswith("-"):
        paths.append(words[i])
        i += 1
    if not paths:
        paths = [("", "", set(), words[start][3])]
    for path in paths:
        text, _lit, _metas, path_cwd = path
        if _directory_hit(text or ".", path_cwd, absolute, relative, ancestor=True):
            return True
    return False


def _has_exec(words, start):
    for word in words[start + 1:]:
        if word[0] in _SHELL_OPERATORS:
            break
        if word[0] in ("-exec", "-execdir"):
            return True
    return False


def _path_like(text):
    return text in (".", "..") or text.startswith("~") or "/" in text or text.startswith(".")


def _xargs_reaches(words, absolute, relative):
    for word in words:
        text, _lit, metas, path_cwd = word
        if text in _SHELL_OPERATORS or text.startswith("-") or metas or not _path_like(text):
            continue
        if _directory_hit(text, path_cwd, absolute, relative):
            return True
    return False


def _hidden_script_paths(command, cwd, absolute, relative):
    words = _annotate_cwd(_command_words(command), cwd)
    for text, literal, metas, path_cwd in words:
        if _expansion_hits(literal, text, metas, path_cwd, absolute, relative):
            _deny_hidden()
    programs = _programs(words)
    find_hits = False
    xargs = False
    for index in programs:
        base = os.path.basename(words[index][0])
        if base == "find" and _has_exec(words, index) and _find_reaches(words, index, absolute, relative):
            _deny_hidden()
        if base == "find" and _find_reaches(words, index, absolute, relative):
            find_hits = True
        if base == "xargs":
            xargs = True
            if _directory_hit(".", words[index][3], absolute, relative):
                _deny_hidden()
    if xargs and (find_hits or _xargs_reaches(words, absolute, relative)):
        _deny_hidden()


def _deny_hidden():
    listed = [f"`{rel}`" for rel in EXACT_ONLY_SCRIPTS]
    listed.extend(f"`{rel}`" for rel in SECRETS_DIR_RELPATHS)
    if not listed:
        listed.append("the credential directory")
    deny("A glob, brace, variable, substitution, find -exec, find -execdir or xargs could build a path under "
         + ", ".join(listed)
         + " without that path appearing as text. The guard cannot see the path the shell would produce, "
         "so the command is denied.")


def check_hidden_script_paths(command, cwd):
    """Deny expansion and find/xargs that can name a restricted script or credential path."""
    try:
        absolute, relative = hidden_script_dirs()
        _hidden_script_paths(command, cwd, absolute, relative)
    except SystemExit:
        raise
    except Exception:
        deny("A path that could name a restricted script or the credential directory could not be checked, "
             "so the command is denied.")


# A blocked script name in a command the parsers above can misread (#1383): an allowlist, not a parser.
# Each shell line must be plain: quotes open and close on the line, no backslash, `$`, backtick or process
# substitution, and at most one closing `<<'TAG'` heredoc with a plain tag. Anything else denies.
PLAIN_HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\2[ \t]*")


def _plain_shell_line(line):
    """(text before any comment, heredoc match or None) for a plain shell line, else None."""
    quote, heredoc = "", None
    for i, c in enumerate(line):
        if c in "\\$`\r":
            return None
        if quote:
            quote = "" if c == quote else quote
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t;&|()<>"):
            line = line[:i]
            break
        elif c in "<>" and line[i + 1:i + 2] == "(":
            return None
        elif c == "<" and line[i + 1:i + 2] == "<" and heredoc is None:
            heredoc = i
        elif c == "<" and heredoc is not None and i > heredoc + 1:
            return None
    if quote:
        return None
    if heredoc is None:
        return line, None
    match = PLAIN_HEREDOC.fullmatch(line, heredoc)
    return (line, match) if match else None


def _blocked_mention(text):
    flat = re.sub(r"[\"'\\]", "", text).lower()
    return any(name.lower() in flat for name in BLOCKED_SCRIPTS)


def _deny_unplain_mention():
    deny("This command names a blocked script in a shape the guard cannot read with certainty (a quote across "
         "lines, a backslash, `$`, a backtick, a process substitution, or an unusual heredoc). Put each command on "
         "its own plain line, or write prose about the script into a file with `cat > file <<'EOF'`.")


def check_blocked_script_mentions(command):
    """Deny a blocked script name outside the plain line grammar; check each plain line on its own."""
    try:
        if not BLOCKED_SCRIPTS or not _blocked_mention(command):
            return
        lines, i, cur_cwd = command.split("\n"), 0, GATE_CWD
        while i < len(lines):
            # A text sink heredoc line has its own strict grammar; it may name `$VAR` as the file (#1435).
            sink = text_sink_heredoc(lines[i])
            plain = (lines[i], sink) if sink else _plain_shell_line(lines[i])
            if plain is None:
                _deny_unplain_mention()
            text, heredoc = plain
            i += 1
            for seg in segments(text[:heredoc.start()] if heredoc else text):
                check_segment(seg, cwd=cur_cwd)
                prog, args = program_and_args(words(seg))
                if prog in ("cd", "pushd") and args:
                    dest = next((a for a in args if not a.startswith("-")), None)
                    if dest:
                        cur_cwd = os.path.normpath(os.path.join(cur_cwd or os.getcwd(), os.path.expanduser(dest)))
            if heredoc:
                dash, tag = heredoc[1], heredoc[3]
                end = next((j for j in range(i, len(lines))
                            if (lines[j].lstrip("\t") if dash else lines[j]) == tag), None)
                if end is None or (_blocked_mention("\n".join(lines[i:end])) and not text_sink_heredoc(text.rstrip())):
                    _deny_unplain_mention()
                i = end + 1
    except SystemExit:
        raise
    except Exception:
        _deny_unplain_mention()


# ---------------------------------------------------------------- Literal host variables (#1795)
# A command that fits a closed shape (a prelude of NAME=literal statements, flat statements, at most one trailing
# `for NAME in WORD...; do ...; done`) has known variable values. Only the hidden host deny is lifted, and only
# for a word whose every value is a plain host. The raw command keeps every other check, and each copy with the
# values filled in is checked too, so a copy can add a deny but never remove one. Anything outside the shape
# returns no copies and is judged exactly as before.

LIFTED_HOST_WORDS: set[str] = set()
_LV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_LV_VAR = re.compile(r"\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})")
_LV_VAR_RE = r"\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})"
_LV_TOKEN = re.compile(r"(?P<sp>[ \t]+)|(?P<op>&&|\|\||[;\n|])"
                       r"|(?P<uword>(?:[A-Za-z0-9_./:@%+,=~*?\[\]-]|" + _LV_VAR_RE + r")+)"
                       r"|(?P<qword>\"(?:[A-Za-z0-9_./:@%+,=-]|[ ]|" + _LV_VAR_RE + r")*\")")
_LV_VALUE = re.compile(r"[A-Za-z0-9_./:@%+,-]+\Z")
_LV_HEADS = {"echo", "ls", "cat", "head", "tail", "stat", "file", "wc", "ssh", "scp", "bash", "sh"}
_LV_LOOP_MAX = 16
_LV_SPECIAL = {
    "IFS", "PATH", "HOME", "CDPATH", "REPLY", "ENV", "SHELLOPTS", "BASHOPTS", "PWD", "OLDPWD", "OPTIND",
    "OPTARG", "GLOBIGNORE", "HISTFILE", "ZDOTDIR", "TMPDIR", "SHELL", "FPATH", "MAILPATH", "MAIL", "TERM",
    "USER", "LOGNAME", "SECONDS", "RANDOM", "LINENO", "HOSTNAME", "PPID", "UID", "EUID", "TMOUT", "NULLCMD",
    "READNULLCMD", "WORDCHARS", "KEYTIMEOUT", "FIGNORE", "POSIXLY_CORRECT", "PROMPT_COMMAND", "MAILCHECK",
    "path", "cdpath", "fpath", "manpath", "module_path", "mailpath", "psvar", "status", "argv", "pipestatus",
    "prompt", "options", "commands", "functions", "aliases", "builtins", "parameters", "reply", "match",
    "mbegin", "mend", "signals", "history", "historywords", "jobstates", "jobtexts", "jobdirs", "dirstack",
    "funcstack", "widgets", "termcap", "terminfo", "modules", "nameddirs", "userdirs", "sysparams", "_",
    "COLUMNS", "LINES", "SHLVL", "ERRNO", "GID", "EGID", "SAVEHIST", "LISTMAX", "ARGC", "FUNCNEST", "GROUPS",
    "FUNCNAME", "DIRSTACK", "EPOCHSECONDS", "EPOCHREALTIME", "SRANDOM",
}
_LV_SPECIAL_PREFIX = ("LC_", "BASH", "LD_", "DYLD_", "ZSH", "GIT_", "PS", "PROMPT", "HIST", "SSH_", "SUDO")


class _LVMiss(Exception):
    """The command is outside the closed shape: judge it exactly as before."""


def _lv_tokens(command):
    out, pos, prev = [], 0, "op"
    while pos < len(command):
        m = _LV_TOKEN.match(command, pos)
        if not m:
            raise _LVMiss
        kind = m.lastgroup
        if kind in ("uword", "qword"):
            if prev in ("uword", "qword"):  # a quote in the middle of a word
                raise _LVMiss
            out.append((kind, m.group()))
        elif kind == "op":
            out.append(("op", m.group()))
        prev = kind
        pos = m.end()
    return out


def _lv_statements(tokens):
    """[(separator before, [(kind, text), ...])]. Blank lines drop out; any other empty statement is a miss."""
    out, cur, sep = [], [], "\n"
    for kind, text in tokens:
        if kind != "op":
            cur.append((kind, text))
        elif cur:
            out.append((sep, cur))
            cur, sep = [], text
        elif text != "\n":
            raise _LVMiss
    if cur:
        out.append((sep, cur))
    elif sep not in (";", "\n"):
        raise _LVMiss
    return out


def _lv_name(name, bound):
    if not _LV_NAME.match(name) or name in bound or name in _LV_SPECIAL or name.startswith(_LV_SPECIAL_PREFIX):
        raise _LVMiss
    return name


def _lv_vars(text):
    """The names in `text`; a variable followed by `:`, `[`, `$` or `{` (a zsh modifier or subscript) is a miss."""
    names = []
    for m in _LV_VAR.finditer(text):
        if text[m.end():m.end() + 1] in (":", "[", "$", "{"):
            raise _LVMiss
        names.append(m.group(1) or m.group(2))
    return names


def _lv_sub(text, values):
    return _LV_VAR.sub(lambda m: values[m.group(1) or m.group(2)], text)


def _lv_literal(word):
    """A plain word as the shell keeps it: `~` only alone or before `/`, no `..` component, a closed charset."""
    if word == "~" or word.startswith("~/"):
        word = os.path.expanduser("~") + word[1:]
    if "/../" in f"/{word}/" or "++" in word or "--" in word or not _LV_VALUE.match(word):
        raise _LVMiss
    return word


def literal_variable_copies(command):
    """Set LIFTED_HOST_WORDS and return the copies of `command` with the values filled in, or [] outside the shape."""
    LIFTED_HOST_WORDS.clear()
    stmts = _lv_statements(_lv_tokens(command))
    prelude, i = {}, 0
    while i < len(stmts) and len(stmts[i][1]) == 1 and stmts[i][0] in (";", "\n"):
        kind, text = stmts[i][1][0]
        name, eq, value = text.partition("=")
        if kind != "uword" or not eq or not _LV_NAME.match(name):
            break
        if "$" in value or "=" in value or any(c in value for c in "*?[]"):
            raise _LVMiss
        if i + 1 < len(stmts) and stmts[i + 1][0] not in (";", "\n"):
            raise _LVMiss
        prelude[_lv_name(name, prelude)] = _lv_literal(value)
        i += 1
    if not prelude and not any(s[1][0][1] == "for" for s in stmts):
        return []
    flat, loop = stmts[i:], None
    k = next((j for j, s in enumerate(flat) if s[1][0] == ("uword", "for")), None)
    if k is not None:
        flat, rest = flat[:k], flat[k:]
        sep, header = rest[0]
        if sep not in (";", "\n") or len(header) < 4 or header[2] != ("uword", "in"):
            raise _LVMiss
        if any(kind != "uword" for kind, _ in header):
            raise _LVMiss
        var = _lv_name(header[1][1], prelude)
        words = [t for _, t in header[3:]]
        if any(w in ("for", "do", "done") for w in words):
            raise _LVMiss
        body = rest[1:]
        if len(body) < 2 or body[-1][1] != [("uword", "done")] or body[-1][0] not in (";", "\n"):
            raise _LVMiss
        body = body[:-1]
        first_sep, first = body[0]
        if first_sep not in (";", "\n") or first[0] != ("uword", "do"):
            raise _LVMiss
        body = ([(first_sep, first[1:])] if len(first) > 1 else []) + body[1:]
        if not body or any(t[1] in ("for", "do", "done") for _, s in body for t in s):
            raise _LVMiss
        values = []
        for w in words:
            if any(n not in prelude for n in _lv_vars(w)) or "=" in w or "[" in w or "]" in w:
                raise _LVMiss
            w = _lv_sub(w, prelude)
            if "*" in w or "?" in w:
                _lv_literal(w.replace("*", "x").replace("?", "x"))
                values = None
            elif values is not None:
                values.append(_lv_literal(w))
        loop = (var, values, [(sep, [("uword", _lv_sub(t, prelude)) for _, t in header])], body)
    bound = set(prelude) | ({loop[0]} if loop else set())
    for part, names in ((flat, set(prelude)), (loop[3] if loop else [], bound)):
        for _, stmt in part:
            _lv_check_statement(stmt, names, bound)
    if loop and len(loop[2][0][1]) - 3 > _LV_LOOP_MAX:
        deny(f"A loop over {len(loop[2][0][1]) - 3} words is more than the guard follows ({_LV_LOOP_MAX}), so it "
             "is refused: split the loop into smaller loops.")

    def choices(text):
        names = _lv_vars(text)
        if loop and loop[0] in names:
            return [_lv_sub(text, {**prelude, loop[0]: v}) for v in loop[1]]
        return [_lv_sub(text, prelude)]

    def values_of(name):
        return loop[1] if loop and name == loop[0] else [prelude[name]]

    for _, stmt in flat + (loop[3] if loop else []):
        if stmt[0][1] not in ("ssh", "scp"):
            continue
        if any(values_of(n) is None for _, t in stmt for n in _lv_vars(t)):
            continue  # a glob loop word could be an option: lift nothing in this statement
        for kind, text in stmt[1:]:
            names = _lv_vars(text)
            if not names or any(values_of(n) is None for n in names):
                continue
            if kind == "qword" and any(":" in v for n in names for v in values_of(n)):
                continue  # a quoted remote path: the value must not add a host
            vals = [v[1:-1] if kind == "qword" else v for v in choices(text)]
            if not any(hidden_host(v) for v in vals):
                LIFTED_HOST_WORDS.add(text)

    def render(stmts_, values):
        out = []
        for sep, stmt in stmts_:
            text = " ".join(_lv_sub(t, values) for _, t in stmt)
            out.append(text if not out else f"{sep} {text}")
        return " ".join(out)

    if not loop:
        return [render(flat, prelude)] if flat else []
    var, vals, head, body = loop
    if vals is None:
        return [render(flat + head + body, {**prelude, var: "$" + var})]
    return [render(flat + head + body, {**prelude, var: v}) for v in vals]


def _lv_check_statement(stmt, names, bound):
    texts = [t for _, t in stmt]
    for t in texts:
        if any(n not in names for n in _lv_vars(t)):
            raise _LVMiss
        if t in bound:
            raise _LVMiss
    if texts[0] == "[":
        if (len(stmt) != 4 or texts[1] not in ("-d", "-f", "-e") or texts[3] != "]" or stmt[2][0] != "uword"
                or any(c in texts[2] for c in "=[]")):
            raise _LVMiss
        return
    if stmt[0][0] != "uword" or texts[0] not in _LV_HEADS:
        raise _LVMiss
    for kind, t in stmt:
        if kind == "qword" and texts[0] == "echo":
            continue
        if any(c in t for c in "=[]") or "++" in t or "--" in t:
            raise _LVMiss


def check_command(command):
    command = report_command_text(command)
    global CODE_COMMAND
    CODE_COMMAND = command
    check_exact_only_scripts(command, GATE_CWD)
    texts = [command, *substitutions(command)]
    for text in texts:
        cur_cwd = GATE_CWD
        for seg in segments(text):
            check_segment(seg, cwd=cur_cwd)
            prog, args = program_and_args(words(seg))
            if prog in ("cd", "pushd") and args:
                dest = next((a for a in args if not a.startswith("-")), None)
                if dest:
                    cur_cwd = os.path.normpath(os.path.join(cur_cwd or os.getcwd(), os.path.expanduser(dest)))
    # After the rules above, so an existing deny keeps its reason. This only closes paths they cannot see.
    for text in texts:
        check_hidden_script_paths(text, GATE_CWD)
    check_blocked_script_mentions(RAW_COMMAND)
    if INDIRECT:
        deny(INDIRECT[0])


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
    global GATE_CWD, RAW_COMMAND, HOOK_INPUT
    HOOK_INPUT = data
    session_role.cached = None
    raw_cwd = data.get("cwd")
    GATE_CWD = raw_cwd if isinstance(raw_cwd, str) and raw_cwd else os.getcwd()
    load_guard_config(GATE_CWD)
    if tool in EDIT_TOOLS:
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        check_edit(tool, path if isinstance(path, str) else "")
        return
    if tool == "Read":
        path = tool_input.get("file_path") or ""
        check_approval_secret_read(path if isinstance(path, str) else "")
        return
    if tool != "Bash":
        return
    raw_cmd = tool_input.get("command")
    command = raw_cmd if isinstance(raw_cmd, str) else ""
    RAW_COMMAND = command
    check_background_wait(command)
    try:
        copies = literal_variable_copies(command)
    except SystemExit:
        raise
    except Exception:  # _LVMiss, or a shape the resolver cannot read: judge the command exactly as before
        LIFTED_HOST_WORDS.clear()
        copies = []
    try:
        check_command(command)
        for copy in copies:
            check_command(copy)
    except SystemExit:
        raise
    except Exception:
        if not LIFTED_HOST_WORDS:
            return
        LIFTED_HOST_WORDS.clear()  # a copy failed to check: judge the raw command as before, with no lift
        try:
            check_command(command)
        except SystemExit:
            raise
        except Exception:
            return


if __name__ == "__main__":
    main()
