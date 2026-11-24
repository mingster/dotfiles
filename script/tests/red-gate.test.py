"""#1746: red-gate.py dedupe and the infra line contract. No live gh."""
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('red_gate', Path(__file__).parent.parent / 'red-gate.py')
rg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rg)


class FakeGh:
    """Stand-in for subprocess.run: a tiny issue tracker that logs each write."""

    def __init__(self, open_issues=None, fail_on=None):
        self.open = dict(open_issues or {})  # number -> title
        self.calls = []
        self.fail_on = fail_on

    def __call__(self, command, **_kw):
        args = command[1:]
        self.calls.append(args)
        if self.fail_on and args[:2] == self.fail_on:
            raise subprocess.CalledProcessError(1, command)
        if args[:2] == ['issue', 'list']:
            rows = [{'number': n, 'title': t} for n, t in self.open.items()]
            return subprocess.CompletedProcess(command, 0, json.dumps(rows), '')
        if args[:2] == ['issue', 'create']:
            number = 100 + len(self.open)
            self.open[number] = args[args.index('--title') + 1]
            return subprocess.CompletedProcess(command, 0, 'https://github.com/o/r/issues/%d\n' % number, '')
        return subprocess.CompletedProcess(command, 0, '', '')

    def writes(self, verb):
        return [c for c in self.calls if c[:2] == ['issue', verb]]


class Dedupe(unittest.TestCase):
    def test_first_failure_creates_one_p1_ready_for_agent_issue_with_the_output(self):
        gh = FakeGh()
        number = rg.file_gate('head-checks', 'boom: host gone', 'o/r', gh)
        self.assertEqual(number, 100)
        (create,) = gh.writes('create')
        self.assertEqual(create[create.index('--title') + 1], 'red gate: head-checks')
        labels = [create[i + 1] for i, a in enumerate(create) if a == '--label']
        self.assertEqual(labels, ['P1', 'ready-for-agent'])
        self.assertIn('boom: host gone', create[create.index('--body') + 1])

    def test_second_failure_comments_on_the_open_issue_and_creates_nothing(self):
        gh = FakeGh({7: 'red gate: head-checks'})
        self.assertEqual(rg.file_gate('head-checks', 'again', 'o/r', gh), 7)
        self.assertEqual(gh.writes('create'), [])
        (comment,) = gh.writes('comment')
        self.assertEqual(comment[2], '7')
        self.assertIn('again', comment[comment.index('--body') + 1])

    def test_another_tool_gets_its_own_issue(self):
        gh = FakeGh({7: 'red gate: head-checks'})
        self.assertEqual(rg.file_gate('remote-heavy', 'x', 'o/r', gh), 101)
        self.assertEqual(len(gh.writes('create')), 1)

    def test_a_main_red_issue_is_not_a_red_gate(self):
        gh = FakeGh({9: 'main red: 12345'})
        self.assertEqual(rg.open_gates('o/r', gh), {})

    def test_gh_failure_files_nothing_and_returns_none(self):
        self.assertIsNone(rg.file_gate('head-checks', 'x', 'o/r', FakeGh(fail_on=['issue', 'list'])))
        self.assertIsNone(rg.file_gate('head-checks', 'x', 'o/r', FakeGh(fail_on=['issue', 'create'])))

    def test_failed_comment_still_returns_the_open_issue_number(self):
        gh = FakeGh({7: 'red gate: head-checks'}, fail_on=['issue', 'comment'])
        self.assertEqual(rg.file_gate('head-checks', 'again', 'o/r', gh), 7)

    def test_database_urls_are_redacted_from_the_issue(self):
        gh = FakeGh()
        rg.file_gate('head-checks', 'connect postgres://u:p@host/db failed', 'o/r', gh)
        body = gh.writes('create')[0]
        self.assertNotIn('u:p@host', body[body.index('--body') + 1])


class InfraLine(unittest.TestCase):
    def test_named_tool(self):
        self.assertEqual(rg.infra_tool('x\ninfra: run-scoped-tests: usage error\n'), 'run-scoped-tests')

    def test_bare_preflight_line_names_the_test_database(self):
        self.assertEqual(rg.infra_tool('infra: cannot reach the test database\n'), 'test-database')

    def test_test_failure_has_no_infra_line(self):
        self.assertIsNone(rg.infra_tool('not ok 1\nAssertionError: infra: is a word here\n'))


if __name__ == '__main__':
    unittest.main()
