"""#1820: one start budget check, start_allowed(cost), owned by each start site; the start wrapper has none.

#1841: verifier starts (one shot and standing) have no budget hold; they start on Review PASS within the usage gate."""
import ast
import copy
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parent.parent / 'fleet-watch.py'
spec = importlib.util.spec_from_file_location('fleet_watch_budget', SCRIPT)
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_1216 import row  # noqa: E402
from test_fleet_watch_1730 import BIG_CODE, PICK, TEST_FILES, pr as tier_pr, scan_config as tier_config  # noqa: E402
from test_fleet_watch_scan import pr as plain_pr  # noqa: E402
from test_fleet_watch_standing import HOST, FakeIO, pr as standing_pr  # noqa: E402
from test_fleet_watch_triage import NOW as TRIAGE_NOW, pick as triage_pick  # noqa: E402
from test_fleet_watch_park import REPO as PARK_REPO, scan_config as park_config  # noqa: E402

AGY = 'antigravity'


def spent():
    return patch.object(fw, 'start_allowed', return_value=False)


def norm(value):
    """State without its empty containers: a pass creates empty maps with setdefault, which is not a state change."""
    if isinstance(value, dict):
        out = {k: norm(v) for k, v in value.items() if k != 'work_order_no_work_day'}  # a status notice marker, not a start
        return {k: v for k, v in out.items() if v not in ({}, [], None)}
    if isinstance(value, list):
        return [norm(v) for v in value]
    return value


def triage_run(issues, backlog, state, order=None, supply_recent=True, starts_out=None):
    """The triage tests' run(), against this module's copy of fleet-watch so start_allowed patches reach it."""
    config = park_config('/work/app')
    if order is not None:
        config['work_order'] = order
    def start(command):
        starts_out.append(command)
        return 0

    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        _n, bits = fw.issue_scan_pass(
            config, state, TRIAGE_NOW, [], pr_fetch=lambda _r: [], list_issues=lambda _r: list(issues),
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
            start_worker=start, act=lambda _c: 0, repo_id_lookup=lambda _h, _r: 'repo-id',
            pick_fn=triage_pick, list_backlog=lambda _r: backlog,
        )
    return None, bits, state


# Each scenario runs one start site with a start stub and returns (starts, log bits, state before, state after).
def issue_start(held):
    starts, state = [], {'issue_scan_backlog_sweep_at': TRIAGE_NOW, 'work_order_supply_at': TRIAGE_NOW}
    before = copy.deepcopy(state)
    with spent() if held else patch.object(fw, 'start_allowed', return_value=True):
        _t, bits, state = triage_run([row(1)], backlog=0, state=state, starts_out=starts)
    return starts, bits, before, state


def auto_ship(held):
    starts, state = [], {'issue_scan_backlog_sweep_at': 1_700_000_000.0}
    before = copy.deepcopy(state)
    with spent() if held else patch.object(fw, 'start_allowed', return_value=True):
        _n, bits = fw.issue_scan_pass(
            tier_config('/tmp/app'), state, 1_700_000_000.0, [], list_issues=lambda _r: [],
            pr_fetch=lambda _r: [tier_pr(1, TEST_FILES)],
            gate_check=lambda _c: True, admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_worker=lambda cmd: (starts.append(cmd), 0)[1],
        )
    return starts, bits, before, state


def backlog_sweep(held):
    starts, state = [], {'work_order_supply_at': TRIAGE_NOW}
    before = copy.deepcopy(state)
    with spent() if held else patch.object(fw, 'start_allowed', return_value=True):
        _t, bits, state = triage_run([], backlog=0, state=state, starts_out=starts)
    return starts, bits, before, state


def supply(held):
    starts, state = [], {'issue_scan_backlog_sweep_at': TRIAGE_NOW}
    before = copy.deepcopy(state)
    order = {'min_active': 3, 'target_workers': 10}
    with spent() if held else patch.object(fw, 'start_allowed', return_value=True):
        _t, bits, state = triage_run([], backlog=3, state=state, order=order, supply_recent=False, starts_out=starts)
    return starts, bits, before, state


def triage(held):
    starts, state = [], {'issue_scan_backlog_sweep_at': TRIAGE_NOW, 'work_order_supply_at': TRIAGE_NOW}
    before = copy.deepcopy(state)
    with spent() if held else patch.object(fw, 'start_allowed', return_value=True):
        _t, bits, state = triage_run([], backlog=3, state=state, starts_out=starts)
    return starts, bits, before, state


def rework(held):
    starts, state = [], {'issue_scan_backlog_sweep_at': 1}
    before = copy.deepcopy(state)
    head = 'a' * 40
    prs = [plain_pr(1, head=head, comments=[{'body': 'Checks: FAIL head=%s' % head}])]
    with spent() if held else patch.object(fw, 'start_allowed', return_value=True):
        _n, bits = fw.issue_scan_pass(
            park_config('/tmp/app'), state, 1_700_000_000.0, [], list_issues=lambda _r: [],
            pr_fetch=lambda _r: prs, gate_check=lambda _c: True,
            admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
            start_worker=lambda cmd: (starts.append(cmd), 0)[1], act=lambda _c: 0,
        )
    return starts, bits, before, state


def babysit(held, rows, standing=None, pick=PICK):
    starts, state = [], {}
    before = copy.deepcopy(state)
    with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {'STANDING_VERIFIER_TRIAL_LOG': os.path.join(root, 't.tsv')}):
        config = tier_config(root)
        if standing:
            config['babysit']['standing_verifier'] = standing
        io = FakeIO()
        with spent() if held else patch.object(fw, 'start_allowed', return_value=True):
            _n, lines, bits = fw.babysit_pass(
                config, state, [], pr_fetch=lambda _r: rows,
                start_worker=lambda cmd: (starts.append(cmd), fw.BabysitStartResult(0, '', 'ctx_x', 'term_x'))[1],
                pick=pick, owner_check=lambda _pr, **_kw: None, release_worker=lambda *_a, **_k: None,
                notify_worker=lambda *_a: None, now=10_000.0, term_times={}, standing_io=io,
            )
    return starts, bits, before, state, lines


def one_shot_verifier(held):
    starts, bits, before, state, _lines = babysit(held, [tier_pr(2, BIG_CODE)])
    return starts, bits, before, state


AGY_PICK = lambda _role, **_kw: {'selected': {'provider': AGY, 'model': 'm', 'eligible': True, 'headroom': 50}}  # noqa: E731


def standing_verifier(held):
    starts, bits, before, state, _lines = babysit(
        held, [standing_pr(7)], standing={'enabled': True, 'hosts': [HOST]}, pick=AGY_PICK)
    return starts, bits, before, state


# Verifier starts that never wait on the start budget (owner 2026-11-25, #1838): scenario per site.
VERIFIER_SITES = {
    'standing verifier': standing_verifier,
    'one shot verifier': one_shot_verifier,
}

# site -> (scenario, log line the held start leaves)
BUDGET_TABLE = {
    'issue start': (issue_start, 'issue_start_budget=1'),
    'auto ship': (auto_ship, 'ship_budget=1'),
    'backlog sweep': (backlog_sweep, 'backlog_sweep_budget='),
    'supply': (supply, 'supply_budget='),
    'triage': (triage, 'triage_budget='),
    'rework': (rework, 'rework_budget=1'),
}

# function (as `outer.inner`) -> number of start calls in it. A new start call site fails the test below until it has
# a row here and a row in BUDGET_TABLE.
START_CALLEES = {'start_worker', 'handed_start', 'real_start'}
START_SITES = {
    'issue_scan_try_backlog_sweep': 1,
    'work_order_try_supply': 1,
    'issue_scan_try_triage': 1,
    'standing_route': 1,  # a verifier start: no budget check (#1841), see VERIFIER_SITES
    'babysit_pass.start_worker': 1,  # the wrapper, which calls with_coordinator_handle's result: no budget check here
    'babysit_pass': 2,  # the one shot verifier start and its one startup retry: no budget check (#1841)
    '_issue_scan_pass': 3,  # auto ship, rework, issue start
}


def start_call_sites():
    tree = ast.parse(SCRIPT.read_text(encoding='utf-8'))
    found = {}

    def walk(node, scope):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                walk(child, scope + [child.name])
                continue
            if isinstance(child, ast.Call) and isinstance(child.func, ast.Name) and child.func.id in START_CALLEES and scope:
                key = '.'.join(scope[:2]) if len(scope) > 1 and scope[1] == 'start_worker' else scope[0]
                found[key] = found.get(key, 0) + 1
            walk(child, scope)
    walk(tree, [])
    return found


class StartBudget(unittest.TestCase):
    def test_no_budget_set_always_allows(self):  # case 4
        fw.end_pass_clock()
        self.assertTrue(fw.start_allowed(10_000.0))

    def test_budget_is_elapsed_plus_cost_against_the_finish_line(self):
        with patch.object(fw, '_PASS_BEGAN', 1000.0), patch.object(fw.time, 'time', return_value=1000.0 + 35.0):
            self.assertTrue(fw.start_allowed(fw.START_COST_AGY))  # 35 + 105 = 140
            self.assertFalse(fw.start_allowed(fw.START_COST_AGY + 0.5))

    def test_an_agy_start_is_held_while_a_claude_start_is_allowed(self):  # case 12
        with patch.object(fw, '_PASS_BEGAN', 1000.0), patch.object(fw.time, 'time', return_value=1000.0 + 60.0):
            agy = ['bash', 'start.sh', '--agent', AGY]
            alias = ['bash', 'start.sh', '--agent', 'agy']
            claude = ['bash', 'start.sh', '--agent', 'claude']
            self.assertFalse(fw.start_allowed(fw.start_cost(agy)))
            self.assertFalse(fw.start_allowed(fw.start_cost(alias)))
            self.assertTrue(fw.start_allowed(fw.start_cost(claude)))
            self.assertTrue(fw.start_allowed(fw.start_cost(['bash', 'ship.sh'])))

    def test_main_sets_and_clears_the_clock(self):
        seen = []
        with patch.object(fw, '_main', lambda: seen.append(fw._PASS_BEGAN) or 0):
            fw.main()
        self.assertIsNotNone(seen[0])
        self.assertIsNone(fw._PASS_BEGAN)

    def test_every_site_holds_when_the_budget_is_spent(self):  # case 5
        for site, (scenario, bit) in BUDGET_TABLE.items():
            with self.subTest(site=site):
                fw.begin_pass_counts()
                starts, bits, before, after = scenario(True)[:4]
                self.assertEqual(starts, [], site)
                self.assertTrue(any(b.startswith(bit) for b in bits), (site, bits))
                self.assertEqual(norm(after), norm(before), site)
                self.assertEqual((fw._PASS.started, fw._PASS.failed, fw._PASS.parked), (0, 0, 0), site)
                self.assertFalse([b for b in bits if ('_fail' in b and 'list_failed' not in b) or 'deferred' in b or 'parked' in b], (site, bits))

    def test_every_site_starts_when_the_budget_allows(self):
        for site, (scenario, _bit) in BUDGET_TABLE.items():
            with self.subTest(site=site):
                fw.begin_pass_counts()
                starts, bits = scenario(False)[:2]
                self.assertTrue(starts, (site, bits))
                self.assertFalse([b for b in bits if '_budget=' in b and not b.startswith(('supply', 'triage'))], (site, bits))

    def test_new_start_call_site_needs_a_row_in_the_table(self):  # case 6
        self.assertEqual(start_call_sites(), START_SITES)

    def test_with_coordinator_handle_never_refuses_for_time(self):
        calls = []
        with patch.object(fw, '_PASS_BEGAN', 1000.0), patch.object(fw.time, 'time', return_value=1000.0 + 500.0):
            start = fw.with_coordinator_handle({}, lambda command: calls.append(command) or 0)
            self.assertEqual(start(['x']), 0)
        self.assertEqual(calls, [['x']])

    def test_a_site_let_through_starts_even_after_the_clock_passes_the_line(self):  # cases 9 and 10
        for scenario in (issue_start, auto_ship, backlog_sweep, supply, triage):
            with self.subTest(scenario=scenario.__name__):
                allowed = iter([True])
                with patch.object(fw, 'start_allowed', side_effect=lambda cost: next(allowed, True)), \
                        patch.object(fw, '_PASS_BEGAN', 1000.0), patch.object(fw.time, 'time', return_value=1000.0 + 900.0):
                    fw.begin_pass_counts()
                    # start_allowed is stubbed true; the wrapper sees the clock far past the line and must still run.
                    starts, bits = scenario(False)[:2]
                self.assertTrue(starts, bits)
                self.assertFalse([b for b in bits if b.startswith(('ship_fail', 'issue_start_fail', 'issue_deferred', 'backlog_sweep_fail', 'supply_fail', 'triage_fail'))], bits)

    def test_a_held_auto_ship_leaves_the_head_unshipped_for_the_next_pass(self):  # case 10
        starts, bits, _before, state = auto_ship(True)
        self.assertEqual(starts, [])
        head = tier_pr(1, TEST_FILES)['headRefOid']
        self.assertFalse(((state.get('issue_scan_ship') or {}).get('o/r') or {}).get(head))
        starts, bits, _before, state = auto_ship(False)
        self.assertEqual(len(starts), 1, bits)

    def test_a_held_issue_start_does_not_count_toward_the_deferral_escalation(self):  # case 11
        state = {'issue_scan_backlog_sweep_at': TRIAGE_NOW}
        with spent():
            for _ in range(4):
                fw.begin_pass_counts()
                _t, bits, state = triage_run([row(1)], backlog=0, state=state)
        self.assertEqual(state.get('issue_scan_deferred') or {}, {})
        self.assertIn('issue_start_budget=1', bits)

    def test_a_verifier_starts_on_the_same_pass_when_the_budget_is_spent(self):
        for site, scenario in VERIFIER_SITES.items():
            with self.subTest(site=site):
                fw.begin_pass_counts()
                starts, bits, _before, state = scenario(True)
                self.assertEqual(len(starts), 1, (site, bits))
                self.assertFalse([b for b in bits if '_budget=' in b], (site, bits))
                self.assertTrue(state.get('babysit'), site)

    def test_standing_route_starts_when_the_budget_is_spent(self):
        config = tier_config('/tmp')
        config['babysit']['standing_verifier'] = {'enabled': True, 'hosts': [HOST]}
        config['issue_scan']['repo_roots'] = {'o/r': '/tmp'}
        starts = []
        with spent(), tempfile.TemporaryDirectory() as root, \
                patch.dict(os.environ, {'STANDING_VERIFIER_TRIAL_LOG': os.path.join(root, 't.tsv')}):
            result = fw.standing_route(
                config, {}, [], 'o/r', standing_pr(7), ('claude', 'sonnet'), '', [], FakeIO(),
                lambda command: starts.append(command) or fw.BabysitStartResult(0, '', 'ctx_s', 'term_s'),
                lambda *_a, **_k: None, 10_000.0, {}, [])
        self.assertEqual(result, 'started')
        self.assertEqual(len(starts), 1)

    def test_rework_and_issue_start_still_hold_while_a_verifier_starts(self):  # case 8
        for scenario in (rework, issue_start):
            with self.subTest(scenario=scenario.__name__):
                self.assertEqual(scenario(True)[0], [])
        self.assertEqual(len(one_shot_verifier(True)[0]), 1)

if __name__ == '__main__':
    unittest.main()
