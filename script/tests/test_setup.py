import os
import json
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import asdf_pin  # noqa: E402
asdf_pin.pin()  # before any test sets HOME

ROOT = Path(__file__).resolve().parents[2]
KEYS = ('sandbox_mode = "danger-full-access"', 'approval_policy = "never"',
        'model = "gpt-6.1-sol"', 'model_reasoning_effort = "medium"')


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.config = self.home / '.codex/config.toml'
        self.config.parent.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), DOTFILES=str(ROOT))
        self.env.update(CODEX_HOME=str(self.home / '.codex'),
                        XDG_CONFIG_HOME=str(self.home / '.config'),
                        APPDATA=str(self.home / 'AppData/Roaming'))
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.env['PATH'] = str(self.bin) + os.pathsep + os.environ['PATH']
        self.env['PLAYWRIGHT_BROWSERS_PATH'] = str(self.home / 'browsers')
        self.env['GH_CONFIG_DIR'] = str(self.home / '.config/gh')
        for command in ('gh', 'orca', 'bun', 'claude', 'codex', 'agent', 'agy'):
            executable = self.bin / command
            executable.write_text('#!/bin/sh\nexit 0\n')
            executable.chmod(0o700)

    def run_script(self, name):
        return subprocess.run(['bash', str(ROOT / 'script' / name)], env=self.env,
                              text=True, capture_output=True)

    def test_existing_config_gains_keys_preserving_other_lines(self):
        original = '# keep comment\nnotify = ["custom"]\n\n[profile]\nmodel = "custom"\n'
        self.config.write_text(original)
        result = self.run_script('setup-codex.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        updated = self.config.read_text()
        for key in KEYS:
            self.assertIn(key + '\n', updated)
            self.assertLess(updated.index(key), updated.index('[profile]'))
        self.assertEqual(''.join(line for line in updated.splitlines(True)
                                 if line.rstrip('\n') not in KEYS), original)
        backups = list(self.config.parent.glob('config.toml.bak*'))
        self.assertTrue(backups)
        self.assertTrue(any(path.read_text() == original for path in backups))

    def test_check_reports_missing_presets(self):
        result = self.run_script('setup-check.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MISSING presets.json\n', result.stdout)

    def test_replaces_only_top_level_values_and_keeps_backups(self):
        original = '\n'.join(key.split('=')[0] + '= "old"' for key in KEYS)
        original += '\n\n[profile]\nmodel = "custom"\n'
        self.config.write_text(original)
        self.assertEqual(self.run_script('setup-codex.sh').returncode, 0)
        expected = '\n'.join(KEYS) + '\n\n[profile]\nmodel = "custom"\n'
        self.assertEqual(self.config.read_text(), expected)
        backups = {p: p.read_bytes() for p in self.config.parent.glob('config.toml.bak*')}
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.run_script('setup-codex.sh').returncode, 0)
        self.assertEqual(self.config.read_text(), expected)
        self.assertEqual({p: p.read_bytes() for p in self.config.parent.glob('config.toml.bak*')}, backups)
        self.config.write_text('model = "old-again"\n')
        self.assertEqual(self.run_script('setup-codex.sh').returncode, 0)
        self.assertEqual(len(list(self.config.parent.glob('config.toml.bak*'))), 2)
        for path, content in backups.items():
            self.assertEqual(path.read_bytes(), content)

    def test_missing_config_is_initialized(self):
        result = self.run_script('setup-codex.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        for key in KEYS:
            self.assertIn(key + '\n', self.config.read_text())
        self.assertNotIn('__HOME__', self.config.read_text())

    def ready_home(self):
        # These deliberately customized fixture settings are covered by a private manifest.
        manifest = self.home / 'private-settings.manifest'
        names = ('.claude/settings.json', '.codex/config.toml', '.codex/hooks.json',
                 '.cursor/hooks.json', '.orca/presets.json')
        manifest.write_text(''.join('settings/item-' + str(i) + ' $HOME/' + name + '\n'
                                    for i, name in enumerate(names)))
        self.env['AGENT_PRIVATE_BACKUP_MANIFEST'] = str(manifest)
        for name in ('.claude/.credentials.json', '.codex/auth.json', '.config/cursor/auth.json', '.cursor/auth.json'):
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        self.config.write_text('\n'.join(KEYS) + '\n')
        presets = self.home / '.orca/presets.json'
        presets.parent.mkdir()
        presets.write_text('{}')
        skill = self.home / 'skill'
        skill.mkdir()
        for directory in ('.agents/skills', '.claude/skills'):
            root = self.home / directory
            root.mkdir(parents=True)
            (root / 'example').symlink_to(skill, target_is_directory=True)
        for name in ('.claude/settings.json', '.codex/hooks.json', '.cursor/hooks.json'):
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({'hooks': {'test': [{'command': 'true'}]}}))
        for engine, binary in (('chromium', 'chrome'), ('firefox', 'firefox'), ('webkit', 'pw_run.sh')):
            path = self.home / 'browsers' / (engine + '-123') / binary
            path.parent.mkdir(parents=True)
            path.write_text('#!/bin/sh\n')
            path.chmod(0o700)

    def test_check_ready_is_read_only_and_prints_one_line_per_item(self):
        self.ready_home()
        before = {p: (p.lstat().st_mtime_ns, p.read_bytes() if p.is_file() else None)
                  for p in self.home.rglob('*')}
        result = self.run_script('setup-check.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 27)
        self.assertTrue(all(line.startswith(('OK ', 'INFO ')) for line in result.stdout.splitlines()))
        self.assertEqual(before, {p: (p.lstat().st_mtime_ns, p.read_bytes() if p.is_file() else None)
                                  for p in self.home.rglob('*')})

    def test_check_rejects_each_missing_item(self):
        self.ready_home()
        cases = {'.orca/presets.json': 'presets.json',
                 '.agents/skills/example': 'shared skills links',
                 '.claude/skills/example': 'Claude skills links',
                 '.claude/settings.json': 'Claude agent hooks',
                 '.codex/hooks.json': 'Codex agent hooks',
                 '.cursor/hooks.json': 'Cursor agent hooks',
                 'browsers/webkit-123/pw_run.sh': 'playwright browsers'}
        for name, label in cases.items():
            with self.subTest(item=label):
                path = self.home / name
                held = self.home / 'held'
                path.rename(held)
                try:
                    result = self.run_script('setup-check.sh')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('MISSING ' + label + '\n', result.stdout)
                finally:
                    held.rename(path)

    def test_check_rejects_wrong_keys_even_if_profile_is_correct(self):
        self.ready_home()
        for key in KEYS:
            with self.subTest(key=key):
                self.config.write_text('\n'.join(KEYS).replace(key, key.split('=')[0] + '= "wrong"')
                                       + '\n[profile]\n' + key + '\n')
                result = self.run_script('setup-check.sh')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('MISSING Codex ' + key.split()[0] + '\n', result.stdout)

    def test_check_rejects_empty_hook_configuration(self):
        self.ready_home()
        (self.home / '.claude/settings.json').write_text('{}')
        result = self.run_script('setup-check.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MISSING Claude agent hooks\n', result.stdout)

    def test_check_rejects_failed_authentication(self):
        self.ready_home()
        (self.bin / 'gh').write_text('#!/bin/sh\nexit 1\n')
        result = self.run_script('setup-check.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MISSING gh auth\n', result.stdout)

    def test_agent_cli_and_sign_in_file_presence_never_reads_credentials(self):
        self.ready_home()
        for cli in ('claude', 'codex', 'agent', 'agy'):
            with self.subTest(cli=cli):
                result = self.run_script('setup-check.sh')
                self.assertIn('OK ' + cli + ' CLI\n', result.stdout)
                # Hide this CLI from PATH without exposing real machine CLIs.
                executable = self.bin / cli
                held = self.home / 'held-cli'
                executable.rename(held)
                try:
                    env = dict(self.env, PATH=str(self.bin) + ':/usr/bin:/bin')
                    result = subprocess.run(['/bin/bash', str(ROOT / 'script/setup-check.sh')],
                                            env=env, text=True, capture_output=True)
                    self.assertIn('MISSING ' + cli + ' CLI\n', result.stdout)
                    self.assertNotEqual(result.returncode, 0)
                finally:
                    held.rename(executable)
        for name in ('.claude/.credentials.json', '.codex/auth.json', '.config/cursor/auth.json', '.cursor/auth.json'):
            path = self.home / name
            path.write_text('SECRET_SENTINEL invalid JSON')
            path.chmod(0)
        result = self.run_script('setup-check.sh')
        self.assertNotIn('SECRET_SENTINEL', result.stdout + result.stderr)
        for cli in ('claude', 'codex', 'agent'):
            self.assertIn('OK ' + cli + ' sign-in file\n', result.stdout)
        self.assertIn('INFO agy sign-in file: system keyring', result.stdout)
        (self.home / '.codex/auth.json').unlink()
        result = self.run_script('setup-check.sh')
        self.assertIn('MISSING codex sign-in file\n', result.stdout)

    def test_install_finishes_with_checker_and_propagates_status(self):
        fixture = self.home / 'fixture'
        scripts = fixture / 'script'
        scripts.mkdir(parents=True)
        shutil.copyfile(ROOT / 'install.sh', fixture / 'install.sh')
        for name in ('.gitconfig', '.gitconfig-x64'):
            (fixture / name).write_text('')
        for name in ('agent-skills', 'claude-code', 'claude-desktop', 'cursor', 'codex',
                     'orca', 'obsidian', 'vscode', 'antigravity', 'zed'):
            (scripts / ('setup-' + name + '.sh')).write_text(
                'echo setup >> "$HOME/install-log"\n')
        (scripts / 'setup-check.sh').write_text(
            'echo check >> "$HOME/install-log"\nexit "$READINESS_STATUS"\n')
        (scripts / 'install-agent-clis.sh').write_text('echo agent-clis >> "$HOME/install-log"\n')
        (fixture / 'mac').mkdir()
        (fixture / 'mac/system_setup.sh').write_text('echo node >> "$HOME/install-log"\n')
        for skip in ('1', '0'):
            for status in (0, 1):
                with self.subTest(skip=skip, status=status):
                    log = self.home / 'install-log'
                    if log.exists():
                        log.unlink()
                    result = subprocess.run(['bash', str(fixture / 'install.sh')],
                                            env=dict(self.env, OSTYPE='test',
                                                     DOTFILES_SKIP_SYSTEM_SETUP=skip,
                                                     READINESS_STATUS=str(status)),
                                            text=True, capture_output=True)
                    self.assertEqual(result.returncode, status, result.stderr)
                    lines = log.read_text().splitlines()
                    self.assertEqual(lines[-1], 'check')
                    self.assertEqual(lines.count('check'), 1)
                    self.assertEqual(lines.count('setup'), 1 if skip == '1' else 10)
                    self.assertEqual(lines.count('agent-clis'), 0 if skip == '1' else 1)
        result = subprocess.run(['bash', str(fixture / 'install.sh')],
                                env=dict(self.env, OSTYPE='darwin', READINESS_STATUS='0'),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = (self.home / 'install-log').read_text().splitlines()[-13:]
        self.assertLess(lines.index('node'), lines.index('agent-clis'))


if __name__ == '__main__':
    unittest.main()
