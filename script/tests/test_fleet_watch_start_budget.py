"""#1820: one start budget check, start_allowed(cost), owned by each start site; the start wrapper has none.

#1841: verifier starts (one shot and standing) have no budget hold; they start on Review PASS within the usage gate."""
import ast
import copy
import importlib.util
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

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
        # A status notice marker, the short pass count (#1876) and the last ready count (#1904) are not starts.
        out = {k: norm(v) for k, v in value.items() if k not in ('work_order_no_work_day', 'work_order_short_passes', 'work_order_last_supply')}
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
    # The issue start holds on the pass end (#2009), not the start line.
    starts, state = [], {'issue_scan_backlog_sweep_at': TRIAGE_NOW, 'work_order_supply_at': TRIAGE_NOW}
    before = copy.deepcopy(state)
    with patch.object(fw, 'start_fits_pass', return_value=not held):
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
    # Supply is held by start_fits_pass (PASS_HARD_END), not start_allowed (#1889).
    starts, state = [], {'issue_scan_backlog_sweep_at': TRIAGE_NOW}
    before = copy.deepcopy(state)
    order = {'min_active': 3, 'target_workers': 10}
    with patch.object(fw, 'start_fits_pass', return_value=not held):
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

    def test_supply_holds_on_the_pass_end_not_the_start_line(self):  # #1889
        fw.begin_pass_counts()
        starts, bits = supply(True)[:2]
        self.assertTrue(any(b.startswith('supply_budget=') for b in bits), bits)
        self.assertFalse([c for c in starts if 'supply' in ' '.join(map(str, c))], starts)
        with spent():  # START_FINISH_BY spent does not hold it
            bits = triage_run([], backlog=3, state={'issue_scan_backlog_sweep_at': TRIAGE_NOW},
                              order={'min_active': 3, 'target_workers': 10}, starts_out=[])[1]
        self.assertFalse(any(b.startswith('supply_budget=') for b in bits), bits)

    def test_every_site_starts_when_the_budget_allows(self):
        for site, (scenario, _bit) in {**BUDGET_TABLE, 'supply': (supply, '')}.items():
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
                        patch.object(fw, 'start_fits_pass', return_value=True), \
                        patch.object(fw, 'pass_deadline_reached', return_value=False), \
                        patch.object(fw, '_PASS_BEGAN', 1000.0), patch.object(fw.time, 'time', return_value=1000.0 + 900.0):
                    fw.begin_pass_counts()
                    # start_allowed is stubbed true; the wrapper sees the clock far past the line and must still run.
                    # The pass deadline (#1838) is held off: this case is about the wrapper, not the row loops.
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
        with patch.object(fw, 'start_fits_pass', return_value=False):
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


# #1904: the forced supply runs at the start of the pass, free counts only working seats, and an empty supply run fails.
SUPPLY_ORDER = {'min_active': 3, 'target_workers': 10}


def scan_supply(state, workers=(), first=False, order=None):
    """One forced supply candidate pass: no ready issue, five open issues. `first` runs main()'s early supply step."""
    config = park_config('/work/app')
    config['work_order'] = dict(order or SUPPLY_ORDER)
    starts = []
    kwargs = dict(
        gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
        start_worker=lambda cmd: (starts.append(cmd), 0)[1], act=lambda _c: 0, pick_fn=triage_pick,
        count_open=lambda _r: 5, list_blocked=lambda _r: [], ref_state=lambda *_a: None, list_claimed=lambda _r: [],
    )
    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        if first:
            bits = fw.issue_scan_supply_first(config, state, TRIAGE_NOW, list(workers), **kwargs)
        else:
            _n, bits = fw.issue_scan_pass(
                config, state, TRIAGE_NOW, list(workers), pr_fetch=lambda _r: [], list_issues=lambda _r: [],
                repo_id_lookup=lambda _h, _r: 'repo-id', list_backlog=lambda _r: 3, **kwargs)
    return [c for c in starts if 'supply-architect-pm' in c], bits


def short_state(passes=2):
    # A supply worker started 10 minutes ago holds the interval; `passes` short passes already counted.
    return {'issue_scan_backlog_sweep_at': TRIAGE_NOW, 'work_order_supply_at': TRIAGE_NOW - 600,
            'work_order_short_passes': passes}


def live_rows(n):
    return [{'dispatchId': 'd%d' % i, 'dispatchStatus': 'ready', 'terminalState': 'active', '_task_title': '#%d|fullstack-dev' % (i + 1),
             'projection': {'liveness': {'verdict': 'unverifiable'}, 'host': {'id': 'local'}}} for i in range(n)]


class BacklogSweepMaxWorkers(unittest.TestCase):
    """#2016: the sweep starts two roles, so the work_order.max_workers ceiling is checked before each one."""
    CONFIG = {'issue_scan': {'run': 'run_x', 'agent': 'claude', 'model': 'm1', 'repo_roots': {'o/r': '/work/app'}}}

    def setUp(self):
        fw.end_pass_clock()
        self.config = copy.deepcopy(self.CONFIG)
        self.config['work_order'] = {'max_workers': 3}

    def sweep(self, workers, state):
        starts = []
        fw.begin_pass_counts()
        with patch.object(fw, '_write_issue_scan_spec', return_value='/tmp/spec.md'), \
                patch.object(fw, '_issue_scan_startup_script', return_value='/work/startup.sh'):
            bits = fw.issue_scan_try_backlog_sweep(
                self.config, state, TRIAGE_NOW, ['o/r'], 0, 'local', {'occupied': 0}, 0, workers,
                lambda cmd: (starts.append(cmd), 0)[1], None,
            )
        return starts, bits

    def test_one_seat_left_starts_exactly_one_role(self):
        state = {}
        starts, bits = self.sweep(live_rows(2), state)
        self.assertEqual(len(starts), 1, bits)
        self.assertEqual(state.get('issue_scan_backlog_sweep_roles'), ['architect-pm'])

    def test_held_role_starts_on_a_later_pass_with_a_free_seat(self):
        state = {}
        self.sweep(live_rows(2), state)
        starts, bits = self.sweep(live_rows(1), state)
        self.assertEqual(len(starts), 1, bits)
        self.assertIn('--title', starts[0])
        self.assertIn('#0|sales-marketing', starts[0])

    def test_at_max_workers_starts_nothing(self):
        state = {}
        starts, bits = self.sweep(live_rows(3), state)
        self.assertEqual(starts, [])
        self.assertIn('backlog_sweep_max_workers', bits)
        self.assertNotIn('issue_scan_backlog_sweep_roles', state)


class ForcedSupply(unittest.TestCase):
    def tearDown(self):
        fw.end_pass_clock()

    def test_three_short_passes_on_a_slow_pass_still_start_the_forced_supply(self):
        state = short_state(0)
        for _ in range(2):
            self.assertEqual(scan_supply(state)[0], [])
        self.assertEqual(state['work_order_short_passes'], 2)
        fw.begin_pass_clock(time.time())  # main() runs the early step before babysit and the per issue work
        first, first_bits = scan_supply(state, first=True)
        fw.begin_pass_clock(time.time() - 230)  # then the rest of the pass runs slow
        later, bits = scan_supply(state)
        self.assertEqual(len(first), 1, first_bits)
        self.assertIn('supply_force=3', first_bits)
        self.assertIn('unblock_cleared=0', first_bits)
        self.assertEqual(later, [], bits)  # one supply per pass
        self.assertFalse([b for b in first_bits + bits if b.startswith('supply_budget')], first_bits + bits)
        self.assertEqual(state['work_order_short_passes'], 0)

    def test_the_slow_pass_alone_still_refuses_on_the_pass_end(self):
        # The refusal #1904 saw: the late supply call has no time left. The early step is what avoids it.
        fw.begin_pass_clock(time.time() - 230)
        supply, bits = scan_supply(short_state())
        self.assertEqual(supply, [])
        self.assertTrue([b for b in bits if b.startswith('supply_budget')], bits)

    def test_the_early_step_does_nothing_before_the_forced_pass(self):
        state = short_state(0)
        self.assertEqual(scan_supply(state, first=True), ([], []))
        self.assertEqual(state['work_order_short_passes'], 0)

    def test_main_runs_the_early_supply_before_babysit(self):
        tree = ast.parse(SCRIPT.read_text(encoding='utf-8'))
        main = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_main')
        lines = {}
        for node in ast.walk(main):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                lines.setdefault(node.func.id, node.lineno)
        self.assertLess(lines['idle_seat_pass'], lines['issue_scan_supply_first'])
        self.assertLess(lines['issue_scan_supply_first'], lines['babysit_pass'])

    def test_finished_or_idle_workers_do_not_count_toward_free(self):
        order = {'min_active': 3, 'target_workers': 3}
        state = short_state(0)
        _s, bits = scan_supply(state, workers=live_rows(3), order=order)
        self.assertIn('supply_enough=0:0', bits)  # three working seats fill the target
        state = dict(short_state(0), idle_seat={'d0': {'woke_at': TRIAGE_NOW}, 'd1': {'woke_at': TRIAGE_NOW, 'stopped': True}})
        _s, bits = scan_supply(state, workers=live_rows(3), order=order)
        self.assertFalse([b for b in bits if b.startswith('supply_enough')], bits)
        self.assertEqual(state['work_order_short_passes'], 1)

    def test_the_brief_asks_for_one_ready_issue_per_free_seat(self):
        state = {'issue_scan_backlog_sweep_at': TRIAGE_NOW}
        supply, _bits = scan_supply(state, workers=live_rows(2))
        text = Path(supply[0][supply[0].index('--spec') + 1]).read_text(encoding='utf-8')
        self.assertIn('Free seats: 8', text)
        self.assertIn('supply ready=', text)


SUPPLY_ROW = {'dispatchId': 'ctx_supply', 'dispatchStatus': 'completed', '_task_title': '#0|architect-pm|supply'}


def done(subject, dispatch='ctx_supply', mid='m1'):
    return {'id': mid, 'type': 'worker_done', 'subject': subject, 'payload': {'dispatchId': dispatch}}


class SupplyResult(unittest.TestCase):
    def notices(self, messages, state=None, workers=(SUPPLY_ROW,)):
        # A state that already ran a pass: the first pass only records the inbox.
        return fw.supply_done_notices(messages, list(workers), {'supply_done_seen': []} if state is None else state)

    def test_a_supply_run_with_no_ready_issue_and_no_reasons_is_a_failure_in_the_digest(self):
        for subject in ('supply ready=0 reasons=0', 'all done'):
            with self.subTest(subject=subject):
                notices = self.notices([done(subject)])
                self.assertEqual(len(notices), 1, notices)
                self.assertIn('supply run failed', notices[0])
                self.assertIn('ctx_supply', notices[0])

    def test_ready_issues_or_listed_reasons_are_no_failure(self):
        for subject in ('supply ready=2 reasons=0', 'supply ready=0 reasons=4'):
            with self.subTest(subject=subject):
                self.assertEqual(self.notices([done(subject)]), [])

    def test_first_pass_records_old_runs_without_reporting_them(self):
        state = {}
        self.assertEqual(self.notices([done('nothing')], state), [])
        self.assertEqual(len(self.notices([done('nothing'), done('nothing', mid='m2')], state)), 1)

    def test_reported_once_and_only_for_supply_workers(self):
        state = {'supply_done_seen': []}
        self.assertEqual(len(self.notices([done('nothing')], state)), 1)
        self.assertEqual(self.notices([done('nothing')], state), [])
        builder = {'dispatchId': 'ctx_b', '_task_title': '#7|fullstack-dev'}
        self.assertEqual(self.notices([done('nothing', dispatch='ctx_b', mid='m2')], workers=(builder,)), [])


if __name__ == '__main__':
    unittest.main()
