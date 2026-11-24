"""#1730: the tier classifier labels a PR 0, 1 or 2 from its files and line counts."""
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / 'pr-tier.py'
spec = importlib.util.spec_from_file_location('pr_tier', SCRIPT)
pt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pt)


def f(path, add=5, dele=0, **extra):
    return {'path': path, 'additions': add, 'deletions': dele, **extra}


def tier(*files):
    return pt.classify(list(files))[0]


class Tier0(unittest.TestCase):
    def test_tests_and_docs_only_is_tier_0(self):
        self.assertEqual(tier(f('script/tests/test_x.py'), f('docs/agents/fleet-watch.md'), f('changelog.d/1-x.md')), 0)
        self.assertEqual(tier(f('script/foo.test.sh'), f('web/a.spec.ts')), 0)

    def test_150_lines_is_the_cap(self):
        self.assertEqual(tier(f('script/tests/test_x.py', 100, 50)), 0)
        self.assertEqual(tier(f('script/tests/test_x.py', 100, 51)), 2)

    def test_helpers_fixtures_mocks_config_json_are_not_tier_0(self):
        for path in ('script/tests/lib/asdf-pin.sh', 'tests/fixtures/a.test.ts', 'tests/mocks/b.test.ts',
                     'tests/conftest.py', 'tests/data.json', 'tests/helpers/x.test.py', 'docs/shapes.json',
                     'config/app.yml', 'script/fleet-watch.config.example.json'):
            self.assertNotEqual(tier(f(path)), 0, path)

    def test_protected_paths_are_tier_2_even_as_docs_or_tests(self):
        for path in ('.claude/hooks/guard.py', 'ide/cursor/hooks/a.sh', '.claude/settings.json', 'prisma/schema.prisma',
                     'app/payment/test_pay.py', 'src/auth/login.test.ts', 'secret-store/x.md', '.env.example',
                     'script/ship.sh', 'script/post-verdict.sh', 'docs/agents/team.md',
                     'templates/agent-team/.claude/agents/a.md', 'AGENTS.md', 'docs/intent/x.md', 'a.rules',
                     '.github/workflows/checks.yml'):
            self.assertEqual(tier(f(path, 1)), 2, path)

    def test_a_rename_out_of_a_protected_path_is_tier_2(self):
        self.assertEqual(tier(f('docs/x.md', 1, 1, previous_filename='script/ship.sh')), 2)
        self.assertEqual(tier(f('script/tests/test_x.py', 1, 1, previous_filename='.claude/hooks/guard.py')), 2)

    def test_a_rename_between_docs_or_tests_is_tier_0(self):
        self.assertEqual(tier(f('docs/x.md', 1, 1, previous_filename='docs/y.md')), 0)
        self.assertEqual(tier(f('script/tests/test_new.py', 5, 0, previous_filename='script/tests/test_old.py')), 0)
        self.assertEqual(tier(f('script/tests/test_new.py', 100, 50, previous_filename='script/tests/test_old.py')), 0)
        self.assertEqual(tier(f('script/tests/test_new.py', 100, 51, previous_filename='script/tests/test_old.py')), 2)

    def test_fails_closed(self):
        self.assertEqual(tier(), 2)
        self.assertEqual(pt.classify(None)[0], 2)
        self.assertEqual(pt.classify(['docs/a.md'])[0], 2)
        self.assertEqual(tier({'path': 'docs/a.md'}), 2)
        self.assertEqual(tier(f('docs/a.md', True, 0)), 2)
        self.assertEqual(tier(*[f('docs/d%d.md' % i, 1) for i in range(100)]), 2)


class Tier1(unittest.TestCase):
    def test_small_code_is_tier_1(self):
        self.assertEqual(tier(f('script/fleet-watch.py', 30, 20)), 1)
        self.assertEqual(tier(f('script/fleet-watch.py', 30, 21)), 2)

    def test_docs_do_not_count_against_the_50_lines(self):
        self.assertEqual(tier(f('script/fleet-watch.py', 50), f('changelog.d/1-x.md', 3), f('docs/a.md', 90)), 1)

    def test_ui_file_is_never_tier_1(self):
        for path in ('web/Button.tsx', 'web/app.css', 'resources/views/a.blade.php', 'src/components/x.ts', 'a.vue'):
            self.assertEqual(tier(f(path, 2)), 2, path)

    def test_oversize_tier_0_candidate_with_a_helper_is_tier_1_when_small(self):
        self.assertEqual(tier(f('script/tests/lib/x.sh', 10), f('script/tests/test_a.py', 10)), 1)

    def test_a_rename_from_code_or_a_helper_into_a_test_or_doc_is_not_tier_0(self):
        self.assertEqual(tier(f('script/tests/test_x.py', 5, 0, previous_filename='script/x.py')), 1)
        self.assertEqual(tier(f('docs/x.md', 5, 0, previous_filename='script/tests/lib/helper.sh')), 1)
        self.assertEqual(tier(f('script/tests/test_x.py', 30, 21, previous_filename='script/x.py')), 2)


class Protected(unittest.TestCase):
    """Every path protected-paths.sh calls protected is tier 2 here."""

    def test_agrees_with_protected_path_shell_function(self):
        lib = Path(__file__).parent.parent / 'lib' / 'protected-paths.sh'
        paths = ['.claude/hooks/a.py', 'x/.claude/hooks/a.py', '.claude/settings.json', 'bin/owner-approve.sh', 'a.rules',
                 'docs/intent/a.md', 'docs/agents/team.md', 'docs/agents/elon-dispatch.md', '.claude/agents/qa.md',
                 'AGENTS.md', 'sub/AGENTS.md', 'model-routing.md', 'docs/ok.md', 'script/x.sh']
        hits = 0
        for path in paths:
            shell = subprocess.run(['bash', '-c', '. "$1"; protected_path "$2"', 'x', str(lib), path]).returncode == 0
            if shell:
                hits += 1
                self.assertEqual(tier(f(path, 1)), 2, path)
        self.assertGreater(hits, 8)


class Cli(unittest.TestCase):
    def run_cli(self, payload, raw=None):
        text = raw if raw is not None else json.dumps(payload)
        return subprocess.run([sys.executable, str(SCRIPT)], input=text, capture_output=True, text=True).stdout.strip()

    def test_reads_gh_api_shape_and_pages(self):
        api = [{'filename': 'docs/a.md', 'additions': 3, 'deletions': 1, 'status': 'modified'}]
        self.assertEqual(self.run_cli(api), '0')
        self.assertEqual(self.run_cli([api, api]), '0')
        self.assertEqual(self.run_cli([]), '2')

    def test_garbage_is_tier_2(self):
        self.assertEqual(self.run_cli(None, raw='not json'), '2')


if __name__ == '__main__':
    unittest.main()
