#!/usr/bin/env python3
"""A board of 60+ Done cards is finished over several budget limited rounds. Fake orca CLI only."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "board-clean.py"
CARDS = 64
FAKE = """#!/usr/bin/env bash
case "$*" in
  'worktree list --json') cat "$FAKE_TREES" ;;
  'worktree set '*) sleep 0.05; echo "$4" >> "$ORCA_LOG"; echo '{"ok":true,"result":{}}' ;;
  *) echo '{"ok":true,"result":{"workers":[],"scope":{"source":"all"}}}' ;;
esac
"""


class Resume(unittest.TestCase):
    def test_every_card_is_looked_at_though_no_round_covers_the_board(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            orca = root / "orca"
            orca.write_text(FAKE)
            orca.chmod(0o755)
            # Dirty cards are kept for ever: without resuming, every round would stop on the same first ones.
            paths = ["/w/%02d" % n for n in range(CARDS)]
            (root / "trees.json").write_text(json.dumps({"ok": True, "result": {"truncated": False, "worktrees": [
                {"path": p, "branch": "refs/heads/b", "workspaceStatus": "completed", "lastActivityAt": 1} for p in paths]}}))
            (root / "facts.json").write_text(json.dumps(
                {p: {"dirty": True, "unpushed": False, "unmerged": False} for p in paths}))
            log = root / "orca.log"
            log.write_text("")
            env = dict(os.environ, ORCA_CLI_COMMAND=str(orca), ORCA_LOG=str(log), FAKE_TREES=str(root / "trees.json"),
                       BOARD_CLEAN_FACTS=str(root / "facts.json"), BOARD_DONE_STAMP=str(root / "stamps.json"),
                       BOARD_CLEAN_BUDGET_S="3")
            looked, cut = set(), 0
            for _round in range(20):
                done = subprocess.run([sys.executable, str(SCRIPT), "--apply"], env=env, capture_output=True,
                                      text=True, timeout=60)
                self.assertEqual(done.returncode, 0, done.stderr)
                cut += "time budget spent" in done.stdout
                looked = set(log.read_text().split())
                if len(looked) == CARDS:
                    break
            self.assertGreater(cut, 0, "the budget never cut a round, so resume was not exercised")
            self.assertEqual(looked, {"path:" + p for p in paths})


if __name__ == "__main__":
    unittest.main()
