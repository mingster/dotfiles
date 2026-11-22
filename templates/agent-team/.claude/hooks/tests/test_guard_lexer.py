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


class Pr1407Boundaries(unittest.TestCase):
    """Where the lexer stops trusting itself (#1407 Review): a quote, expansion or test it cannot place is a LexError."""

    def test_unreadable_shapes(self):
        for text in (
            "echo \"${HOME:-'}\"; cat .env.local; echo \"'}\"",   # quote inside a double quoted ${
            "echo $(( $'it\\'))' ? 0 : 1 )); cat .env.local # \\'",  # quote inside $((
            "(( x = 'a' ))",
            "[[ -n a\n# '\n]] && cat .env.local # ' ]]",          # comment inside [[ ]]
            "[[ -n a]]) ]]",                                       # `]]` glued to an operator
            "f() if true; then cd /tmp; fi",                       # a function body that is not { } or ( )
        ):
            with self.subTest(text=text), self.assertRaises(guard.LexError):
                list(guard.walk(text, "/w"))

    def test_test_ends_at_close_bracket_beside_an_operator(self):
        self.assertEqual([c.tokens[0] for c in guard.walk("echo $( [[ -n a ]]) && cat .env.local # ]] )", "/w")],
                         ["[[", "echo", "cat"])

    def test_unquoted_param_decodes_dollar_quote(self):
        word = guard.lex("echo ${X:-$'a\\x62'}")[0].argv[1]
        self.assertEqual(word.alt({}), "ab")
        self.assertIn("ab", word.deep)

    def test_process_substitution_is_a_redirect_target(self):
        self.assertEqual(walked("cat < <(sort a.txt)")[-1], (["cat", "<", "<(sort a.txt)"], 0))
        self.assertIn((["sort", "a.txt"], 1), walked("cat < <(sort a.txt)"))

    def test_redirects_come_after_the_words(self):
        self.assertEqual(walked("2>/dev/null git push --force")[0][0], ["git", "push", "--force", "2>/dev/null"])

    def test_time_flags_and_append_assignment(self):
        self.assertEqual(walked("time -p -- ls")[0][0], ["ls"])
        self.assertEqual(guard.program_and_args(["A+=1", "B[0]=2", "ls"]), ("ls", []))

    def test_default_value_and_loop_variants(self):
        self.assertIn(["cat", ".env.local"], [c.tokens for c in guard.walk("cat ${X:-.env.local}", "/w")])
        tokens = [c.tokens for c in guard.walk("for f in a b; do cat \"$f\"; done", "/w")]
        self.assertIn(["cat", "a"], tokens)
        self.assertIn(["cat", "b"], tokens)

    def test_shell_c_option_clusters(self):
        for args, script in ((["-oc", "errexit", "x"], "x"), (["-co", "errexit", "x"], "x"),
                             (["-c", "--", "x"], "x"), (["-euo", "pipefail", "-c", "x"], "x"), (["x.sh"], None)):
            with self.subTest(args=args):
                got = guard.shell_c_script(args)
                self.assertEqual(got and got[0], script)


class Pr1407Cwd(unittest.TestCase):
    def cwds(self, text):
        return [(c.tokens[0], c.cwd) for c in guard.walk(text, "/w")]

    def test_subshell_cd_stays_inside(self):
        self.assertEqual(self.cwds("(cd /tmp; ls); pwd"), [("cd", "/w"), ("ls", "/tmp"), ("pwd", "/w")])

    def test_cd_that_may_not_run_keeps_both(self):
        for text in ("f() { cd /tmp; }; pwd", "true || cd /tmp; pwd", "if x; then cd /tmp; fi; pwd",
                     "cd /tmp | cat; pwd", "cd /tmp & pwd"):
            with self.subTest(text=text):
                self.assertEqual([c for t, c in self.cwds(text) if t == "pwd"], ["/w", "/tmp"])


class Pr1407Matrix(GuardTest):
    """Each payload under each disguise from the #1407 Review is denied."""
    PAYLOADS = ("cat .env.local", "git push --force origin main", "bunx playwright test")
    DISGUISES = ("2>/dev/null {}", "time -p {}", "time -- {}", "A+=1 {}", "( {} )", "{{ {}; }}",
                 "true && {}", "bash -oc errexit {q}", "bash -co errexit {q}", "bash -c -- {q}",
                 "bash -c 2>/dev/null {q}", "for f in x; do {}; done")

    def test_matrix(self):
        for payload in self.PAYLOADS:
            for disguise in self.DISGUISES:
                command = disguise.format(payload, q=f'"{payload}"')
                with self.subTest(command=command):
                    self.assertDenied(command)

    def test_default_value_disguises(self):
        for command in ("cat ${X:-.env.local}", "git push ${X:---force} origin main", "bunx ${X:-playwright} test",
                        "cat \"${X:-.env.local}\""):
            with self.subTest(command=command):
                self.assertDenied(command)


class Pr1407LinkedWorktree(GuardTest):
    """#1407 Review shapes that need a linked worktree, which the fixture checker does not have."""

    def setUp(self):
        super().setUp()
        with open(os.path.join(self.home, ".git"), "w") as f:
            f.write("gitdir: /nowhere/.git/worktrees/x\n")

    def test_env_writes_the_old_scan_missed(self):
        for command in ("echo x > $'.env.lo\\x63al'", "echo $'it\\'s' > .env.local", "echo \"$( # \"\n)\" > .env.local",
                        "2>/dev/null cp /tmp/a .env.local", "echo x > ${X:-.env.local}"):
            with self.subTest(command=command):
                self.assertDenied(command)

    def test_cd_that_does_not_move_the_cp(self):
        for command in ("(cd /tmp); cp /tmp/a .env.local", "f() { cd /tmp; }; cp /tmp/a .env.local",
                        "true || cd /tmp; cp /tmp/a .env.local", "if false; then cd /tmp; fi; cp /tmp/a .env.local",
                        "cd /tmp & cp /tmp/a .env.local"):
            with self.subTest(command=command):
                self.assertDenied(command)


if __name__ == "__main__":
    unittest.main()
