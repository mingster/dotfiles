"""No-network vendor installer tests with a disposable home and repository."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AgentCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.repo = self.home / 'dotfiles'
        (self.repo / 'script').mkdir(parents=True)
        (self.repo / 'arch/bin').mkdir(parents=True)
        for name in ('install-agent-clis.sh', 'install_claude.sh'):
            shutil.copyfile(ROOT / 'script' / name, self.repo / 'script' / name)
        shutil.copyfile(ROOT / '.gitignore', self.repo / '.gitignore')
        self.rc = self.repo / '.zshrc'
        self.rc.write_bytes(b'# existing local change\nexport PATH="$HOME/.local/bin:$PATH"')
        (self.home / '.zshrc').symlink_to(self.rc)
        (self.home / '.profile').write_text('# outside repo\n')
        (self.home / '.local').mkdir()
        (self.home / '.local/bin').symlink_to(self.repo / 'arch/bin', target_is_directory=True)
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'add', '.zshrc', '.gitignore'], check=True)
        self.bin = self.home / 'stubs'
        self.bin.mkdir()
        (self.bin / 'python3').symlink_to(sys.executable)
        (self.bin / 'curl').write_text('''#!/bin/bash
case "$*" in
  *claude.ai*) tool=claude ;; *cursor.com*) tool=agent ;; *antigravity.google*) tool=agy ;; *) exit 99 ;;
esac
echo "$tool" >> "$HOME/vendor-log"
printf 'printf "#!/bin/sh\\\\nexit 0\\\\n" > "$HOME/.local/bin/%s"\nchmod +x "$HOME/.local/bin/%s"\nprintf "\\\\n# vendor PATH\\\\n" >> "$HOME/.zshrc"\nprintf "# vendor PATH\\\\n" >> "$HOME/.profile"\nexit "${VENDOR_EXIT:-0}"\n' "$tool" "$tool"
''')
        for name in ('curl',):
            (self.bin / name).chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), DOTFILES=str(self.repo),
                        ASDF_DATA_DIR=str(self.home / '.asdf'), ZDOTDIR=str(self.home),
                        PATH=str(self.bin) + ':/usr/bin:/bin')

    def install(self):
        return subprocess.run(['/bin/bash', str(self.repo / 'script/install-agent-clis.sh')],
                              env=self.env, text=True, capture_output=True)

    def test_preserves_tracked_rc_and_reports_outside_rc(self):
        original = self.rc.read_bytes()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rc.read_bytes(), original)
        self.assertIn(str(self.home / '.profile'), result.stdout)
        self.assertIn('# vendor PATH', (self.home / '.profile').read_text())

    def test_failed_vendor_still_cleans_tracked_rc(self):
        original = self.rc.read_bytes()
        self.env['VENDOR_EXIT'] = '19'
        result = self.install()
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual(self.rc.read_bytes(), original)

    def test_installs_once_and_ignores_vendor_binaries_through_legacy_symlink(self):
        for _ in range(2):
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / 'vendor-log').read_text().splitlines(),
                         ['claude', 'agent', 'agy'])
        for cli in ('claude', 'agent', 'cursor-agent', 'agy'):
            result = subprocess.run(['git', '-C', str(self.repo), 'check-ignore', 'arch/bin/' + cli],
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, cli)
        result = subprocess.run(['git', '-C', str(self.repo), 'check-ignore', 'arch/bin/custom-helper'],
                                capture_output=True)
        self.assertEqual(result.returncode, 1)


if __name__ == '__main__':
    unittest.main()
