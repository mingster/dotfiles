#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# No network: execute the transported Bash payload locally and stub transfers.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import os, pathlib, subprocess, sys, tempfile, unittest
scripts = pathlib.Path(sys.argv[1])
class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.bin = self.root/'bin'; self.bin.mkdir()
        self.remote = self.root/"remote space ' quote"; self.remote.mkdir()
        self.out = self.root/'local shots'
        self.log = self.root/'calls'
        self.env = dict(os.environ, HOME=str(self.root), PATH=str(self.bin)+':'+os.environ['PATH'], CALLS=str(self.log))
        self.stub('git', '''#!/bin/sh
printf 'git %s\\n' "$*" >> "$CALLS"
[ "$1" != rev-parse ] || echo fixture-sha
[ "$1" != merge-base ] || echo "$MERGE_BASE"
if [ "$1" = -C ] && [ "$3" = fetch ]; then
  [ "$5" != origin ] || [ -z "$FAIL_ORIGIN_FETCH" ] || exit 1
  [ "$5" = origin ] || [ -z "$FAIL_BUNDLE_FETCH" ] || { echo 'error: Repository lacks these prerequisite commits' >&2; exit 1; }
fi
if [ "$1" = -C ] && [ "$3" = worktree ]; then mkdir -p "$7"; fi
''')
        self.stub('ssh', '''#!/bin/sh
printf 'ssh\\n' >> "$CALLS"
shift
# Emulate a non-Bash login shell parsing the word-list transport.
exec /bin/sh -c "$*"
''')
        self.stub('scp', '''#!/usr/bin/env python3
import os,sys,shutil
with open(os.environ['CALLS'], 'a') as f: f.write('scp\\n')
a = sys.argv[1:]
if a[0] == '--': a.pop(0)
shutil.copyfile(a[0].split(':',1)[1], a[1])
''')
        self.gate = self.stub('gate', '#!/bin/sh\nshift 3\nexec "$@"\n')
    def stub(self, name, text):
        p=self.bin/name; p.write_text(text); p.chmod(0o755); return str(p)
    def run_heavy(self, flags, command):
        return subprocess.run(['bash',str(scripts/'remote-heavy.sh'),'--host','fixture','--repo-dir','checkout','--dir',str(self.remote),'--gate',self.gate,*flags,'--',*command],env=self.env,text=True,capture_output=True)
    def test_fetch_after_failure(self):
        result=self.run_heavy(['--fetch','test-results/**/*.png','--into',str(self.out)],['bash','-c', 'mkdir -p "test-results/nested dir"; printf image > "test-results/nested dir/shot.png"; exit 7'])
        self.assertEqual(result.returncode,7,result.stderr)
        target=self.out/'shot.png'
        self.assertEqual(target.read_text(),'image')
        self.assertIn(str(target),result.stdout)
    def test_missing_remote_dir_is_created_as_worktree(self):
        self.remote=self.root/'new lane'
        result=self.run_heavy([],['sh','-c','pwd'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(f'git -C checkout worktree add -q --detach {self.remote} fixture-sha',self.log.read_text())
        self.assertEqual(result.stdout.strip(),str(self.remote))
    def test_no_end_marker_exits_255(self):
        self.stub('ssh','#!/bin/sh\nexit 0\n')
        result=self.run_heavy([],['true'])
        self.assertEqual(result.returncode,255)
        self.assertIn('remote setup failed',result.stderr)
    def test_branch_equal_to_main_bundle_stays_non_empty(self):
        self.env['MERGE_BASE']='fixture-sha'
        result=self.run_heavy([],['true'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('git bundle create - HEAD ^fixture-sha^',self.log.read_text())
    def test_failed_origin_fetch_still_runs_command(self):
        self.env['FAIL_ORIGIN_FETCH']='1'
        result=self.run_heavy([],['sh','-c','printf ran'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'ran')
    def test_missing_bundle_prerequisite_is_explained(self):
        self.env['FAIL_BUNDLE_FETCH']='1'
        result=self.run_heavy([],['true'])
        self.assertEqual(result.returncode,255)
        self.assertIn('lacks the base commit of the bundle',result.stderr)
    def test_no_fetch_keeps_single_ssh_and_status(self):
        result=self.run_heavy([],['sh','-c','printf job-output; exit 9'])
        self.assertEqual(result.returncode,9,result.stderr)
        self.assertEqual(result.stdout,'job-output')
        self.assertEqual([l for l in self.log.read_text().splitlines() if not l.startswith('git ')],['ssh'])
    def test_repeat_fetch_and_unmatched_glob(self):
        result=self.run_heavy(['--fetch','test-results/**/*.png','--fetch','other file.txt','--fetch','missing/*','--into',str(self.out)],['sh','-c','mkdir test-results; printf root > test-results/root.png; printf other > "other file.txt"'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.out/'root.png').read_text(),'root')
        self.assertEqual((self.out/'other file.txt').read_text(),'other')
    def test_shot_refuses_wrong_database_without_leaking(self):
        envfile=self.root/'private env'
        envfile.write_text('DATABASE_URL=postgresql://fixture:secret@db.example/wrong_db?sslmode=require\n')
        result=self.run_shot(envfile)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('db.example',result.stdout)
        self.assertIn('wrong_db',result.stdout)
        self.assertNotIn('secret',result.stdout+result.stderr)
        self.assertNotIn('postgresql://',result.stdout+result.stderr)
        self.assertFalse((self.remote/'playwright-ran').exists())
    def test_shot_runs_matching_database_and_fetches_failed_test_artifact(self):
        envfile=self.root/'private env'
        envfile.write_text('DATABASE_URL=postgresql://fixture:secret@db.example/expected_db\n')
        result=self.run_shot(envfile)
        self.assertEqual(result.returncode,5,result.stdout+result.stderr)
        self.assertEqual((self.out/'shot.png').read_text(),'screenshot')
        self.assertNotIn('secret',result.stdout+result.stderr)
    def test_shot_invalid_url_is_redacted(self):
        envfile=self.root/'private env'
        envfile.write_text('DATABASE_URL=invalid-secret-url\n')
        result=self.run_shot(envfile)
        self.assertEqual(result.returncode,64,result.stdout+result.stderr)
        self.assertNotIn('invalid-secret-url',result.stdout+result.stderr)
        self.assertFalse((self.remote/'playwright-ran').exists())
    def test_shot_requires_expected_database(self):
        result=subprocess.run(['bash',str(scripts/'remote-shot.sh')],env=self.env,text=True,capture_output=True)
        self.assertEqual(result.returncode,64)
        self.assertIn('--expect-db',result.stderr)
        self.assertFalse(self.log.exists())
    def test_copy_failure_keeps_command_status(self):
        self.stub('scp','#!/bin/sh\nexit 23\n')
        result=self.run_heavy(['--fetch','*.png','--into',str(self.out)],['sh','-c','touch shot.png; exit 6'])
        self.assertEqual(result.returncode,6,result.stderr)
        self.assertIn('artifact copy failed',result.stderr)
    def run_shot(self, envfile, expect='expected_db'):
        # Use the real Bun env loader and URL parser; only the Playwright boundary is stubbed.
        import shutil
        real_bun=shutil.which('bun')
        self.stub('bun', '#!/bin/sh\nif [ "$3" = x ]; then touch playwright-ran; mkdir -p test-results/nested; printf screenshot > test-results/nested/shot.png; exit 5; fi\nexec '+__import__('shlex').quote(real_bun)+' "$@"\n')
        return subprocess.run(['bash',str(scripts/'remote-shot.sh'),'--host','fixture','--repo-dir','checkout','--dir',str(self.remote),'--sub','.','--gate',self.gate,'--spec','e2e/capture spec.ts','--env-file',str(envfile),'--expect-db',expect,'--out',str(self.out)],env=self.env,text=True,capture_output=True)
if __name__ == '__main__': unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
