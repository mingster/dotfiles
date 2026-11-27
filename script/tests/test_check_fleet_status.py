"""check-fleet-status.py with stubbed orca and sensor output. No real fleet calls."""
import contextlib
import importlib.util
import io
import json
import os
import time
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "cfs", os.path.join(os.path.dirname(__file__), "..", "check-fleet-status.py")
)
cfs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cfs)

NOW = time.time() * 1000


def worker(n, terminal=None):
    return {"dispatchId": f"ctx_{n}", "terminal": terminal or f"term_{n}", "host": "local",
            "liveness": "live", "outcome": "in_progress", "workspace": f"x::/w/ws{n}"}


def term(last_min_ago, agent="claude", preview="", connected=True, title="t"):
    return {"terminal": {"agentIdentity": agent, "connected": connected, "preview": preview,
                         "lastOutputAt": NOW - last_min_ago * 60000, "title": title}}


class Fleet:
    """Routes orca calls to canned answers keyed on the command words."""

    def __init__(self, workers, terminals, envs=(), sensor=""):
        self.workers, self.terminals, self.envs, self.sensor = workers, terminals, envs, sensor

    def run(self, cmd, timeout=15):
        if cmd[0] == "bash":
            return self.sensor
        if cmd[0] == "memory_pressure":
            return "System-wide memory free percentage: 42%\n"
        env = cmd[cmd.index("--environment") + 1] if "--environment" in cmd else "local"
        if cmd[1:3] == ["environment", "list"]:
            return json.dumps({"result": {"environments": [{"id": e, "name": e} for e in self.envs]}})
        if cmd[1:3] == ["orchestration", "worker-list"]:
            if self.workers.get(env) is None:
                return None
            return json.dumps({"result": {"workers": self.workers[env]}})
        if cmd[1:3] == ["terminal", "show"]:
            t = self.terminals.get(cmd[cmd.index("--terminal") + 1])
            return json.dumps({"result": t}) if t else None
        raise AssertionError(cmd)


def run_main(fleet, *argv):
    cfs.run = fleet.run
    out = io.StringIO()
    with mock.patch.dict(os.environ, {"FLEET_LOAD_SCRIPT": __file__}), contextlib.redirect_stdout(out):
        code = cfs.main(list(argv))
    return code, out.getvalue()


class CheckFleetStatus(unittest.TestCase):
    def setUp(self):
        self.host = cfs.socket.gethostname().split(".")[0]

    def test_all_real_exits_zero(self):
        f = Fleet({"local": [worker(1), worker(2)]},
                  {"term_1": term(1), "term_2": term(60, preview="esc to interrupt")})
        code, out = run_main(f)
        self.assertEqual(code, 0, out)
        self.assertIn("reported=2 real=2", out)
        self.assertIn("mem=42% free", out)

    def test_idle_and_gone_listed_with_dispatch_and_title(self):
        f = Fleet({"local": [worker(1), worker(2), worker(3)]},
                  {"term_1": term(30, title="idle one"), "term_2": term(1, agent=None, title="no agent")})
        code, out = run_main(f)
        self.assertEqual(code, 1)
        self.assertIn("reported=3 real=0", out)
        self.assertIn("reported active, actually idle: ctx_1 idle one", out)
        self.assertIn("reported active, actually gone: ctx_2 no agent", out)
        self.assertIn("reported active, actually gone: ctx_3", out)

    def test_window_is_configurable(self):
        f = Fleet({"local": [worker(1)]}, {"term_1": term(30)})
        self.assertEqual(run_main(f)[0], 1)
        self.assertEqual(run_main(f, "--window-minutes", "45")[0], 0)

    def test_unreachable_environment_is_named(self):
        f = Fleet({"local": [], "envB": None}, {}, envs=["envB"])
        code, out = run_main(f)
        self.assertEqual(code, 1)
        self.assertIn("envB: UNREACHABLE", out)

    def test_sensor_unreachable_and_load(self):
        sensor = f"{self.host} cores=8 load=2.50 2 2 memfree=6.0\nhostB cores=4 load=1 1 1\n"
        f = Fleet({"local": []}, {}, sensor=sensor)
        code, out = run_main(f)
        self.assertEqual(code, 0)
        self.assertIn("load=2.50/8c mem=6.0GB free", out)
        f2 = Fleet({"local": []}, {}, sensor=f"{self.host} unreachable\n")
        code, out = run_main(f2)
        self.assertEqual(code, 1)
        self.assertIn(f"{self.host}: UNREACHABLE", out)

    def test_count_prints_only_the_really_active_workers(self):
        f = Fleet({"local": [worker(1), worker(2), worker(3)]},
                  {"term_1": term(1), "term_2": term(30), "term_3": term(1, agent=None)})
        code, out = run_main(f, "--count")
        self.assertEqual((code, out), (0, "1\n"))

    def test_count_adds_every_host(self):
        f = Fleet({"local": [worker(1)], "envB": [worker(2)]}, {"term_1": term(1), "term_2": term(1)}, envs=["envB"])
        self.assertEqual(run_main(f, "--count"), (0, "2\n"))

    def test_count_with_an_unreadable_host_exits_one_and_names_it(self):
        f = Fleet({"local": [worker(1)], "envB": None}, {"term_1": term(1)}, envs=["envB"])
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code, out = run_main(f, "--count")
        self.assertEqual((code, out), (1, "1\n"))
        self.assertIn("unreachable: envB", err.getvalue())

    def test_count_ignores_a_failed_load_probe(self):
        f = Fleet({"local": [worker(1)]}, {"term_1": term(1)}, sensor=f"{self.host} unreachable\n")
        self.assertEqual(run_main(f, "--count"), (0, "1\n"))

    def test_help_prints_usage_and_what_is_checked_on_stdout_and_exits_zero(self):
        def no_orca(cmd, timeout=15):
            raise AssertionError(cmd)

        cfs.run = no_orca
        for flag in ("-h", "--help"):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = cfs.main([flag])
            self.assertEqual(code, 0, flag)
            self.assertIn("Usage: check-fleet-status.py [--window-minutes N] [--json | --count]", out.getvalue())
            self.assertIn("each worker Orca reports", out.getvalue())
            self.assertEqual(err.getvalue(), "", flag)

    def test_bad_usage_prints_usage_on_stderr_and_exits_two(self):
        for args in (["--nope"], ["--window-minutes"], ["--window-minutes", "x"]):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = cfs.main(args)
            self.assertEqual(code, 2, args)
            self.assertIn("Usage: check-fleet-status.py", err.getvalue(), args)
            self.assertEqual(out.getvalue(), "", args)


if __name__ == "__main__":
    unittest.main()
