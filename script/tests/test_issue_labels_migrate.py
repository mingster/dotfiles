"""#1216: the label migration script. Dry run changes nothing; --apply runs the planned edits."""
import importlib.util
import io
import json
import unittest
from contextlib import redirect_stdout
from pathlib import Path

spec = importlib.util.spec_from_file_location('mig', Path(__file__).parent.parent / 'issue-labels-migrate.py')
mig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mig)

ISSUES = [
    {'number': 1, 'labels': [{'name': 'ready-for-agent'}, {'name': 'P2'}, {'name': 'enhancement'}]},
    {'number': 2, 'labels': [{'name': 'bug'}, {'name': 'P2'}, {'name': 'ready-for-agent'}]},
    {'number': 3, 'labels': [{'name': 'P1'}, {'name': 'P2'}, {'name': 'after-go-live'}, {'name': 'phase-2'}]},
    {'number': 4, 'labels': []},
    {'number': 5, 'labels': [{'name': 'needs-triage'}, {'name': 'P3'}]},
    {'number': 6, 'labels': [{'name': 'ready-for-agent'}, {'name': 'ready-for-human'}]},
]


class Plan(unittest.TestCase):
    def test_rows(self):
        rows = {n: (a, r) for n, a, r in mig.plan(ISSUES)}
        self.assertEqual(rows[1], ([], ['enhancement']))
        self.assertEqual(rows[2], (['P0'], ['P2', 'bug']))
        self.assertEqual(rows[3], (['deferred'], ['P2', 'after-go-live', 'phase-2']))
        self.assertEqual(rows[4], (['needs-triage'], []))
        self.assertNotIn(5, rows)
        self.assertEqual(rows[6], (['owner'], ['ready-for-agent', 'ready-for-human']))

    def test_bug_replaces_every_other_p_label(self):
        self.assertEqual(mig.new_labels_for({'bug', 'P1', 'P3'}) & set(mig.PRIORITY), {'P0'})


class Fake:
    def __init__(self):
        self.calls = []

    def __call__(self, command, **_kw):
        self.calls.append(command[1:])

        class Proc:
            returncode = 0
            stderr = ''
            stdout = ''
        proc = Proc()
        if command[1:3] == ['label', 'list']:
            proc.stdout = json.dumps([{'name': 'P0'}, {'name': 'bug'}])
        elif command[1:3] == ['issue', 'list']:
            proc.stdout = json.dumps(ISSUES)
        return proc


def run_main(argv):
    fake, out = Fake(), io.StringIO()
    with redirect_stdout(out):
        code = mig.main(argv, run=fake)
    return code, out.getvalue(), fake.calls


class Main(unittest.TestCase):
    def test_dry_run_only_reads_and_prints_counts(self):
        code, out, calls = run_main(['o/r'])
        self.assertEqual(code, 0)
        self.assertTrue(all(c[1] == 'list' for c in calls))
        self.assertIn('dry run: 6 open issues, 19 labels to create, 5 issues to relabel', out)
        self.assertNotIn('#', out)

    def test_apply_creates_labels_and_edits_issues(self):
        code, out, calls = run_main(['o/r', '--apply'])
        self.assertEqual(code, 0)
        self.assertEqual(sum(1 for c in calls if c[:2] == ['label', 'create']), 19)
        self.assertEqual(sum(1 for c in calls if c[:2] == ['issue', 'edit']), 5)
        self.assertFalse(any(c[:2] == ['label', 'delete'] for c in calls))
        self.assertIn('done: 19 created, 5 relabeled, 0 deleted', out)

    def test_delete_old_removes_retired_labels_that_exist(self):
        _c, out, calls = run_main(['o/r', '--apply', '--delete-old'])
        self.assertEqual([c[2] for c in calls if c[:2] == ['label', 'delete']], ['bug'])

    def test_delete_old_needs_apply(self):
        with self.assertRaises(SystemExit):
            run_main(['o/r', '--delete-old'])


if __name__ == '__main__':
    unittest.main()
