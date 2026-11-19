"""#1201: the PR body gate needs a valid Builder line, and fleet-watch reads the slash and agy forms."""
import importlib.util
import unittest
from pathlib import Path

base = Path(__file__).parent.parent
gate_spec = importlib.util.spec_from_file_location('pr_body_gate', base / 'pr-body-gate.py')
gate = importlib.util.module_from_spec(gate_spec)
gate_spec.loader.exec_module(gate)
fw_spec = importlib.util.spec_from_file_location('fleet_watch', base / 'fleet-watch.py')
fw = importlib.util.module_from_spec(fw_spec)
fw_spec.loader.exec_module(fw)

BODY = """## Acceptance
- [x] Done.

## Self-check
- `bash script/tests/x.test.sh`
ok 3 passed
%s
"""


def body(builder):
    return BODY % builder


class BuilderGateTests(unittest.TestCase):
    def test_valid_lines_pass(self):
        for line in ('Builder: agent=claude model=sonnet', 'Builder: agent=antigravity model=gemini-3-pro',
                     'Builder: agent=agy model=gemini-3-pro', 'Builder: agent=grok model=grok-4.7-high',
                     'Builder: agent=cursor model=composer-2'):
            self.assertIsNone(gate.finish_block_reason(body(line)), line)

    def test_missing_line_blocks(self):
        reason = gate.finish_block_reason(body(''))
        self.assertIn('Builder: agent=<provider> model=<model>', reason)

    def test_role_host_and_slash_forms_block(self):
        for line in ('Builder: claude/sonnet (some-host)', 'Builder: agent=fullstack-dev',
                     'Builder: agent=fullstack-dev model=sonnet', 'Builder: agent=claude model=unknownthing',
                     'Builder: agent=claude'):
            self.assertIn('Builder:', gate.finish_block_reason(body(line)) or '', line)

    def test_earlier_checks_keep_their_reason(self):
        self.assertEqual(gate.finish_block_reason(body('Builder: agent=claude model=sonnet').replace('[x]', '[ ]')),
                         'unchecked Acceptance items')


class BuilderPairTests(unittest.TestCase):
    def pair(self, line):
        return fw.builder_pair({'number': 1, 'headRefName': 'b', 'body': 'text\n' + line + '\nmore'}, [])

    def test_exact_line(self):
        self.assertEqual(self.pair('Builder: agent=claude model=sonnet'), ('claude', 'sonnet'))

    def test_agy_maps_to_antigravity(self):
        self.assertEqual(self.pair('Builder: agent=agy model=gemini-3-pro'), ('antigravity', 'gemini-3-pro'))

    def test_slash_form_with_a_host_note(self):
        self.assertEqual(self.pair('Builder: claude/sonnet (some-host)'), ('claude', 'sonnet'))

    def test_slash_form_agy(self):
        self.assertEqual(self.pair('Builder: agy/gemini-3-pro'), ('antigravity', 'gemini-3-pro'))


if __name__ == '__main__':
    unittest.main()
