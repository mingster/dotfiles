#!/usr/bin/env python3
"""Exercise the selector through its CLI and real fixture files."""
import json
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

    def test_pstv_root_changed_test_and_quoted_path(self):
        self.write('web2/pstv_web/src/path with space.test.ts', '')
        result = self.run_helper('web2/pstv_web/src/path with space.test.ts', root='web2/pstv_web')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.repo / 'web2/pstv_web/selected.json').read_text()), ['./src/path with space.test.ts'])

    def test_no_tests_does_not_start_runner(self):
        result = self.run_helper('README.md')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scoped tests: 0', result.stdout)
        self.assertFalse((self.repo / 'web/selected.json').exists())


if __name__ == '__main__':
    unittest.main()
