#!/usr/bin/env python3
"""board-sweep runs both board steps, each with its own time limit. Fake orca CLI only."""
import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "board-sweep.py"
REPLY = """echo '{"ok":true,"result":{"environments":[],"worktrees":[],"workers":[],"scope":{"source":"all"}}}'"""


class Sweep(unittest.TestCase):
    def run_sweep(self, fake, *args, **extra):
        with tempfile.TemporaryDirectory() as tmp:
            orca = pathlib.Path(tmp, "orca")
            orca.write_text("#!/usr/bin/env bash\n" + textwrap.dedent(fake) + REPLY + "\n")
            orca.chmod(0o755)
            log = pathlib.Path(tmp, "orca.log")
            env = dict(os.environ, ORCA_CLI_COMMAND=str(orca), ORCA_LOG=str(log), HOME=tmp,
                       BOARD_DONE_STAMP=str(pathlib.Path(tmp, "stamps.json")), **extra)
            done = subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=60)
            return done, log.read_text()

    def test_done_then_clean(self):
        done, log = self.run_sweep('echo "$*" >> "$ORCA_LOG"\n')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(done.stdout.count("applied:"), 2, done.stdout)
        self.assertEqual(log.count("environment list"), 2)

    def test_dry_run_applies_nothing(self):
        done, _log = self.run_sweep('echo "$*" >> "$ORCA_LOG"\n', "--dry-run")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(done.stdout.count("dry-run:"), 2, done.stdout)

    def test_a_hung_board_done_does_not_take_the_clean_step_time(self):
        # The first call is board-done's environment list: hang it once.
        done, _log = self.run_sweep("""
            echo "$*" >> "$ORCA_LOG"
            [ "$(wc -l < "$ORCA_LOG")" -gt 1 ] || sleep 30
        """, BOARD_SWEEP_DONE_TIMEOUT="2", BOARD_SWEEP_CLEAN_TIMEOUT="30")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("board-sweep: board-done timed out", done.stdout)
        self.assertIn("applied: clean=0 keep=0", done.stdout)


if __name__ == "__main__":
    unittest.main()
