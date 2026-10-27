#!/usr/bin/env bash
# No network: run the transported remote script locally under a fake HOME and stub git/ssh.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import os, pathlib, subprocess, sys, tempfile, unittest
scripts = pathlib.Path(sys.argv[1])
class Env(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.home = self.root/'home'; self.home.mkdir()
        self.bin = self.root/'bin'; self.bin.mkdir()
        self.remote = self.root/'lane'; self.remote.mkdir()
        self.args = self.root/'gate-args'
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin)+':'+os.environ['PATH'])
        self.env.pop('DOTFILES_DIR', None)
        self.stub('git', '#!/bin/sh\n[ "$1" != rev-parse ] || echo fixture-sha\n')
        self.stub('ssh', '#!/bin/sh\nshift\nexec /bin/sh -c "$*"\n')
        # The gate records its own path and the remote environment, then runs the job.
        self.gate = self.stub('gate', '#!/bin/sh\nprintf "%s\\n" "$0" > "$GATE_OUT"\nshift 3\nexec "$@"\n')
        self.env['GATE_OUT'] = str(self.args)
    def stub(self, name, text):
        p = self.bin/name; p.write_text(text); p.chmod(0o755); return str(p)
    def run_heavy(self, command, gate=True):
        flags = ['--gate', self.gate] if gate else []
        return subprocess.run(['bash', str(scripts/'remote-heavy.sh'), '--host', 'fixture', '--repo-dir', 'checkout', '--dir', str(self.remote), *flags, '--', *command], env=self.env, text=True, capture_output=True)
    def test_dotfiles_dir_is_set_when_main_checkout_exists(self):
        (self.home/'dotfiles-main').mkdir()
        result = self.run_heavy(['sh', '-c', 'printf %s "$DOTFILES_DIR"'])
        self.assertEqual(result.stdout, str(self.home/'dotfiles-main'), result.stderr)
    def test_dotfiles_dir_is_unset_without_main_checkout(self):
        result = self.run_heavy(['sh', '-c', 'printf "[%s]" "${DOTFILES_DIR-}"'])
        self.assertEqual(result.stdout, '[]', result.stderr)
    def test_core_perl_is_appended_to_path_when_present(self):
        if not pathlib.Path('/usr/bin/core_perl').is_dir(): self.skipTest('no core_perl on this host')
        result = self.run_heavy(['sh', '-c', 'printf %s "$PATH"'])
        self.assertTrue(result.stdout.endswith(':/usr/bin/core_perl'), result.stdout)
    def test_core_perl_export_line_exists(self):
        # The directory is host specific, so pin the line itself.
        text = (scripts/'remote-heavy.sh').read_text()
        self.assertIn('[ ! -d /usr/bin/core_perl ] || export PATH="$PATH:/usr/bin/core_perl"', text)
    def test_no_gate_flag_uses_dotfiles_dir_gate(self):
        main = self.home/'dotfiles-main'; (main/'script').mkdir(parents=True)
        g = main/'script/heavy-gate.sh'; g.write_text('#!/bin/sh\nprintf "%s\\n" "$0" > "$GATE_OUT"\nshift 3\nexec "$@"\n'); g.chmod(0o755)
        result = self.run_heavy(['true'], gate=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.args.read_text().strip(), str(g))
if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
