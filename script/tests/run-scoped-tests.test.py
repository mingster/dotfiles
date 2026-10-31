#!/usr/bin/env python3
"""Exercise the selector through its CLI and real fixture files."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

HELPER = pathlib.Path(__file__).resolve().parents[1] / 'run-scoped-tests.py'


class ScopedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = pathlib.Path(self.temp.name)
        self.write('web/tsconfig.json', json.dumps({'compilerOptions': {'paths': {'@/*': ['./src/*']}}}))
        self.write('web/src/lib/send.server.ts', 'export const send = 1;')
        self.write('web/src/lib/send.server.test.ts', '')
        self.write('web/src/lib/__tests__/local.test.ts', '')
        self.write('web/src/notification/__tests__/notification-service.test.ts', 'import {send} from "@/lib/send.server";')
        self.write('web/src/db/__tests__/no-update-many-claims-contract.test.ts', 'mock.module("@/lib/send.server", () => ({}));')
        self.write('web/src/app/api/__tests__/route.test.ts', 'const x = import("../../../lib/send.server");')
        self.write('web/src/other/ignored.test.ts', 'import "unrelated";')
        self.write('capture.py', 'import json,sys,pathlib; pathlib.Path("selected.json").write_text(json.dumps(sys.argv[1:]))')

    def write(self, path, contents):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)

    def run_helper(self, *files, root='web'):
        return subprocess.run([sys.executable, str(HELPER), '--root', root, '--runner', f'{sys.executable} {self.repo / "capture.py"}', *files], cwd=self.repo, text=True, capture_output=True)

    def test_changed_and_sibling_tests_run_from_component_root(self):
        result = self.run_helper('web/src/lib/send.server.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = json.loads((self.repo / 'web/selected.json').read_text())
        self.assertIn('./src/lib/send.server.test.ts', selected)
        self.assertIn('./src/lib/__tests__/local.test.ts', selected)
        self.assertNotIn('./src/other/ignored.test.ts', selected)

    def test_importers_anywhere_with_alias_relative_and_dynamic_import(self):
        result = self.run_helper('web/src/lib/send.server.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = json.loads((self.repo / 'web/selected.json').read_text())
        for path in ['notification/__tests__/notification-service.test.ts', 'db/__tests__/no-update-many-claims-contract.test.ts', 'app/api/__tests__/route.test.ts']:
            self.assertIn('./src/' + path, selected)

    def test_source_contract_references_are_selected(self):
        self.write('web/src/db/__tests__/no-update-many-claims-contract.test.ts',
                   'const allowed = {"src/lib/send.server.ts#claim": "safe"};')
        result = self.run_helper('web/src/lib/send.server.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = json.loads((self.repo / 'web/selected.json').read_text())
        self.assertIn('./src/db/__tests__/no-update-many-claims-contract.test.ts', selected)

    def test_projb_root_changed_test_and_quoted_path(self):
        self.write('web2/projb_web/src/path with space.test.ts', '')
        result = self.run_helper('web2/projb_web/src/path with space.test.ts', root='web2/projb_web')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.repo / 'web2/projb_web/selected.json').read_text()), ['./src/path with space.test.ts'])

    def test_no_tests_does_not_start_runner(self):
        result = self.run_helper('README.md')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scoped tests: 0', result.stdout)
        self.assertFalse((self.repo / 'web/selected.json').exists())

    def test_directory_guard_selects_scanner_without_imports_or_changed_tests(self):
        self.write('web/src/admin/new.tsx', 'export const view = "Hello";')
        self.write('web/guards/copy.test.ts', '// scans admin sources without imports')
        result = self.run_helper('--directory-guard', 'src/admin', 'guards/copy.test.ts',
                                 'web/src/admin/new.tsx')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.repo / 'web/selected.json').read_text()),
                         ['./guards/copy.test.ts'])

    def test_unmapped_directory_keeps_exact_selection(self):
        self.write('web/src/admin/new.tsx', 'export const view = 1;')
        self.write('web/guards/copy.test.ts', '// scans admin')
        result = self.run_helper('web/src/admin/new.tsx')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scoped tests: 0', result.stdout)
        self.assertFalse((self.repo / 'web/selected.json').exists())

    def test_directory_guard_respects_segments_and_component_root(self):
        self.write('web/guards/copy.test.ts', '')
        result = self.run_helper('--directory-guard', 'src/admin', 'guards/copy.test.ts',
                                 'web/src/administrator/new.tsx', 'other/src/admin/new.tsx')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scoped tests: 0', result.stdout)
        self.assertFalse((self.repo / 'web/selected.json').exists())

    def test_directory_guards_support_spaces_and_deduplicate_overlaps(self):
        self.write('web/guards/copy guard.test.ts', '')
        self.write('web/src/admin area/new.tsx', '')
        result = self.run_helper('--directory-guard', 'src', 'guards/copy guard.test.ts',
                                 '--directory-guard', 'src/admin area', 'guards/copy guard.test.ts',
                                 '--directory-guard', 'src/admin area', 'guards/copy guard.test.ts',
                                 'web/src/admin area/new.tsx')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.repo / 'web/selected.json').read_text()),
                         ['./guards/copy guard.test.ts'])

    def test_deleted_and_renamed_paths_trigger_each_affected_directory(self):
        self.write('web/guards/old.test.ts', '')
        self.write('web/guards/new.test.ts', '')
        self.write('web/src/new/moved.ts', '')
        result = self.run_helper('--directory-guard', 'src/deleted', 'guards/old.test.ts',
                                 '--directory-guard', 'src/new', 'guards/new.test.ts',
                                 'web/src/deleted/gone.ts', 'web/src/new/moved.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.repo / 'web/selected.json').read_text()),
                         ['./guards/new.test.ts', './guards/old.test.ts'])

    def test_invalid_directory_guard_fails_before_runner_even_without_changes(self):
        self.write('web/guards/copy.test.ts', '')
        self.write('outside.test.ts', '')
        self.write('web/guards/plain.ts', '')
        (self.repo / 'web/escape').symlink_to(self.repo, target_is_directory=True)
        cases = [('', 'guards/copy.test.ts'), ('../outside', 'guards/copy.test.ts'),
                 (str(self.repo / 'web/src'), 'guards/copy.test.ts'),
                 ('escape/src', 'guards/copy.test.ts'), ('src', '../outside.test.ts'),
                 ('src', str(self.repo / 'outside.test.ts')), ('src', ''),
                 ('src', 'escape/outside.test.ts'), ('src', 'guards/missing.test.ts'),
                 ('src', 'guards/plain.ts')]
        for directory, guard in cases:
            with self.subTest(directory=directory, guard=guard):
                result = self.run_helper('--directory-guard', directory, guard)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('directory guard:', result.stderr)
                self.assertFalse((self.repo / 'web/selected.json').exists())

    def test_directory_guard_rejects_e2e_and_database_specs(self):
        for guard in ['e2e/copy.spec.ts', 'guards/copy.db.spec.ts']:
            with self.subTest(guard=guard):
                self.write('web/' + guard, '')
                result = self.run_helper('--directory-guard', 'src/admin', guard,
                                         'web/src/admin/new.ts')
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('directory guard:', result.stderr)
                self.assertFalse((self.repo / 'web/selected.json').exists())

    def test_directory_guard_preserves_existing_selection_and_test_change_option(self):
        self.write('web/guards/copy.test.ts', '')
        self.write('web/guards/contracts.test.ts', '')
        result = self.run_helper('--directory-guard', 'src/lib', 'guards/copy.test.ts',
                                 '--on-test-change', 'guards/contracts.test.ts',
                                 'web/src/lib/send.server.ts', 'web/src/lib/send.server.test.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = json.loads((self.repo / 'web/selected.json').read_text())
        self.assertEqual(selected, ['./guards/contracts.test.ts', './guards/copy.test.ts',
                                   './src/app/api/__tests__/route.test.ts',
                                   './src/db/__tests__/no-update-many-claims-contract.test.ts',
                                   './src/lib/__tests__/local.test.ts', './src/lib/send.server.test.ts',
                                   './src/notification/__tests__/notification-service.test.ts'])

    def test_directory_guard_browser_suite_stays_unchecked_without_browser(self):
        self.write('web/guards/browser.test.ts', 'import {test} from "@playwright/test";')
        # A disposable PATH stub proves the existing unavailable-browser path without launching one.
        self.write('tools/bun', '#!/bin/sh\nexit 1\n')
        (self.repo / 'tools/bun').chmod(0o755)
        from unittest import mock
        with mock.patch.dict(os.environ, PATH=str(self.repo / 'tools') + os.pathsep + os.environ['PATH']):
            result = self.run_helper('--directory-guard', 'src/admin', 'guards/browser.test.ts',
                                     'web/src/admin/new.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('UNCHECKED: guards/browser.test.ts', result.stdout)
        self.assertIn('Scoped tests: 0', result.stdout)
        self.assertFalse((self.repo / 'web/selected.json').exists())

    def test_renamed_test_selects_configured_contract_tests(self):
        # A rename reaches the selector as the new path; the old path no longer exists.
        self.write('web/src/__tests__/mocks-contract.test.ts', '')
        self.write('web/src/moved/__tests__/moved.test.ts', '')
        result = self.run_helper('--on-test-change', 'src/__tests__/*-contract.test.ts',
                                 'web/src/old/__tests__/moved.test.ts', 'web/src/moved/__tests__/moved.test.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = json.loads((self.repo / 'web/selected.json').read_text())
        self.assertIn('./src/__tests__/mocks-contract.test.ts', selected)
        self.assertIn('./src/moved/__tests__/moved.test.ts', selected)

    def test_deleted_test_selects_configured_contract_tests(self):
        self.write('web/src/__tests__/mocks-contract.test.ts', '')
        result = self.run_helper('--on-test-change', 'src/__tests__/*-contract.test.ts', 'web/src/gone/__tests__/gone.test.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = json.loads((self.repo / 'web/selected.json').read_text())
        self.assertEqual(selected, ['./src/__tests__/mocks-contract.test.ts'])

    def test_no_test_change_does_not_select_contract_tests(self):
        self.write('web/src/__tests__/mocks-contract.test.ts', '')
        result = self.run_helper('--on-test-change', 'src/__tests__/*-contract.test.ts', 'web/src/lib/send.server.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = json.loads((self.repo / 'web/selected.json').read_text())
        self.assertNotIn('./src/__tests__/mocks-contract.test.ts', selected)

    def test_playwright_specs_under_e2e_are_not_bun_tests(self):
        self.write('web/e2e/regression/rsvp/booking.spec.ts', '')
        result = self.run_helper('web/e2e/regression/rsvp/booking.spec.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scoped tests: 0', result.stdout)
        self.assertFalse((self.repo / 'web/selected.json').exists())

    def test_db_integration_specs_are_not_unit_tests(self):
        # *.db.spec.* files need a test database and run under the integration config.
        self.write('web/src/orders/order.server.ts', 'export const order = 1;')
        self.write('web/src/orders/order.server.db.spec.ts', 'import {order} from "./order.server";')
        result = self.run_helper('web/src/orders/order.server.db.spec.ts', 'web/src/orders/order.server.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scoped tests: 0', result.stdout)
        self.assertFalse((self.repo / 'web/selected.json').exists())

    def test_db_integration_specs_next_to_a_changed_source_are_not_selected(self):
        self.write('web/src/orders/order.server.ts', 'export const order = 1;')
        self.write('web/src/orders/order.server.db.spec.ts', '')
        self.write('web/src/orders/__tests__/order.db.spec.ts', '')
        result = self.run_helper('web/src/orders/order.server.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scoped tests: 0', result.stdout)

    def test_bun_tests_under_an_e2e_directory_still_run(self):
        self.write('web/src/app/api/e2e/route/__tests__/route.test.ts', '')
        result = self.run_helper('web/src/app/api/e2e/route/__tests__/route.test.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = json.loads((self.repo / 'web/selected.json').read_text())
        self.assertEqual(selected, ['./src/app/api/e2e/route/__tests__/route.test.ts'])

    def components(self, phase, *files):
        tools = self.repo / 'tools'
        tools.mkdir(exist_ok=True)
        for tool in ['bun', 'bunx', 'python3']:
            target = tools / tool
            target.write_text('#!' + sys.executable + '\nimport json,os,pathlib,subprocess,sys\nwith open(os.environ["CALLS"], "a") as f: f.write(json.dumps([pathlib.Path(sys.argv[0]).name, os.getcwd(), sys.argv[1:]])+"\\n")\nif pathlib.Path(sys.argv[0]).name == "python3" and "py_compile" in sys.argv: sys.exit(subprocess.run([' + repr(sys.executable) + ']+sys.argv[1:]).returncode)\n')
            target.chmod(0o755)
        return subprocess.run([sys.executable, str(HELPER), '--root', 'web', '--runner', 'bun test --isolate', '--components', phase, *files], cwd=self.repo, env=dict(os.environ, PATH=str(tools)+os.pathsep+os.environ['PATH'], CALLS=str(self.repo/'calls')), text=True, capture_output=True)

    def test_unknown_components_are_reported_and_do_not_block(self):
        result = self.components('lint', 'jellyfin/Thing.cs', 'roku/main.brs', 'streaminator/a.cpp')
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in ['jellyfin/Thing.cs', 'roku/main.brs', 'streaminator/a.cpp']:
            self.assertIn('UNCHECKED: '+path, result.stdout)

    def test_python_syntax_errors_fail_lint(self):
        self.write('projb_op/bin/task.py', 'def broken(:')
        result = self.components('lint', 'projb_op/bin/task.py')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SyntaxError', result.stderr)

    def test_python_sibling_tests_are_run(self):
        self.write('projb_op/bin/task.py', 'x = 1')
        self.write('projb_op/bin/tests/test_task.py', 'def test_ok(): assert True')
        result = self.components('tests', 'projb_op/bin/task.py')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('pytest', (self.repo/'calls').read_text())
        self.assertIn('projb_op/bin/tests', (self.repo/'calls').read_text())

    def test_workflow_yaml_is_parsed(self):
        self.write('.github/workflows/build.yml', 'name: Build')
        result = self.components('lint', '.github/workflows/build.yml')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('YAML.parse', (self.repo/'calls').read_text())
        self.assertNotIn('UNCHECKED', result.stdout)

    def test_marketing_lint_and_typecheck_run_from_marketing(self):
        self.write('marketing/src/page.tsx', 'export default 1;')
        self.write('marketing/package.json', '{}')
        for phase in ['lint', 'typecheck']:
            result = self.components(phase, 'marketing/src/page.tsx')
            self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.repo/'calls').read_text().splitlines()]
        self.assertTrue(any('biome' in ' '.join(call[2]) and call[1].endswith('/marketing') for call in calls))
        self.assertTrue(any('tsc' in call[2] and call[1].endswith('/marketing') for call in calls))

    def test_bin_sources_run_sibling_bun_tests(self):
        self.write('bin/job.ts', 'export const job=1;')
        self.write('bin/job.test.ts', '')
        result = self.components('tests', 'bin/job.ts')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('./job.test.ts', (self.repo/'calls').read_text())


class EnsureDependenciesTests(unittest.TestCase):
    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('run_scoped_tests', HELPER)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        (self.root / 'package.json').write_text('{}')
        (self.root / 'prisma').mkdir()
        (self.root / 'prisma/schema.prisma').write_text('')
        (self.root / 'a.test.ts').write_text('')
        self.calls = []

    def fake_run(self, codes=()):
        codes = list(codes)
        def run(command, **kwargs):
            self.calls.append((command, kwargs.get('env', {}).get('DATABASE_URL')))
            return subprocess.CompletedProcess(command, codes.pop(0) if codes else 0)
        return run

    def run_scoped(self, codes=()):
        from unittest import mock
        with mock.patch.object(self.mod.subprocess, 'run', self.fake_run(codes)):
            return self.mod.run_scoped_tests(self.root, 'bun test', [str(self.root / 'a.test.ts')])

    def test_installs_and_generates_when_node_modules_missing(self):
        self.assertEqual(self.run_scoped(), 0)
        commands = [call[0] for call in self.calls]
        self.assertEqual(commands[0], ['bun', 'install', '--frozen-lockfile', '--ignore-scripts'])
        self.assertEqual(commands[1], ['bunx', '--no-install', 'prisma', 'generate'])
        self.assertEqual(self.calls[1][1], self.mod.PLACEHOLDER_DATABASE)
        self.assertEqual(self.mod.PLACEHOLDER_DATABASE, 'postgresql://test:test@localhost:5432/test')
        self.assertEqual(commands[2][:2], ['bun', 'test'])

    def test_generate_falls_back_to_bunx_without_no_install(self):
        self.assertEqual(self.run_scoped([0, 1, 0]), 0)
        self.assertEqual(self.calls[2][0], ['bunx', 'prisma', 'generate'])

    def test_skipped_when_node_modules_present(self):
        (self.root / 'node_modules').mkdir()
        self.assertEqual(self.run_scoped(), 0)
        self.assertEqual([call[0][0] for call in self.calls], ['bun'])
        self.assertEqual(self.calls[0][0][:2], ['bun', 'test'])

    def test_skipped_when_no_tests_selected(self):
        from unittest import mock
        with mock.patch.object(self.mod.subprocess, 'run', self.fake_run()):
            self.assertEqual(self.mod.run_scoped_tests(self.root, 'bun test', []), 0)
        self.assertEqual(self.calls, [])

    def test_install_failure_propagates_and_skips_tests(self):
        self.assertEqual(self.run_scoped([3]), 3)
        self.assertEqual(len(self.calls), 1)

    def test_generate_failure_propagates(self):
        self.assertEqual(self.run_scoped([0, 1, 5]), 5)
        self.assertEqual(len(self.calls), 3)


if __name__ == '__main__':
    unittest.main()
