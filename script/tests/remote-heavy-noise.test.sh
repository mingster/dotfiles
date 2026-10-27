#!/usr/bin/env bash
# No network: a fake ssh wraps every remote command in login-shell noise on stdout.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import os, pathlib, subprocess, sys, tempfile, unittest
scripts = pathlib.Path(sys.argv[1])
class NoisyRemoteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.bin = self.root/'bin'; self.bin.mkdir()
        self.local = self.root/'local'; self.remote = self.root/'remote'
        self.out = self.root/'shots'
        self.env = dict(os.environ, HOME=str(self.root), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null',
                        GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@e', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@e',
                        PATH=str(self.bin)+':'+os.environ['PATH'])
        for d in (self.local, self.remote):
            subprocess.run(['git','init','-q',str(d)],check=True,env=self.env)
        (self.local/'f').write_text('x')
        subprocess.run(['git','-C',str(self.local),'add','f'],check=True,env=self.env)
        subprocess.run(['git','-C',str(self.local),'commit','-qm','c'],check=True,env=self.env)
        self.sha = subprocess.run(['git','-C',str(self.local),'rev-parse','HEAD'],check=True,env=self.env,text=True,capture_output=True).stdout.strip()
        self.stub('ssh', '''#!/bin/sh
shift
echo "Welcome banner"
/bin/sh -c "$*"
status=$?
echo "fish is now exiting"
exit $status
''')
        self.stub('scp', '#!/bin/sh\nshift\ncp "${1#*:}" "$2"\n')
        self.stub('gate', '#!/bin/sh\nshift 3\nexec "$@"\n')
    def stub(self, name, text):
        p=self.bin/name; p.write_text(text); p.chmod(0o755)
    def run_heavy(self, flags, command):
        return subprocess.run(['bash',str(scripts/'remote-heavy.sh'),'--host','fixture','--repo-dir',str(self.remote),'--dir',str(self.remote),'--gate',str(self.bin/'gate'),*flags,'--',*command],cwd=self.local,env=self.env,text=True,capture_output=True)
    def test_push_and_run_survive_stdout_noise(self):
        result=self.run_heavy([],['sh','-c','printf job-output; exit 9'])
        self.assertEqual(result.returncode,9,result.stderr)
        self.assertEqual(result.stdout,'job-output')
        ref=subprocess.run(['git','-C',str(self.remote),'rev-parse',f'refs/heavy/{self.sha}'],env=self.env,text=True,capture_output=True)
        self.assertEqual(ref.stdout.strip(),self.sha,ref.stderr)
    def test_output_keeps_its_trailing_newline(self):
        result=self.run_heavy([],['sh','-c','echo line'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'line\n')
    def test_bundle_sends_only_commits_past_main(self):
        (self.local/'e').write_text('z')
        subprocess.run(['git','-C',str(self.local),'add','e'],check=True,env=self.env)
        subprocess.run(['git','-C',str(self.local),'commit','-qm','main 2'],check=True,env=self.env)
        subprocess.run(['git','-C',str(self.local),'branch','-M','main'],check=True,env=self.env)
        origin=self.root/'origin.git'
        subprocess.run(['git','clone','-q','--bare',str(self.local),str(origin)],check=True,env=self.env)
        subprocess.run(['git','-C',str(self.local),'remote','add','origin',str(origin)],check=True,env=self.env)
        subprocess.run(['git','-C',str(self.local),'fetch','-q','origin'],check=True,env=self.env)
        subprocess.run(['git','-C',str(self.remote),'remote','add','origin',str(origin)],check=True,env=self.env)
        (self.local/'g').write_text('y')
        subprocess.run(['git','-C',str(self.local),'add','g'],check=True,env=self.env)
        subprocess.run(['git','-C',str(self.local),'commit','-qm','d'],check=True,env=self.env)
        head=subprocess.run(['git','-C',str(self.local),'rev-parse','HEAD'],check=True,env=self.env,text=True,capture_output=True).stdout.strip()
        self.stub('ssh', '''#!/bin/sh
shift
cat > "$HOME/stdin.b64"
/bin/sh -c "$*" < "$HOME/stdin.b64"
''')
        result=self.run_heavy([],['sh','-c','echo ok'])
        self.assertEqual(result.returncode,0,result.stderr)
        bundle=subprocess.run(['base64','-d','-i',str(self.root/'stdin.b64')],capture_output=True).stdout
        header=bundle.split(b'\n\n',1)[0].decode()
        self.assertTrue(any(l.startswith('-') for l in header.splitlines()),header)
        ref=subprocess.run(['git','-C',str(self.remote),'rev-parse',f'refs/heavy/{head}'],env=self.env,text=True,capture_output=True)
        self.assertEqual(ref.stdout.strip(),head,ref.stderr)
    def test_fetch_survives_stdout_noise(self):
        result=self.run_heavy(['--fetch','*.png','--into',str(self.out)],['sh','-c','printf image > shot.png'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.out/'shot.png').read_text(),'image')
if __name__ == '__main__': unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
