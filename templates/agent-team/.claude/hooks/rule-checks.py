#!/usr/bin/env python3
"""Mechanical CLAUDE.md and AGENTS.md rules, checked instead of only written down.

One hook, registered once per event (PreToolUse on Bash|Write|Edit|MultiEdit, PostToolUse on Write|Edit|MultiEdit).

PreToolUse Bash: `gh pr|issue create|edit|comment` is denied when its title, body or body file
  names the assistant product, or has a "Test plan" heading.
PreToolUse Write|Edit: an edit to CHANGELOG.md is denied when the repo has changelog.d/.
PostToolUse Write|Edit: a warning for a spaced dash between two words in written markdown
  (outside code), and for an AGENTS.md over 200 lines.

Anything unexpected exits 0 and lets the call through: this is a seatbelt, not a gate.
"""
import json
import os
import re
import shlex
import sys

GH_TEXT = re.compile(r"(^|[;&|(]\s*|\s)gh\s+(pr|issue)\s+(create|edit|comment)\b")
PRODUCT = re.compile("claude" + r"[\s-]*code", re.I)
TEST_PLAN = re.compile(r"^\s*(#{1,6}\s*|\*\*)test\s+plan\b", re.I | re.M)
DASH = re.compile(r"(?<=\w) (?:—|–|-) (?=\w)")
FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"`[^`\n]*`")
AGENTS_LIMIT = 200


def emit(event, **fields):
    print(json.dumps({"hookSpecificOutput": dict(hookEventName=event, **fields)}))


def deny(reason):
    emit("PreToolUse", permissionDecision="deny", permissionDecisionReason=reason)


def body_files(command, cwd):
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        tokens = command.split()
    paths = []
    for i, t in enumerate(tokens):
        value = None
        if t in ("--body-file", "-F") and i + 1 < len(tokens):
            value = tokens[i + 1]
        elif t.startswith("--body-file="):
            value = t.split("=", 1)[1]
        if value and value != "-":
            paths.append(os.path.join(cwd, os.path.expanduser(value)))
    return paths


def check_bash(data):
    command = data.get("tool_input", {}).get("command", "")
    if "gh" not in command or not GH_TEXT.search(command):
        return
    text = command
    for path in body_files(command, data.get("cwd") or os.getcwd()):
        try:
            with open(path, errors="replace") as f:
                text += "\n" + f.read()
        except OSError:
            pass
    if PRODUCT.search(text):
        deny("PR and issue text never names the assistant product name (CLAUDE.md, Using GitHub). Remove it and retry.")
    elif TEST_PLAN.search(text):
        deny('PR text has no "Test plan" section (CLAUDE.md, Using GitHub). Remove that heading and retry.')


def file_path(data):
    path = data.get("tool_input", {}).get("file_path", "")
    return path if os.path.isabs(path) else os.path.join(data.get("cwd") or os.getcwd(), path)


def check_changelog(data):
    path = file_path(data)
    if os.path.basename(path) == "CHANGELOG.md" and os.path.isdir(os.path.join(os.path.dirname(path), "changelog.d")):
        deny("Never edit CHANGELOG.md in a PR. Add a changelog.d/<issue>-<slug>.md fragment instead.")


def dash_lines(text):
    lines, in_fence = [], False
    for n, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
        elif not in_fence and DASH.search(INLINE_CODE.sub("", line)):
            lines.append(n)
    return lines


def edited_dash_lines(path, tool_input):
    """Dash lines of an Edit or MultiEdit, numbered and fenced by the whole file on disk."""
    if "new_string" in tool_input:
        pieces = [tool_input["new_string"]]
    else:
        pieces = [e.get("new_string", "") for e in tool_input.get("edits", [])]
    try:
        with open(path, errors="replace") as f:
            full = f.read()
    except OSError:
        return [n for piece in pieces for n in dash_lines(piece)]
    file_dashes = set(dash_lines(full))
    lines = []
    for piece in pieces:
        if not piece:
            continue
        starts = [m.start() for m in re.finditer(re.escape(piece), full)]
        if not starts:
            lines.extend(dash_lines(piece))
        for start in starts:
            first = full.count("\n", 0, start) + 1
            last = first + piece.rstrip("\n").count("\n")
            lines.extend(n for n in range(first, last + 1) if n in file_dashes)
    return sorted(set(lines))


def check_written(data):
    tool_input = data.get("tool_input", {})
    path = file_path(data)
    notes = []
    if path.endswith(".md"):
        lines = dash_lines(tool_input["content"]) if "content" in tool_input else edited_dash_lines(path, tool_input)
        if lines:
            shown = ", ".join(str(n) for n in lines[:10])
            notes.append(f"{os.path.basename(path)} line {shown}: a dash is used as punctuation. "
                         "Docs use periods, commas or parentheses instead (CLAUDE.md, Writing docs).")
    if os.path.basename(path) == "AGENTS.md":
        count = len(tool_input["content"].splitlines()) if "content" in tool_input else 0
        if not count:
            try:
                with open(path, errors="replace") as f:
                    count = sum(1 for _ in f)
            except OSError:
                pass
        if count > AGENTS_LIMIT:
            notes.append(f"AGENTS.md has {count} lines, over the {AGENTS_LIMIT} limit. Move area specific text to docs/<area>/<topic>.md behind a pointer.")
    if notes:
        emit("PostToolUse", additionalContext=" ".join(notes))


def main():
    try:
        data = json.load(sys.stdin)
        event, tool = data.get("hook_event_name"), data.get("tool_name")
        if event == "PreToolUse" and tool == "Bash":
            check_bash(data)
        elif event == "PreToolUse" and tool in ("Write", "Edit", "MultiEdit"):
            check_changelog(data)
        elif event == "PostToolUse" and tool in ("Write", "Edit", "MultiEdit"):
            check_written(data)
    except Exception:
        pass


main()
