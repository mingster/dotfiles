#!/usr/bin/env bash
# Start an Orca worker on Codex without the agent_readiness failure (codex 0.160.1):
# Orca only sees a Codex terminal as ready after Codex has finished one turn, so open the
# Codex terminal first, give it a one line warm-up turn, then hand it the task.
# Usage: start-codex-worker.sh --run <run_id> --spec <file> --title <text>
# Briefs must list Allowed files and say: Read only these; Grep before Read; Read with offset/limit.
# Reviewer slices may inspect at most 40 files.
#          (--worktree-path <path> | --name <new worktree> --repo <path> [--base-branch <ref>])
#          [--host <this machine only>] [--model gpt-6.1-sol] [--effort medium] [--from <coordinator handle>]
# --from defaults to $ORCA_TERMINAL_HANDLE; a coordinator without one (Elon in Claude Code) passes its
# orca_session_id, or worker-start fails consumer_fenced after the worktree and terminal exist.
# A "hooks are new or changed" prompt is trusted only when the hooks and what they run match origin/main; else exit 4.
# Prints the dispatch id and terminal handle; exits 1 if the dispatch is not running, 3 if --model gpt-6-astra lacks OWNER_ASTRA_YES.
set -u
poll="${START_CODEX_POLL:-1}"; orca="${ORCA_CLI_COMMAND:-orca}"; model=gpt-6.1-sol; effort=medium; base=
# Plugins a coding or review worker does not need; each one slows Codex startup.
off=; for p in codex-app-tools@openai-bundled unified-computer-use@openai-bundled visualize@openai-bundled \
  documents@openai-primary-runtime pdf@openai-primary-runtime spreadsheets@openai-primary-runtime \
  presentations@openai-primary-runtime template-creator@openai-primary-runtime; do
  off="$off -c plugins.\"$p\".enabled=false"; done
run= spec= title= wt= name= repo= host= from="${ORCA_TERMINAL_HANDLE:-}"
while [ $# -gt 0 ]; do case "$1" in
  --run) run=$2;; --spec) spec=$2;; --title) title=$2;; --worktree-path) wt=$2;;
  --name) name=$2;; --repo) repo=$2;; --base-branch) base=$2;; --host) host=$2;; --model) model=$2;; --effort) effort=$2;; --from) from=$2;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; shift 2; done
[ -n "$run" ] && [ -n "$spec" ] && [ -n "$title" ] || { echo "need --run --spec --title" >&2; exit 2; }
[ -n "$from" ] || { echo "need --from <coordinator handle> (no ORCA_TERMINAL_HANDLE)" >&2; exit 2; }
# The worktree and terminal are created on this machine, so a remote --host would be ignored silently.
case "$host" in ""|"$(hostname -s)"|localhost) ;; *)
  echo "start-codex-worker: refused: --host $host; this script starts only on $(hostname -s). Use orca orchestration worker-start --on $host" >&2; exit 2 ;; esac
# gpt-6-astra costs about 4 times gpt-6.1-sol per token (2026-10-22: one astra worker moved the weekly reading 65% to 95%).
# Owner rule 2026-10-22: only with the owner'"'"'s yes for that specific use; OWNER_ASTRA_YES names the issue or message of that yes.
case "$model" in gpt-6-astra*) [ -n "${OWNER_ASTRA_YES:-}" ] || {
  echo "start-codex-worker: refused: $model needs the owner's yes for this use; set OWNER_ASTRA_YES=<issue or message ref>, or use gpt-6.1-sol" >&2; exit 3; } ;; esac
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
if [ -z "$wt" ]; then
  [ -n "$name" ] && [ -n "$repo" ] || { echo "need --worktree-path or --name and --repo" >&2; exit 2; }
  if [ -z "$base" ]; then
    base=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD) || {
      echo "cannot resolve origin/HEAD for $repo; pass --base-branch explicitly" >&2; exit 1;
    }
  fi
  wt=$("$orca" worktree create --name "$name" --repo "path:$repo" --base-branch "$base" --setup run --json | j 'd["result"]["worktree"]["path"]') || exit 1
fi
# Warn (never block) when the host's bun is older than the repo's pin; --host can only be this machine.
"$(dirname "$0")/bun-pin-check.sh" "${host:-$(hostname -s)}" "${repo:-$wt}" || true
# Codex keys hook trust by path, so every new worktree stops at "hooks are new or changed".
# Trust all only when every listed hooks file, and every file its commands reference, is byte
# identical to origin/main of the same repo. Anything else: select nothing, print the diff, exit 4.
read -r -d '' hooks_check <<'PY'
import sys, os, re, json, subprocess, hashlib, difflib
wt = os.path.realpath(sys.argv[1]); raw = sys.stdin.read()
def strs(d):
    if isinstance(d, str): yield d
    elif isinstance(d, (dict, list)):
        for v in (d.values() if isinstance(d, dict) else d): yield from strs(v)
try: text = "\n".join(strs(json.loads(raw)))
except ValueError: text = raw
def git(*a): return subprocess.run(["git", "-C", wt] + list(a), capture_output=True)
def refuse(msg, diff=""):
    sys.stderr.write("start-codex-worker: " + msg + "\n" + diff); sys.exit(1)
top = git("rev-parse", "--show-toplevel")
if top.returncode: refuse("not a git worktree: " + wt)
top = os.path.realpath(top.stdout.decode().strip())
choice = re.search(r"(\d+)[.)]\s*Trust all and continue", text)
listed = {os.path.realpath(os.path.join(wt, os.path.expanduser(p))) for p in re.findall(r"[\w@%+./~-]*hooks\.json", text)}
mine = wt + "/.codex/hooks.json"
if not choice: refuse("cannot parse the hooks prompt (no Trust all option)")
if listed:
    if mine not in listed: refuse("cannot parse the hooks prompt (no <worktree>/.codex/hooks.json)")
else:   # the real prompt lists no paths, only a count: it must equal the commands in <worktree>/.codex/hooks.json
    m = re.search(r"(\S+)\s+hooks?\s+(?:are|is)\s+new or changed", text)
    if not m or not m.group(1).isdigit() or int(m.group(1)) == 0: refuse("cannot parse the hooks prompt (no usable hook count)")
    try: d = json.load(open(mine))
    except (OSError, ValueError): refuse("cannot read hooks file: " + mine)
    n = 0
    for groups in (d.get("hooks") or {}).values() if isinstance(d, dict) and isinstance(d.get("hooks"), dict) else []:
        for g in groups if isinstance(groups, list) else []:
            for h in (g.get("hooks") or []) if isinstance(g, dict) and isinstance(g.get("hooks"), list) else []:
                if isinstance(h, dict) and isinstance(h.get("command"), str): n += 1
    if int(m.group(1)) != n: refuse("prompt says %s hooks are new or changed but .codex/hooks.json has %d commands (other hooks changed too)" % (m.group(1), n))
    listed = {mine}
checked = {}
def same(path):
    if path in checked: return
    rel = os.path.relpath(path, top)
    if rel.startswith("..") or not os.path.isfile(path): refuse("not a file inside the repo: " + path)
    main = git("show", "origin/main:" + rel)
    if main.returncode: refuse("not on origin/main (untracked or new): " + rel)
    cur = open(path, "rb").read()
    if cur != main.stdout:
        refuse("differs from origin/main: " + rel, "".join(difflib.unified_diff(
            main.stdout.decode(errors="replace").splitlines(True), cur.decode(errors="replace").splitlines(True),
            "origin/main:" + rel, rel)))
    checked[path] = hashlib.sha256(cur).hexdigest()
for path in sorted(listed):
    same(path)
    cmds = []
    def walk(d):
        if isinstance(d, dict): [cmds.append(v) if k == "command" and isinstance(v, str) else walk(v) for k, v in d.items()]
        elif isinstance(d, list): [walk(v) for v in d]
    try: walk(json.load(open(path)))
    except ValueError: refuse("hooks file is not valid JSON: " + path)
    for cmd in cmds:
        for tok in re.findall(r"[^\s\"'`;|&<>()=,{}\[\]]+", cmd):
            tok = re.sub(r"^\$\{?\w+\}?(?=/)", "", tok)
            if tok == "/dev/null" or not ("/" in tok or re.search(r"\.(sh|bash|py|js|mjs|cjs|ts|rb|pl|php)$", tok)): continue
            found = [c for c in (os.path.join(top, tok), top + tok) if os.path.exists(c)] if tok.startswith("/") else [os.path.join(top, tok)]
            if tok.startswith("/") and os.path.exists(tok) and not found: refuse("hook command references a file outside the repo: " + tok)
            if not found or not os.path.exists(found[0]): refuse("hook command references a path I cannot resolve: " + tok)
            same(os.path.realpath(found[0]))
print(choice.group(1))
for path, sha in sorted(checked.items()): print("sha256 " + sha + " " + path)
PY
trusted=
trust_gate() {   # $1 = raw terminal screen
  echo "$1" | grep -qiE 'hooks? (are|is) new or changed' || return 0
  [ -z "$trusted" ] || return 0
  verdict=$(echo "$1" | python3 -c "$hooks_check" "$wt") || { echo "start-codex-worker: hooks prompt left untouched; escalate to the owner" >&2; exit 4; }
  "$orca" terminal send --terminal "$term" --text "$(echo "$verdict" | head -1)" --enter --json >/dev/null
  echo "$verdict" | tail -n +2 | sed 's/^/start-codex-worker: trusted /' >&2; trusted=1
}
term=$("$orca" terminal create --worktree "path:$wt" --title "$title" \
  --command "codex -m $model -c model_reasoning_effort=$effort$off" --json | j 'd["result"]["terminal"]["handle"]') || exit 1
for i in $(seq 1 180); do   # up to 180 s for the Codex prompt
  scr=$("$orca" terminal read --terminal "$term" --screen --json 2>/dev/null); trust_gate "$scr"
  echo "$scr" | grep -q 'Ask Codex\|? for shortcuts\|GPT-[0-9]' && break; sleep "$poll"; done
"$orca" terminal send --terminal "$term" --text "Say ready and wait for your task." --enter --json >/dev/null
for i in $(seq 1 90); do   # up to 90 s for the warm-up turn to finish
  sleep "$poll"; scr=$("$orca" terminal read --terminal "$term" --screen --json 2>/dev/null); trust_gate "$scr"
  echo "$scr" | grep -q 'Working' || { echo "$scr" | grep -qi 'ready' && break; }; done
out=$("$orca" orchestration worker-start --run "$run" --spec "$(cat "$spec")" --terminal "$term" \
  --worktree "path:$wt" --task-title "$title" --from "$from" --json) || { echo "$out" >&2; exit 1; }
disp=$(echo "$out" | j 'd["result"]["dispatchId"]'); st=$(echo "$out" | j 'd["result"]["state"]')
"$orca" terminal rename --terminal "$term" --title "$title" --json >/dev/null   # Codex overwrites the title
echo "$disp $term $st"; [ "$st" = ready ] || [ "$st" = dispatched ]
