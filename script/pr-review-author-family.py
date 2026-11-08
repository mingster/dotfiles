#!/usr/bin/env python3
"""Infer builder model family for cross-family review pick. Reads env AUTHOR_FAMILY first."""
import json
import re
import subprocess
import sys

FAMILIES = frozenset({"claude", "gpt", "gemini", "composer", "grok"})


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: pr-review-author-family.py <repo> <pr>", file=sys.stderr)
        return 2
    repo, pr = sys.argv[1], sys.argv[2]
    env = ( __import__("os").environ.get("AUTHOR_FAMILY") or "").strip().lower()
    if env in FAMILIES:
        print(env)
        return 0
    out = subprocess.run(
        ["gh", "pr", "view", pr, "--repo", repo, "--json", "labels,commits"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if out.returncode != 0:
        print("claude")
        return 0
    try:
        payload = json.loads(out.stdout or "{}")
    except ValueError:
        print("claude")
        return 0
    for label in payload.get("labels") or []:
        name = (label.get("name") or "").lower()
        m = re.fullmatch(r"author-family-([a-z]+)", name)
        if m and m.group(1) in FAMILIES:
            print(m.group(1))
            return 0
    pat = re.compile(r"^Author-Family:\s*(\S+)", re.I | re.M)
    for commit in payload.get("commits") or []:
        body = (commit.get("messageBody") or "") + "\n" + (commit.get("messageHeadline") or "")
        for m in pat.finditer(body):
            fam = m.group(1).lower()
            if fam in FAMILIES:
                print(fam)
                return 0
    print("claude")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
