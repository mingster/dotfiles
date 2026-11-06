#!/usr/bin/env bash
# Route a worker_done to the lead that owns the dispatch, and release the committer once.
#   worker-done-relay.sh relay --dispatch ID --branch B --sha S --payload PATH --coordinator HANDLE
#   worker-done-relay.sh release --dispatch ID
#   worker-done-relay.sh record --dispatch ID --lead HANDLE [--kind builder|reviewer --repo R --branch B --pr N ...]
#   worker-done-relay.sh sweep --coordinator HANDLE [--run RUN]   once per fleet-watch pass
# Owner record: $WORKER_DONE_OWNER_DIR/<dispatch id> (default ~/.claude/state/dispatch-owners). Line 1 is the owning
# lead's terminal handle. `record` writes it atomically; with --lead alone on an existing record it changes only line 1
# (a lead handoff), so the kind, repo, branch and pr lines survive. More lines, written when the worker starts:
# kind=builder|reviewer, repo=owner/name, branch=B (builder), pr=N (reviewer, one line per PR).
# `relay` sends the lead a message with the dispatch, branch, sha and the worker's own summary (the body of the saved
# worker_done, not a path, because the saved file is deleted on release). No record, or an empty one, sends to the
# coordinator as a message only. The lead's terminal also gets a "check your inbox" nudge; a failed nudge does not fail the
# relay (the message was delivered), and the coordinator's terminal is never typed into.
# A successful release writes <dispatch id>.released (atomically), so a second release does nothing.
# `sweep` is the only writer of <dispatch id>.done.json. It reads the inbox with `orchestration inbox` (handled and
# unhandled mail, nothing is marked read, so a waiter that read first loses nothing) and only for records with a kind=
# line: old one line records are never relayed, released or listed. It relays once and releases the seat only on proof.
# <dispatch id>.relayed holds the relay state: "sending" before the send, "sent" after it. A pass that died in between
# leaves "sending": the next pass repeats once ("resending", then "sent"), so a crash gives at most one repeat; if that
# repeat died too, the marker becomes "sent" without a third send and one digest line says the relay may be lost.
# Only the exact word "sent" counts as relayed; an empty or half written marker is treated as "sending".
# A failed send removes the marker, keeps done.json, does not release, and is retried on the next pass, with one
# digest line however many passes fail. A failed nudge still counts as sent.
# The outcome is worker-show's state (the worker_done payload carries an outcome too); the payload's
# outcome is used only when worker-show is unreadable. Only succeeded can release a seat.
#   builder:  git ls-remote shows repo's branch at `git rev-parse HEAD` of the dispatch worktree. worker-show gives
#             result.workspace as "<id>::<path>"; the path must be on the record's branch and have a remote of the record's repo,
#   reviewer: each PR has a Verdict first line with head=<PR head now> and verifier=<this dispatch> (gh, skipped below 500 requests left).
# No proof: the seat stays and one digest line per dispatch is printed on stdout. A refused release is also one digest line
# and is retried each pass.
# Env: GH_COMMAND, WORKER_DONE_REMOTE_PREFIX (default https://github.com/).
set -euo pipefail
orca=${ORCA_CLI_COMMAND:-orca}
dir=${WORKER_DONE_OWNER_DIR:-$HOME/.claude/state/dispatch-owners}
die() { echo "worker-done-relay: $*" >&2; exit 2; }

[ $# -ge 1 ] || die "usage: relay|release|record|sweep ..."
mode=$1; shift
dispatch="" branch="" sha="" payload="" coordinator="" run="" lead="" kind="" repo="" prs=()
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "$1 needs a value"
  case "$1" in
    --dispatch) dispatch=$2 ;; --branch) branch=$2 ;; --sha) sha=$2 ;;
    --payload) payload=$2 ;; --coordinator) coordinator=$2 ;; --run) run=$2 ;;
    --lead) lead=$2 ;; --kind) kind=$2 ;; --repo) repo=$2 ;; --pr) prs+=("$2") ;;
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
    summary=$(python3 - "$payload" <<'PY' 2>/dev/null || true
import json, sys
try:
    body = json.load(open(sys.argv[1])).get('body')
except (OSError, ValueError, AttributeError):
    body = None
print(body[:1500] if isinstance(body, str) else '', end='')
PY
)
    text="dispatch=$dispatch branch=$branch sha=$sha"
    [ -z "$summary" ] || text="$text"$'\n'"summary: $summary"
    bounded "$orca" orchestration send --to "$to" --subject "$subject" --body "$text" --json || exit $?
    if [ "$to" != "$coordinator" ]; then
      bounded "$orca" terminal send --terminal "$to" --text "check your inbox" --enter --json > /dev/null \
        || echo "worker-done-relay: message sent but the nudge to $to failed" >&2
    fi
    ;;
  release)
    [ ! -f "$dir/$dispatch.released" ] || exit 0
    "$orca" orchestration worker-release --dispatch "$dispatch" --json
    mkdir -p "$dir" && printf 'released\n' > "$dir/$dispatch.released.$$.tmp" \
      && mv -f "$dir/$dispatch.released.$$.tmp" "$dir/$dispatch.released"
    ;;
  record)
    [[ "$lead" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "record needs --lead, a plain terminal handle"
    case "$kind" in ''|builder|reviewer) ;; *) die "--kind must be builder or reviewer" ;; esac
    [ -z "$repo" ] || [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be owner/name"
    [ -z "$branch" ] || [[ "$branch" =~ ^[A-Za-z0-9_./+-]+$ ]] || die "--branch is not a plain branch name"
    for number in ${prs[@]+"${prs[@]}"}; do [[ "$number" =~ ^[0-9]+$ ]] || die "--pr must be a number"; done
    mkdir -p "$dir"
    temporary="$dir/$dispatch.$$.tmp"
    if [ -z "$kind$repo$branch" ] && [ ${#prs[@]} -eq 0 ] && [ -f "$dir/$dispatch" ]; then
      { printf '%s\n' "$lead"; tail -n +2 "$dir/$dispatch"; } > "$temporary"
    else
      {
        printf '%s\n' "$lead"
        [ -z "$kind" ] || printf 'kind=%s\n' "$kind"
        [ -z "$repo" ] || printf 'repo=%s\n' "$repo"
        [ -z "$branch" ] || printf 'branch=%s\n' "$branch"
        for number in ${prs[@]+"${prs[@]}"}; do printf 'pr=%s\n' "$number"; done
      } > "$temporary"
    fi
    mv -f "$temporary" "$dir/$dispatch"
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
    if not isinstance(dispatch, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', dispatch):
        return None
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


def mark(name, text='noted'):
    """Write a marker whole or not at all: a crash leaves the old file, never an empty or half written one."""
    path = os.path.join(owners, name)
    temporary = '%s.%d.tmp' % (path, os.getpid())
    with open(temporary, 'w') as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def read_mark(name):
    try:
        return open(os.path.join(owners, name)).read().strip()
    except OSError:
        return None


def unmark(name):
    try:
        os.unlink(os.path.join(owners, name))
    except OSError:
        pass


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
        mark(dispatch + '.done.json', json.dumps(message))


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
    if not record or not record.get('kind'):
        return
    done = os.path.join(owners, dispatch + '.done.json')
    if os.path.exists(os.path.join(owners, dispatch + '.released')):
        unmark(dispatch + '.done.json')
        return
    try:
        payload = payload_of(json.load(open(done)))
    except (OSError, ValueError, AttributeError):
        payload = {}
    shown = show(dispatch)
    sha = head_of(shown, record) if record.get('kind') == 'builder' else None
    marker = dispatch + '.relayed'
    state = read_mark(marker)
    if state is not None and state not in ('sent', 'resending'):
        state = 'sending'   # only the exact word sent counts as relayed; an empty or half written marker is unknown
    if state == 'resending':
        mark(marker, 'sent')
        print('worker-done sweep: %s the relay to the lead may be lost (two passes died before the send finished)' % dispatch)
    elif state != 'sent':
        mark(marker, 'resending' if state else 'sending')
        relayed = subprocess.run(['bash', script, 'relay', '--dispatch', dispatch, '--branch', record.get('branch') or '-',
                                  '--sha', sha or '-', '--payload', done, '--coordinator', coordinator],
                                 capture_output=True, text=True).returncode
        if relayed != 0:
            unmark(marker)
            if read_mark(dispatch + '.sendfail') is None:
                mark(dispatch + '.sendfail')
                print('worker-done sweep: %s relay to the lead failed, will retry each pass' % dispatch)
            return   # nothing is released until the lead has the message
        mark(marker, 'sent')
        unmark(dispatch + '.sendfail')
    outcome = shown.get('state') or payload.get('outcome')
    reason = None if outcome == 'succeeded' else 'outcome is %s' % outcome
    reason = reason or proof(dispatch, record, sha)
    if reason == 'skip':
        return
    name = dispatch + '.noted'
    if reason is None:
        if subprocess.run(['bash', script, 'release', '--dispatch', dispatch], capture_output=True).returncode == 0:
            unmark(dispatch + '.done.json')
            return
        reason, name = 'release was refused, will retry each pass', dispatch + '.noted-release'
    if read_mark(name) is None:
        mark(name)
        print('worker-done sweep: %s seat kept, %s' % (dispatch, reason))


inbox = call(orca + ['orchestration', 'inbox', '--terminal', 'run:' + run if run else coordinator, '--limit', '200', '--full', '--json'], 60)
try:
    box = json.loads(inbox)
    messages = (box['result'] if isinstance(box.get('result'), dict) else box)['messages']
except (TypeError, ValueError, KeyError, AttributeError):
    messages = []
os.makedirs(owners, exist_ok=True)
for message in messages:
    try:
        if message.get('type') != 'worker_done':
            continue
        dispatch = payload_of(message).get('dispatchId')
        record = read_record(dispatch)
        if record and record.get('kind') and not os.path.exists(os.path.join(owners, dispatch + '.released')):
            store(dispatch, message)
    except (AttributeError, OSError) as error:
        print('worker-done sweep: skipped a message: %r' % error, file=sys.stderr)
for path in sorted(glob.glob(os.path.join(owners, '*.done.json'))):
    try:
        process(os.path.basename(path)[:-len('.done.json')])
    except Exception as error:   # one bad dispatch must not stop the others
        print('worker-done sweep: %s failed: %r' % (os.path.basename(path), error), file=sys.stderr)
PY
    ;;
  *) die "mode must be relay, release, record or sweep" ;;
esac
