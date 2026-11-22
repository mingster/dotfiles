"""#1237: Self-check accepts bunx, npx, uv, node and a 'Command (from dir):' heading, and still refuses prose."""
import importlib.util
import unittest
from pathlib import Path

base = Path(__file__).parent.parent
spec = importlib.util.spec_from_file_location('pr_body_gate', base / 'pr-body-gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def check(section):
    return gate.self_check_has_command_and_output('## Acceptance\n- [x] Done.\n\n## Self-check\n' + section)


class SelfCheckCommandTests(unittest.TestCase):
    def test_runner_commands_pass(self):
        for cmd in ('bunx playwright test e2e/a.spec.ts', 'npx vitest run', 'uv run pytest', 'node build.js'):
            self.assertTrue(check('```\n%s\n```\n3 passed\n' % cmd), cmd)

    def test_command_heading_with_parens_passes(self):
        self.assertTrue(check('Command (from web/, with the dev server up):\n```\nmake it\n```\n3 passed\n'))

    def test_plain_command_heading_still_passes(self):
        self.assertTrue(check('Command: make it\n3 passed\n'))

    def test_output_line_naming_a_sh_file_is_not_a_command(self):
        # #1480: \bsh\b matched inside 'test.sh', so this output line counted as a command.
        self.assertTrue(check('$ bash script/a.test.sh\nok script/b.test.sh\n'))

    def test_prose_only_fails(self):
        self.assertFalse(check('I looked at the page and it works.\nEverything is fine.\n'))

    def test_command_word_in_prose_without_colon_fails(self):
        self.assertFalse(check('Commands were fine.\nAll good.\n'))


if __name__ == '__main__':
    unittest.main()
