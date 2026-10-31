#!/usr/bin/env bash
# Exercise the launch boundary without starting an agent or writing to the real HOME.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=tests/lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
# Resolve python before HOME changes; the asdf shim otherwise loses its installs.
if command -v asdf >/dev/null 2>&1; then PATH="$(dirname "$(asdf which python3)"):$PATH"; fi
mkdir -p "$tmp/home" "$tmp/bin"
export HOME="$tmp/home" CURSOR_TEST_LOG="$tmp/calls" ORCA_CLI_COMMAND="$tmp/bin/orca"
cat > "$ORCA_CLI_COMMAND" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CURSOR_TEST_LOG"
case "$*" in
  'worktree create '*)
    if [ -n "${CURSOR_FAIL_CREATE:-}" ]; then
      echo '{"ok":false,"error":"fixture create failed"}'
      echo 'fixture create stderr' >&2
      exit 17
    fi
    printf '%s\n' '{"result":{"worktree":{"path":"/tmp/example.repo/work tree.v1"}}}' ;;
  'orchestration worker-start '*)
    python3 - <<'PY'
import json, os
from datetime import datetime
with open(os.environ['HOME'] + '/.cursor/projects/tmp-example-repo-work tree-v1/.workspace-trusted') as f:
    marker = json.load(f)
assert marker['workspacePath'] == '/tmp/example.repo/work tree.v1'
datetime.strptime(marker['trustedAt'], '%Y-%m-%dT%H:%M:%SZ')
PY
    printf '%s\n' '{"result":{"state":"dispatched"}}' ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$ORCA_CLI_COMMAND"
printf 'Do the fixture task.\n' > "$tmp/spec"
launch() { bash "$root/script/start-cursor-worker.sh" --run run_fixture --spec "$tmp/spec" --title 'fullstack-dev - fixture' --model composer-2.5 --from term_fixture "$@"; }
launch --name fixture --repo /tmp/example.repo --base-branch origin/main > "$tmp/result"
grep -q 'worktree create.*--base-branch origin/main' "$CURSOR_TEST_LOG"
grep -q 'worker-start.*--agent cursor.*--model composer-2.5' "$CURSOR_TEST_LOG"
grep -q -- '--worktree path:/tmp/example.repo/work tree.v1' "$CURSOR_TEST_LOG"
echo 'PASS: new worktree is trusted at the encoded path before dispatch'
for selector in id:abc path:/tmp/example.repo; do
  : > "$CURSOR_TEST_LOG"
  launch --name fixture --repo "$selector" --base-branch origin/main > "$tmp/result"
  grep -Fq -- "--repo $selector --base-branch" "$CURSOR_TEST_LOG"
  echo "PASS: local repo selector $selector is passed through unchanged"
done
: > "$CURSOR_TEST_LOG"
launch --name fixture --repo id:abc > "$tmp/result"
grep -Fq -- '--repo id:abc --setup' "$CURSOR_TEST_LOG"
echo 'PASS: local id selector uses the Orca default base without local git access'
cat > "$tmp/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
test "$#" -eq 6
test "$1" = -C && test "$2" = '/tmp/example repo'
test "$3 $4 $5 $6" = 'symbolic-ref --quiet --short refs/remotes/origin/HEAD'
echo origin/fixture-main
STUB
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH"
for selector in '/tmp/example repo' 'path:/tmp/example repo'; do
  : > "$CURSOR_TEST_LOG"
  launch --name fixture --repo "$selector" > "$tmp/result"
  grep -Fq -- '--repo path:/tmp/example repo --base-branch origin/fixture-main' "$CURSOR_TEST_LOG"
  echo 'PASS: local path resolves its default base using the unprefixed directory'
done
: > "$CURSOR_TEST_LOG"
launch --worktree-path '/tmp/example.repo/work tree.v1' > "$tmp/result"
! grep -q 'worktree create' "$CURSOR_TEST_LOG"
echo 'PASS: existing worktree can be trusted and dispatched again'
: > "$CURSOR_TEST_LOG"
if CURSOR_FAIL_CREATE=1 launch --name fixture --repo /tmp/example.repo --base-branch origin/main > "$tmp/result" 2>&1; then
  echo 'FAIL: failed local creation was accepted' >&2; exit 1
else
  test "$?" -eq 17
fi
grep -q 'fixture create failed' "$tmp/result"
grep -q 'fixture create stderr' "$tmp/result"
if grep -q 'worker-start' "$CURSOR_TEST_LOG"; then
  echo 'FAIL: failed local worktree creation dispatched a worker' >&2; exit 1
fi
echo 'PASS: failed local worktree creation prints diagnostics and preserves exit status before dispatch'
# The remote command must write into the execution host HOME before dispatch.
export CURSOR_REMOTE_HOME="$tmp/remote-home"
mkdir -p "$CURSOR_REMOTE_HOME"
mkdir -p "$CURSOR_REMOTE_HOME/bin"
printf '#!/bin/sh\nexit 0\n' > "$CURSOR_REMOTE_HOME/bin/agent"
chmod +x "$CURSOR_REMOTE_HOME/bin/agent"
cat > "$ORCA_CLI_COMMAND" <<'STUB'
#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CURSOR_TEST_LOG'], 'a') as f:
    f.write(json.dumps(args) + '\n')
def value(flag):
    return args[args.index(flag) + 1]
def reply(result):
    print(json.dumps({'ok': True, 'result': result}))
if args[:2] == ['worktree', 'create']:
    assert value('--environment') == 'fixture-environment'
    assert value('--repo') == os.environ.get('CURSOR_EXPECT_REPO', 'path:/srv/example.repo')
    if os.environ.get('CURSOR_FAIL_CREATE'):
        print('{"ok":false,"error":"fixture create failed"}')
        print('fixture create stderr', file=sys.stderr)
        sys.exit(17)
    reply({'worktree': {'path': '/srv/example.repo/work tree.v1'}})
elif args[:2] == ['terminal', 'create']:
    assert value('--environment') == 'fixture-environment'
    assert value('--worktree') == 'path:/srv/example.repo/work tree.v1'
    env = dict(os.environ, HOME=os.environ['CURSOR_REMOTE_HOME'])
    if value('--command').startswith('if command -v'):
        env['PATH'] = str(Path(os.environ['CURSOR_REMOTE_HOME'], 'bin'))
        code = subprocess.run(value('--command'), shell=True, env=env).returncode
    elif os.environ.get('CURSOR_FAIL_TRUST'):
        code = 1
    else:
        code = subprocess.run(value('--command'), shell=True, env=env).returncode
    Path(os.environ['CURSOR_REMOTE_HOME'], 'exit-code').write_text(str(code))
    reply({'terminal': {'handle': 'term_remote_fixture'}})
elif args[:2] == ['terminal', 'wait']:
    assert value('--environment') == 'fixture-environment'
    assert value('--terminal') == 'term_remote_fixture'
    assert value('--for') == 'exit'
    code = int(Path(os.environ['CURSOR_REMOTE_HOME'], 'exit-code').read_text())
    wait = {'satisfied': True, 'status': 'exited', 'exitCode': code}
    if os.environ.get('CURSOR_WAIT_MODE') == 'timeout':
        wait.update(satisfied=False, status='running', exitCode=None)
    elif os.environ.get('CURSOR_WAIT_MODE') == 'unknown':
        del wait['exitCode']
    reply({'wait': wait})
elif args[:2] == ['terminal', 'close']:
    assert value('--environment') == 'fixture-environment'
    assert value('--terminal') == 'term_remote_fixture'
    reply({'close': {'ptyKilled': True}})
elif args[:2] == ['orchestration', 'worker-start']:
    assert value('--on') == 'fixture-environment'
    assert value('--worktree') == 'path:/srv/example.repo/work tree.v1'
    marker = Path(os.environ['CURSOR_REMOTE_HOME'], '.cursor/projects/srv-example-repo-work tree-v1/.workspace-trusted')
    data = json.loads(marker.read_text())
    assert data['workspacePath'] == '/srv/example.repo/work tree.v1'
    from datetime import datetime
    datetime.strptime(data['trustedAt'], '%Y-%m-%dT%H:%M:%SZ')
    assert not Path(os.environ['HOME'], '.cursor/projects/srv-example-repo-work tree-v1').exists()
    reply({'state': 'dispatched'})
else:
    sys.exit(99)
STUB
: > "$CURSOR_TEST_LOG"
launch --on fixture-environment --name fixture --repo /srv/example.repo --base-branch origin/main > "$tmp/result"
python3 - "$CURSOR_TEST_LOG" <<'PYTEST'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert [call[:2] for call in calls] == [['worktree', 'create'], ['terminal', 'create'], ['terminal', 'wait'], ['terminal', 'close'], ['terminal', 'create'], ['terminal', 'wait'], ['terminal', 'close'], ['orchestration', 'worker-start']]
assert '--base-branch' in calls[0]
assert '/srv/example.repo/work tree.v1' in calls[1][calls[1].index('--command') + 1]
PYTEST
echo 'PASS: remote worktree is trusted in the remote HOME before dispatch'
for selector in id:abc path:/srv/example.repo; do
  : > "$CURSOR_TEST_LOG"
  CURSOR_EXPECT_REPO="$selector" launch --on fixture-environment --name fixture --repo "$selector" > "$tmp/result"
  echo "PASS: remote repo selector $selector is passed through unchanged"
done
: > "$CURSOR_TEST_LOG"
launch --on fixture-environment --name fixture --repo /srv/example.repo > "$tmp/result"
python3 - "$CURSOR_TEST_LOG" <<'PYTEST'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert '--base-branch' not in calls[0]
PYTEST
echo 'PASS: remote creation uses the remote default base without local git access'
: > "$CURSOR_TEST_LOG"
launch --on fixture-environment --worktree-path '/srv/example.repo/work tree.v1' > "$tmp/result"
! grep -q 'worktree.*,.*create' "$CURSOR_TEST_LOG"
echo 'PASS: existing remote worktree is trusted before dispatch'
: > "$CURSOR_TEST_LOG"
if CURSOR_FAIL_CREATE=1 launch --on fixture-environment --name fixture --repo /srv/example.repo --base-branch origin/main > "$tmp/result" 2>&1; then
  echo 'FAIL: failed remote creation was accepted' >&2; exit 1
else
  test "$?" -eq 17
fi
grep -q 'fixture create failed' "$tmp/result"
grep -q 'fixture create stderr' "$tmp/result"
if grep -Eq 'terminal|worker-start' "$CURSOR_TEST_LOG"; then
  echo 'FAIL: failed remote worktree creation continued to trust or dispatch' >&2; exit 1
fi
echo 'PASS: failed remote worktree creation prints diagnostics and preserves exit status before trust or dispatch'
: > "$CURSOR_TEST_LOG"
if CURSOR_FAIL_TRUST=1 launch --on fixture-environment --worktree-path '/srv/example.repo/work tree.v1' > "$tmp/result" 2>&1; then
  echo 'FAIL: failed remote trust was accepted' >&2; exit 1
fi
grep -q 'remote workspace trust did not complete successfully' "$tmp/result"
! grep -q 'worker-start' "$CURSOR_TEST_LOG"
echo 'PASS: failed remote trust stops dispatch'
for mode in timeout unknown; do
  : > "$CURSOR_TEST_LOG"
  if CURSOR_WAIT_MODE="$mode" launch --on fixture-environment --worktree-path '/srv/example.repo/work tree.v1' > "$tmp/result" 2>&1; then
    echo "FAIL: $mode remote trust completion was accepted" >&2; exit 1
  fi
  grep -q 'remote workspace trust did not complete successfully' "$tmp/result"
  ! grep -q 'worker-start' "$CURSOR_TEST_LOG"
  echo "PASS: $mode remote trust completion stops dispatch"
done
: > "$CURSOR_TEST_LOG"
rm "$CURSOR_REMOTE_HOME/bin/agent"
if launch --on fixture-environment --worktree-path '/srv/example.repo/work tree.v1' > "$tmp/result" 2>&1; then
  echo 'FAIL: missing remote agent CLI was accepted' >&2; exit 1
fi
grep -q 'required CLI agent' "$tmp/result"
! grep -q 'worker-start' "$CURSOR_TEST_LOG"
echo 'PASS: missing remote agent CLI stops dispatch and names the CLI'
printf ' \n' > "$tmp/spec"; : > "$CURSOR_TEST_LOG"
if launch --worktree-path /tmp/fixture > "$tmp/result" 2>&1; then
  echo 'FAIL: blank spec was accepted' >&2; exit 1
fi
grep -q 'spec file is empty' "$tmp/result"
test ! -s "$CURSOR_TEST_LOG"
echo 'PASS: blank spec is refused before any Orca call'
echo 'PASS: 19 tests'
