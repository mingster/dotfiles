#!/usr/bin/env bash
# Route a builder worker_done to the lead that owns the dispatch, and release the committer once.
#   worker-done-relay.sh relay --dispatch ID --branch B --sha S --payload PATH --coordinator HANDLE
#   worker-done-relay.sh release --dispatch ID
#   worker-done-relay.sh sweep --coordinator HANDLE [--run RUN]   once per fleet-watch pass
# Owner record: $WORKER_DONE_OWNER_DIR/<dispatch id> (default ~/.claude/state/dispatch-owners) holds the
# owning lead's terminal handle on one line. No record, or an empty one, sends to the coordinator as a message only.
# The lead's terminal gets a "check your inbox" nudge after the message; a failed nudge does not fail the relay
# (the message was delivered), and the coordinator's terminal is never typed into.
# A successful release writes <dispatch id>.released, so a second release does nothing.
# More record lines, written when the worker starts: kind=builder|reviewer, repo=owner/name, branch=B (builder),
# pr=N (reviewer, one line per PR). worker_done reaches <dispatch id>.done.json from two places: coordinator-drain.sh
# (the waiter reads first and marks it read) and sweep (check --peek, for any still unread). Sweep relays it once and
# releases the seat only on proof. <dispatch id>.relayed holds the relay state: "sending" is written before the send,
# "sent" after it. A pass that died in between leaves "sending": the next pass repeats once ("resending", then "sent"),
# so a crash gives at most one repeat. A failed send removes the marker and is retried; a failed nudge still counts as sent.
# The outcome is worker-show's state (the worker_done payload carries only taskId and dispatchId); the payload's
# outcome is used only when worker-show is unreadable. Only succeeded can release a seat.
#   builder:  git ls-remote shows repo's branch at `git rev-parse HEAD` of the dispatch worktree. worker-show gives
#             result.workspace as "<id>::<path>"; the path must be on the record's branch and have a remote of the record's repo,
#   reviewer: each PR has a Verdict first line with head=<PR head now> and verifier=<this dispatch> (gh, skipped below 500 requests left).
# No owner record: nothing happens. No proof: the seat stays and one digest line per dispatch is printed on stdout.
# Env: GH_COMMAND, WORKER_DONE_REMOTE_PREFIX (default https://github.com/).
set -euo pipefail
orca=${ORCA_CLI_COMMAND:-orca}
dir=${WORKER_DONE_OWNER_DIR:-$HOME/.claude/state/dispatch-owners}
die() { echo "worker-done-relay: $*" >&2; exit 2; }

[ $# -ge 1 ] || die "usage: relay|release --dispatch ID ..."
mode=$1; shift
dispatch="" branch="" sha="" payload="" coordinator="" run=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "$1 needs a value"
  case "$1" in
    --dispatch) dispatch=$2 ;; --branch) branch=$2 ;; --sha) sha=$2 ;;
    --payload) payload=$2 ;; --coordinator) coordinator=$2 ;; --run) run=$2 ;;
    *) die "unknown argument $1" ;;
  esac
  shift 2
done
[ "$mode" = sweep ] || [[ "$dispatch" =~ ^[A-Za-z0-9_-]+$ ]] || die "--dispatch must be a plain id"

case "$mode" in
  relay)
    [ -n "$branch" ] && [ -n "$sha" ] && [ -n "$payload" ] && [ -n "$coordinator" ] \
      || die "relay needs --branch, --sha, --payload and --coordinator"
    to=""
    [ ! -f "$dir/$dispatch" ] || to=$(head -n 1 "$dir/$dispatch" | tr -d '[:space:]')
    subject="worker_done $dispatch"
    if [ -z "$to" ]; then
      to=$coordinator
      subject="worker_done $dispatch (no recorded owning lead)"
    fi
    bound=${ORCA_REPLY_BOUND_SECONDS:-30}
    bounded() { perl -e 'alarm shift; exec @ARGV or exit 127' "$bound" "$@"; }
    bounded "$orca" orchestration send --to "$to" --subject "$subject" \
      --body "dispatch=$dispatch branch=$branch sha=$sha payload=$payload" --json || exit $?
    if [ "$to" != "$coordinator" ]; then
      bounded "$orca" terminal send --terminal "$to" --text "check your inbox" --enter --json > /dev/null \
        || echo "worker-done-relay: message sent but the nudge to $to failed" >&2
    fi
    ;;
  release)
    [ ! -f "$dir/$dispatch.released" ] || exit 0
    "$orca" orchestration worker-release --dispatch "$dispatch" --json
    mkdir -p "$dir" && : > "$dir/$dispatch.released"
    ;;
  sweep)
    [ -n "$coordinator" ] || die "sweep needs --coordinator"
    exec python3 - "$0" "$dir" "$coordinator" "$run" <<'PY'
import glob, json, os, re, shlex, subprocess, sys

script, owners, coordinator, run = sys.argv[1:]
orca = shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca'))
gh = shlex.split(os.environ.get('GH_COMMAND', 'gh'))
prefix = os.environ.get('WORKER_DONE_REMOTE_PREFIX', 'https://github.com/')
VERDICT = re.compile(r'^Verdict: (?:PASS|PASS\+NOTES|FAIL) head=(\S+) verifier=(\S+)(?: |$)')


def call(command, timeout=30):
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (subprocess.SubprocessError, OSError):
        return None
    return done.stdout if done.returncode == 0 else None


def read_record(dispatch):
    try:
        lines = open(os.path.join(owners, dispatch)).read().splitlines()
    except OSError:
        return None
    if not lines or not lines[0].strip():
        return None
    record = {'owner': lines[0].strip(), 'pr': []}
    for line in lines[1:]:
        key, _, value = line.partition('=')
        if key == 'pr':
            record['pr'].append(value.strip())
        elif key in ('kind', 'repo', 'branch'):
            record[key] = value.strip()
    return record


def find(node, keys):
    if isinstance(node, dict):
        for key in keys:
            if isinstance(node.get(key), str):
                return node[key]
        for value in node.values():
            found = find(value, keys)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find(value, keys)
            if found:
                return found
    return None


def show(dispatch):
    """The result of worker-show: dispatchId, state (succeeded when settled), workspace as "<id>::<path>"."""
    try:
        node = json.loads(call(orca + ['orchestration', 'worker-show', '--dispatch', dispatch, '--json']))
        return node['result'] if isinstance(node.get('result'), dict) else node
    except (TypeError, ValueError, KeyError, AttributeError):
        return {}


def head_of(shown, record):
    """HEAD of the dispatch worktree, only when that path is on the record's branch and has a remote of the record's repo."""
    try:
        workspace = shown['workspace']
        path = workspace.split('::', 1)[1] if '::' in workspace else workspace
    except (KeyError, AttributeError, IndexError):
        return None
    if not os.path.isdir(path):
        return None
    branch = call(['git', '-C', path, 'symbolic-ref', '--short', 'HEAD'], 15)
    if branch is None or branch.strip() != record.get('branch'):
        return None
    urls = call(['git', '-C', path, 'config', '--get-regexp', r'^remote\..*\.url$'], 15) or ''
    repo = record.get('repo') or ''
    if not any(re.sub(r'(\.git)?/*$', '', line.split(None, 1)[-1]).endswith(('/' + repo, ':' + repo)) for line in urls.splitlines()):
        return None
    head = call(['git', '-C', path, 'rev-parse', 'HEAD'], 15)
    return head.strip() if head and re.fullmatch(r'[0-9a-f]{40}', head.strip()) else None


def mark(name, text=''):
    open(os.path.join(owners, name), 'w').write(text)


def payload_of(message):
    value = message.get('payload')
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return {}
    return value if isinstance(value, dict) else {}


def store(dispatch, message):
    path = os.path.join(owners, dispatch + '.done.json')
    if not os.path.exists(path):
        temporary = '%s.%d.tmp' % (path, os.getpid())
        json.dump(message, open(temporary, 'w'))
        os.replace(temporary, path)


def proof(dispatch, record, sha):
    """None when proven, 'skip' to try again quietly, else the reason the seat stays."""
    kind = record.get('kind')
    if kind == 'builder':
        if not record.get('repo') or not record.get('branch'):
            return 'owner record lacks repo or branch'
        if not sha:
            return 'cannot read the worktree head'
        listed = call(['git', 'ls-remote', prefix + record['repo'], 'refs/heads/' + record['branch']], 60)
        if listed is None:
            return 'cannot read the remote branch'
        return None if listed.split()[:1] == [sha] else 'remote branch is not at the worktree head'
    if kind == 'reviewer':
        if not record.get('repo') or not record['pr']:
            return 'owner record lacks repo or pr'
        remaining = call(gh + ['api', 'rate_limit', '--jq', '.resources.core.remaining'])
        try:
            if int(remaining) < 500:
                return 'skip'
        except (TypeError, ValueError):
            return 'skip'
        for number in record['pr']:
            shown = call(gh + ['pr', 'view', number, '--repo', record['repo'], '--json', 'headRefOid,comments'])
            try:
                pr = json.loads(shown)
                bodies = [c['body'].split('\n')[0] for c in pr['comments']]
                head = pr['headRefOid']
            except (TypeError, ValueError, KeyError):
                return 'skip'
            if not any((m := VERDICT.match(b)) and m.group(1) == head and m.group(2) == dispatch for b in bodies):
                return 'no Verdict for PR %s at its head by this dispatch' % number
        return None
    return 'owner record has no kind, so nothing is released automatically'


def process(dispatch):
    record = read_record(dispatch)
    if not record:
        return
    done = os.path.join(owners, dispatch + '.done.json')
    try:
        payload = payload_of(json.load(open(done)))
    except (OSError, ValueError, AttributeError):
        payload = {}
    shown = show(dispatch)
    sha = head_of(shown, record) if record.get('kind') == 'builder' else None
    marker = dispatch + '.relayed'
    try:
        state = open(os.path.join(owners, marker)).read().strip()
    except OSError:
        state = None
    if state == 'resending':
        mark(marker, 'sent')
    elif state in (None, 'sending'):
        mark(marker, 'resending' if state else 'sending')
        relayed = subprocess.run(['bash', script, 'relay', '--dispatch', dispatch, '--branch', record.get('branch') or '-',
                                  '--sha', sha or '-', '--payload', done, '--coordinator', coordinator],
                                 capture_output=True, text=True).returncode
        if relayed == 0:
            mark(marker, 'sent')
        else:
            os.unlink(os.path.join(owners, marker))
    if os.path.exists(os.path.join(owners, dispatch + '.released')):
        os.path.exists(done) and os.unlink(done)
        return
    outcome = shown.get('state') or payload.get('outcome')
    reason = None if outcome == 'succeeded' else 'outcome is %s' % outcome
    reason = reason or proof(dispatch, record, sha)
    if reason == 'skip':
        return
    if reason is None:
        if subprocess.run(['bash', script, 'release', '--dispatch', dispatch], capture_output=True).returncode == 0:
            os.unlink(done)
        return
    if not os.path.exists(os.path.join(owners, dispatch + '.noted')):
        mark(dispatch + '.noted')
        print('worker-done sweep: %s seat kept, %s' % (dispatch, reason))


inbox = call(orca + ['orchestration', 'check'] + (['--run', run] if run else ['--terminal', coordinator]) + ['--peek', '--types', 'worker_done', '--json'], 60)
try:
    box = json.loads(inbox)
    messages = (box['result'] if isinstance(box.get('result'), dict) else box)['messages']
except (TypeError, ValueError, KeyError, AttributeError):
    messages = []
os.makedirs(owners, exist_ok=True)
for message in messages:
    if message.get('type') != 'worker_done':
        continue
    dispatch = payload_of(message).get('dispatchId')
    if re.fullmatch(r'[A-Za-z0-9_-]+', str(dispatch)) and read_record(dispatch) and not os.path.exists(os.path.join(owners, dispatch + '.released')):
        store(dispatch, message)
for path in sorted(glob.glob(os.path.join(owners, '*.done.json'))):
    process(os.path.basename(path)[:-len('.done.json')])
PY
    ;;
  *) die "mode must be relay, release or sweep" ;;
esac
