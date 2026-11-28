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
_env_spec = importlib.util.spec_from_file_location('fleet_watch_test_env', base / 'tests' / 'fleet_watch_test_env.py')
_env = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(_env)

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

    def test_fable_passes_and_unknown_family_fails(self):
        self.assertIsNone(gate.finish_block_reason(body('Builder: agent=claude model=fable')))
        self.assertIn('Builder:', gate.finish_block_reason(body('Builder: agent=claude model=unknownfamily')) or '')

    def test_template_sync_script_builder_passes(self):
        self.assertIsNone(gate.finish_block_reason(body('Builder: agent=script model=template-sync-pr.sh')))

    def test_other_script_builders_block(self):
        for line in ('Builder: agent=script model=other.sh', 'Builder: agent=script model=sonnet'):
            self.assertIn('Builder:', gate.finish_block_reason(body(line)) or '', line)

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


GOOD = body('Builder: agent=claude model=sonnet')
SHARED_DIFF = """diff --git a/script/fleet-watch.py b/script/fleet-watch.py
--- a/script/fleet-watch.py
+++ b/script/fleet-watch.py
@@ -10,7 +10,8 @@ def classify_worker(row):
     state = row.get('state')
-    if state in ('dispatched', 'running'):
+    if row.get('released'):
+        return 'released'
diff --git a/web/src/lib/loader.ts b/web/src/lib/loader.ts
--- a/web/src/lib/loader.ts
+++ b/web/src/lib/loader.ts
@@ -3,3 +3,3 @@ export interface Store {
-  plan: string;
+  plan?: string;
"""
NEW_ONLY_DIFF = """diff --git a/script/x.py b/script/x.py
--- a/script/x.py
+++ b/script/x.py
@@ -1,2 +1,5 @@
 import os
+def brand_new(x):
+    return x
diff --git a/script/tests/test_x.py b/script/tests/test_x.py
--- a/script/tests/test_x.py
+++ b/script/tests/test_x.py
@@ -1,2 +1,3 @@ def test_old(self):
-    self.assertTrue(True)
+    self.assertTrue(1)
"""
READERS = """
## Readers
- classify_worker: fleet-watch issue scan, covered by script/tests/test_fleet_watch_1841.py
- classify_worker: status digest, no test because it only prints the label (reason: display only)
- plan: billing loader, covered by web/src/lib/loader.test.ts
"""


class ReadersGateTests(unittest.TestCase):
    """#1840 item 8(a): a changed shared function or field lists its readers."""

    def test_changed_definitions_from_hunk_headers_and_removed_lines(self):
        self.assertEqual(gate.changed_definitions(SHARED_DIFF), ['classify_worker', 'plan'])

    def test_new_definitions_and_test_files_are_not_changes(self):
        self.assertEqual(gate.changed_definitions(NEW_ONLY_DIFF), [])
        self.assertIsNone(gate.finish_block_reason(GOOD, diff=NEW_ONLY_DIFF))

    def test_body_without_readers_fails(self):
        reason = gate.finish_block_reason(GOOD, diff=SHARED_DIFF)
        self.assertIn('Readers:', reason or '')
        self.assertIn('classify_worker, plan', reason)

    def test_readers_with_a_test_or_reason_each_pass(self):
        self.assertIsNone(gate.finish_block_reason(GOOD + READERS, diff=SHARED_DIFF))

    def test_inline_readers_label_passes(self):
        inline = GOOD + '\nReaders:\n- classify_worker: reason: only caller is issue scan, tested in test_fleet_watch.py\n- plan: test web/src/lib/loader.test.ts\n'
        self.assertIsNone(gate.finish_block_reason(inline, diff=SHARED_DIFF))

    def test_one_line_readers_passes(self):
        one = GOOD + '\nReaders: classify_worker and plan have no other callers (reason: grep finds none)\n'
        self.assertIsNone(gate.finish_block_reason(one, diff=SHARED_DIFF))

    def test_reader_with_no_test_or_reason_fails(self):
        bare = GOOD + READERS.replace('covered by web/src/lib/loader.test.ts', 'billing page')
        self.assertIn('Readers:', gate.finish_block_reason(bare, diff=SHARED_DIFF) or '')

    def test_readers_missing_a_changed_name_fails(self):
        partial = GOOD + '\n## Readers\n- classify_worker: tested in test_fleet_watch.py\n'
        self.assertIn('Readers:', gate.finish_block_reason(partial, diff=SHARED_DIFF) or '')

    def test_no_diff_keeps_the_old_behavior(self):
        self.assertIsNone(gate.finish_block_reason(GOOD))


class DecisionsGateTests(unittest.TestCase):
    """#1840 Part 3 item 3: a worker that sent no ask lists its choices under Decisions:."""

    def test_no_ask_and_no_decisions_fails(self):
        self.assertIn('Decisions:', gate.finish_block_reason(GOOD, asked=False) or '')

    def test_decisions_none_passes(self):
        self.assertIsNone(gate.finish_block_reason(GOOD + '\nDecisions: none\n', asked=False))

    def test_decisions_heading_passes(self):
        self.assertIsNone(gate.finish_block_reason(GOOD + '\n## Decisions\n- Picked option A (recommended).\n', asked=False))

    def test_empty_decisions_label_fails(self):
        self.assertIn('Decisions:', gate.finish_block_reason(GOOD + '\nDecisions:\n', asked=False) or '')

    def test_a_worker_that_asked_needs_none(self):
        self.assertIsNone(gate.finish_block_reason(GOOD, asked=True))
        self.assertIsNone(gate.finish_block_reason(GOOD))


class PerfGateTests(unittest.TestCase):
    """#2065: a diff on a path the checkout marks perf relevant needs a Perf: line."""

    WEB = 'diff --git a/web/src/page.tsx b/web/src/page.tsx\n+x\n'
    DOCS = 'diff --git a/docs/a.md b/docs/a.md\n+x\ndiff --git a/changelog.d/1-x.md b/changelog.d/1-x.md\n+x\n'
    NEED = ('PR body needs a Perf: line (Perf: <checked items> or Perf: n/a: no data reads changed) '
            'because the diff touches web/src/page.tsx')

    def setUp(self):
        import os
        import subprocess
        import tempfile
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.addCleanup(os.chdir, os.getcwd())
        root = Path(tmp.name)
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        (root / '.agents').mkdir()
        self.conf = root / '.agents' / 'head-checks.conf'
        self.conf.write_text('# perf-paths: web/src/\ntrue\n')
        (root / 'sub').mkdir()
        os.chdir(root / 'sub')

    def test_body_without_perf_is_refused(self):
        self.assertEqual(gate.finish_block_reason(GOOD, diff=self.WEB), self.NEED)

    def test_perf_line_passes(self):
        for line in ('Perf: n/a: no data reads changed', 'Perf: checked N+1 and caching'):
            self.assertIsNone(gate.finish_block_reason(GOOD + '\n' + line + '\n', diff=self.WEB), line)

    def test_empty_perf_line_is_refused(self):
        self.assertEqual(gate.finish_block_reason(GOOD + '\nPerf:\n\nmore\n', diff=self.WEB), self.NEED)

    def test_renamed_from_path_counts(self):
        moved = 'diff --git a/web/src/page.tsx b/lib/page.tsx\n'
        self.assertEqual(gate.finish_block_reason(GOOD, diff=moved), self.NEED)

    def test_docs_and_changelog_only_needs_none(self):
        self.assertIsNone(gate.finish_block_reason(GOOD, diff=self.DOCS))

    def test_no_config_line_or_file_needs_none(self):
        self.conf.write_text('true\n')
        self.assertIsNone(gate.finish_block_reason(GOOD, diff=self.WEB))
        self.conf.unlink()
        self.assertIsNone(gate.finish_block_reason(GOOD, diff=self.WEB))


class PerfTargetTests(unittest.TestCase):
    """#2070: a caller outside the target checkout names it."""

    def setUp(self):
        import os
        import subprocess
        import tempfile
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.addCleanup(os.chdir, os.getcwd())
        self.root = Path(tmp.name) / 'target'
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / '.agents').mkdir()
        self.conf = self.root / '.agents' / 'head-checks.conf'
        self.conf.write_text('# perf-paths: web/src/\n')
        os.chdir(tmp.name)

    def test_repo_dir_or_conf_path_enforces_perf(self):
        for target in ({'repo_dir': str(self.root)}, {'conf_path': str(self.conf)}):
            self.assertEqual(gate.finish_block_reason(GOOD, diff=PerfGateTests.WEB, **target), PerfGateTests.NEED)
        self.assertIsNone(gate.finish_block_reason(GOOD, diff=PerfGateTests.WEB))

    def test_empty_repo_dir_never_reads_the_cwd(self):
        import os
        os.chdir(self.root)
        self.assertIsNone(gate.finish_block_reason(GOOD, diff=PerfGateTests.WEB, repo_dir=''))

    def test_fleet_watch_bounce_reads_the_target_checkout(self):
        from unittest.mock import patch
        worker = {'dispatchId': 'd1'}
        message = {'id': 'm1', 'type': 'worker_done', 'payload': {'dispatchId': 'd1'}}
        config = {'issue_scan': {'repo_roots': {'o/r': str(self.root)}}}
        with patch.object(fw, 'worker_pr_number', return_value=7), \
                patch.object(fw, 'repo_for_worker', return_value='o/r'), \
                patch.object(fw, 'mail_worker'):
            lines = fw.bounce_builder_dones(
                [message], [worker], lambda repo, number: GOOD + '\nDecisions: none\n', None, {}, config,
                diff_of=lambda repo, number: PerfGateTests.WEB)
        self.assertEqual(lines, ['bounce o/r#7 ' + PerfGateTests.NEED])


class CliTests(unittest.TestCase):
    def run_cli(self, args, text):
        import io
        from contextlib import redirect_stdout
        old = gate.sys.stdin
        gate.sys.stdin = io.StringIO(text)
        out = io.StringIO()
        try:
            with redirect_stdout(out):
                rc = gate.main(args)
        finally:
            gate.sys.stdin = old
        return rc, out.getvalue()

    def test_cli_diff_and_asked(self):
        import tempfile
        with tempfile.NamedTemporaryFile('w', suffix='.diff', delete=False) as handle:
            handle.write(SHARED_DIFF)
        rc, out = self.run_cli(['--diff', handle.name, '--asked', 'no'], GOOD)
        self.assertEqual((rc, 'Readers:' in out), (1, True))
        rc, out = self.run_cli(['--diff', handle.name, '--asked', 'no'], GOOD + READERS + '\nDecisions: none\n')
        self.assertEqual((rc, out), (0, ''))
        Path(handle.name).unlink()

    def test_cli_rejects_unknown_options(self):
        self.assertEqual(self.run_cli(['--asked', 'maybe'], GOOD)[0], 2)
        self.assertEqual(self.run_cli(['--bogus', 'x'], GOOD)[0], 2)
        self.assertEqual(self.run_cli([], GOOD)[0], 0)


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
