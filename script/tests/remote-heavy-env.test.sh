#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
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
    def run_heavy(self, command, gate=True, extra=()):
        flags = ['--gate', self.gate] if gate else []
        flags += extra
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
    def test_homebrew_bin_is_appended_to_path_when_present(self):
        if not pathlib.Path('/opt/homebrew/bin').is_dir(): self.skipTest('no homebrew on this host')
        result = self.run_heavy(['sh', '-c', 'printf %s "$PATH"'])
        self.assertTrue(result.stdout.endswith(':/opt/homebrew/bin'), result.stdout)
    def test_homebrew_export_line_exists(self):
        # The directory is host specific, so pin the line itself.
        text = (scripts/'remote-heavy.sh').read_text()
        self.assertIn('[ ! -d /opt/homebrew/bin ] || export PATH="$PATH:/opt/homebrew/bin"', text)
    def test_no_gate_flag_uses_dotfiles_dir_gate(self):
        main = self.home/'dotfiles-main'; (main/'script').mkdir(parents=True)
        g = main/'script/heavy-gate.sh'; g.write_text('#!/bin/sh\nprintf "%s\\n" "$0" > "$GATE_OUT"\nshift 3\nexec "$@"\n'); g.chmod(0o755)
        result = self.run_heavy(['true'], gate=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.args.read_text().strip(), str(g))
    def gate_args(self, extra=(), env=None):
        full = self.root/'all-args'
        self.gate = self.stub('gate', '#!/bin/sh\nprintf "%s\\n" "$@" > "$ALL_ARGS"\nshift 2\n[ "$1" != --memory-mb ] || shift 2\nshift\nexec "$@"\n')
        saved = dict(self.env); self.env.update(env or {}, ALL_ARGS=str(full))
        try: result = self.run_heavy(['true'], extra=extra)
        finally: self.env = saved
        self.assertEqual(result.returncode, 0, result.stderr)
        return full.read_text().split()
    def test_memory_flag_is_forwarded_to_the_gate(self):
        args = self.gate_args(['--memory-mb', '2048'])
        self.assertEqual(args[:4], ['--weight', '1', '--memory-mb', '2048'], args)
    def test_memory_env_is_forwarded_and_flag_wins(self):
        self.assertEqual(self.gate_args(env={'HEAVY_GATE_MEMORY_MB': '3000'})[2:4], ['--memory-mb', '3000'])
        args = self.gate_args(['--memory-mb', '500'], env={'HEAVY_GATE_MEMORY_MB': '3000'})
        self.assertEqual(args[2:4], ['--memory-mb', '500'], args)
    def test_no_memory_declared_adds_nothing(self):
        args = self.gate_args()
        self.assertNotIn('--memory-mb', args)
        self.assertEqual(args[:2], ['--weight', '1'])
    def test_bad_memory_is_refused_before_ssh(self):
        for value in ('0', '-1', 'lots'):
            result = self.run_heavy(['true'], extra=['--memory-mb', value])
            self.assertEqual(result.returncode, 64, result.stderr)
            self.assertIn('memory', result.stderr)
if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
