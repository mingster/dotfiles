"""Tests for the shell lexer (`lex`) and command walker (`walk`) in guard-bash.py (#1385).

Run from the repo root: python3 -m unittest discover -s templates/agent-team/.claude/hooks/tests
"""
import importlib.util
import os
import unittest

from test_guard_bash import HOOK, GuardTest

spec = importlib.util.spec_from_file_location("guard_bash_lexer", HOOK)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def argv(text):
    return [w.text for w in guard.lex(text)[0].argv]


def walked(text, cwd="/w"):
    return [(cmd.tokens, cmd.nested) for cmd in guard.walk(text, cwd)]


class Words(unittest.TestCase):
    def test_ansi_c_quotes_decode(self):
        self.assertEqual(argv("echo $'a\\x41\\n\\t'"), ["echo", "aA\n\t"])

    def test_ansi_c_nul_ends_the_string_like_bash(self):
        self.assertEqual(argv("printf %s $'a\\x00b'\"c\""), ["printf", "%s", "ac"])

    def test_ansi_c_surrogate_is_unreadable(self):
        with self.assertRaises(guard.LexError):
            guard.lex("echo $'\\ud800'")

    def test_dollar_quote_inside_double_quotes_is_literal(self):
        self.assertEqual(argv("echo \"$'x'\""), ["echo", "$'x'"])

    def test_static_and_quoted(self):
        words = guard.lex("echo a 'b' $X \"$(id)\"")[0].argv
        self.assertEqual([w.static for w in words], [True, True, True, False, False])
        self.assertEqual([w.quoted for w in words], [False, False, True, True, True])  # anything but plain text

    def test_arithmetic_is_not_a_subshell(self):
        part = guard.lex("echo $((1 + 2))")[0].argv[1].parts[0]
        self.assertEqual(part.kind, "arith")
        self.assertEqual(walked("echo $( (rm x) )")[0], (["rm", "x"], 1))

    def test_unterminated_constructs_are_unreadable(self):
        for text in ("echo 'a", 'echo "a', "echo $(a", "echo `a", "cat <<EOF\nx", "echo ${a", "echo )", "cat >"):
            with self.subTest(text=text), self.assertRaises(guard.LexError):
                guard.lex(text)

    def test_nesting_past_the_limit_is_unreadable(self):
        with self.assertRaises(guard.LexError):
            guard.lex("echo " + "$(" * (guard.LEX_DEPTH + 2) + "x" + ")" * (guard.LEX_DEPTH + 2))


class Redirects(unittest.TestCase):
    def test_redirect_tokens(self):
        self.assertEqual(walked("cat < .env.local")[0][0], ["cat", "<", ".env.local"])
        self.assertEqual(walked("ls 2>/dev/null")[0][0], ["ls", "2>/dev/null"])
        self.assertEqual(walked("ls 2> /dev/null")[0][0], ["ls", "2>", "/dev/null"])

    def test_quoted_heredoc_body_is_data_and_unquoted_body_runs_substitutions(self):
        self.assertEqual(walked("cat <<'EOF'\n$(rm x)\nEOF"), [(["cat", "<<EOF"], 0)])
        self.assertEqual(walked("cat <<EOF\n$(rm x)\nEOF")[0], (["rm", "x"], 1))
        r = guard.lex("cat <<-EOF\n\tbody\n\tEOF\necho done")[0].redirects[0]
        self.assertEqual((r.delim, r.quoted, r.body), ("EOF", False, "\tbody\n"))

    def test_heredoc_in_substitution_that_bash_3_2_ends_early_is_unreadable(self):
        for close in ("hi)", "EOF)", "see (a) and b); "):
            with self.subTest(close=close), self.assertRaises(guard.LexError):
                guard.lex(f"gh issue comment 5 --body \"$(cat <<'EOF'\n{close}\nEOF\n)\"")
        self.assertEqual(len(guard.lex("gh issue comment 5 --body \"$(cat <<'EOF'\nsee (a)\nEOF\n)\"")), 1)


class Walker(unittest.TestCase):
    def test_substitution_bodies_come_first(self):
        self.assertEqual(walked("echo $(id) `whoami`"), [(["id"], 1), (["whoami"], 1), (["echo", "$(id)", "`whoami`"], 0)])

    def test_backtick_body_unescapes_and_drops_comments(self):
        self.assertEqual(walked("echo `echo \\$HOME`")[0], (["echo", "$HOME"], 1))
        self.assertEqual(walked("echo `true # x`")[0], (["true"], 1))

    def test_comment_is_not_a_command(self):
        self.assertEqual(walked("# ; rm x\nls"), [(["ls"], 0)])

    def test_compound_commands(self):
        self.assertEqual([t for t, _ in walked("case $x in a) rm -rf b ;; esac") if t], [["rm", "-rf", "b"]])
        self.assertIn(["rm", "$f"], [t for t, _ in walked("for f in $(ls); do rm \"$f\"; done")])
        self.assertIn(["ls"], [t for t, _ in walked("for f in $(ls); do rm \"$f\"; done")])
        self.assertIn(["rm", "x"], [t for t, _ in walked("[[ -f a && -f b ]] && rm x")])
        self.assertIn(["rm", "x"], [t for t, _ in walked("(( n > 1 )) && rm x")])
        self.assertIn(["rm", "-rf", "x"], [t for t, _ in walked("f() { rm -rf x; }; f")])

    def test_cd_moves_the_cwd_of_later_commands(self):
        cwds = [(cmd.tokens[0], cmd.cwd) for cmd in guard.walk("ls; cd /tmp && ls; cd sub; pwd", "/w")]
        self.assertEqual(cwds, [("ls", "/w"), ("cd", "/w"), ("ls", "/tmp"), ("cd", "/tmp"), ("pwd", "/tmp/sub")])


class FailClosed(GuardTest):
    def test_a_command_the_lexer_cannot_read_is_denied(self):
        for command in ("echo 'a", "cat <<EOF\nx", "echo $(", "echo $'\\ud800'"):
            with self.subTest(command=command):
                self.assertDenied(command, "cannot read this command")

    def test_comment_does_not_move_the_cwd_in_a_linked_worktree(self):
        """Fixture pr1406-r1-23 needs a linked worktree, so it lives here: `# ; cd /tmp` is a comment."""
        with open(os.path.join(self.home, ".git"), "w") as f:
            f.write("gitdir: /nowhere/.git/worktrees/x\n")
        self.assertDenied("# ; cd /tmp\ncp /tmp/a .env.local")


if __name__ == "__main__":
    unittest.main()
