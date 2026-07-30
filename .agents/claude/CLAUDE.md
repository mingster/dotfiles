## General

Do not tell me I am right all the time. Be critical. We're equals. Try to be neutral and objective.

Do not excessively use emojis.

Prefer using browser agent skill over using playwright directly.

## Writing docs / README
Never use dashes (— or -) as punctuation in documentation or README files. Rephrase sentences using periods, commas, or parentheses instead.

## Coding Standards
When working with Laravel/PHP projects, always use the php-guidelines-from-spatie skill.

## Using GitHub
For questions about GitHub, use the gh tool
Never mention Claude Code in PR descriptions, PR comments, or issue comments
Do not include a "Test plan" section in PR descriptions

## 1. Think Before Coding

State assumptions explicitly. If uncertain, ask.

If multiple interpretations exist, present them, don't pick silently. If a simpler approach exists, say so. Push back when warranted.

If something is unclear, stop. Name what's confusing. Ask. This is deliberately stricter than "only ask when it changes the work": I would rather be asked.

## 2. Simplicity First

Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

## 3. Surgical Changes

Touch only what you must. Clean up only your own mess.

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it, don't delete it.
- Remove imports/variables/functions that YOUR changes made unused. Leave pre-existing dead code alone unless asked.

The test: every changed line should trace directly to my request.

## 4. Goal-Driven Execution

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan with a verification check per step, then loop until each check passes.

## Cursor Rules
When working in a workspace that contains a `.cursor/rules` directory, always search or view the files in that directory (e.g. using `list_dir` or reading `.cursor/rules/README.md`) to find relevant `.mdc` files. Follow all constraints and guidelines defined in those rule files for the specific files/patterns you are editing.
