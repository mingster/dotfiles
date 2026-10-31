#!/usr/bin/env python3
"""Decide whether a cross-family QA reviewer may launch on an exact Orca workspace.

Operator-owned admission policy (never auto-created) lives in the path named by
ON_WORKER_DONE_ADMISSION_POLICY. Version 1 binds one review: saved runtime host,
repo, absolute worktree path, and head SHA, plus authorized host caps and provider
models. This helper reads Orca inventory and fleet-watch --admit only; it never
starts a worker. A successful run prints one JSON object to stdout:

  {"environment_id": "<saved id or LOCAL>", "worktree_selector": "<native selector>",
   "host": "<policy runtime host name>"}

Race: inventory and admit receipts are point-in-time reads, not an atomic reservation.
Provider/model identity on manual terminals may be UNKNOWN when native terminal list
fields do not expose them; those paths fail closed unless policy waives observation.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

POLICY_VERSION = 1


def refuse(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def parse_utc(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value).astimezone(timezone.utc)


def normalize_repo(repo: str) -> str:
    repo = repo.strip()
    if repo.startswith("github:"):
        return repo
    if "/" in repo and not repo.startswith("path:"):
        return "github:" + repo
    return repo


def load_policy(path: str) -> dict[str, Any]:
    if not path:
        refuse("admission policy path not set")
    if not os.path.isfile(path):
        refuse("admission policy missing or unreadable: %s" % path)
    try:
        policy = json.load(open(path))
    except (OSError, ValueError):
        refuse("admission policy invalid JSON")
    if policy.get("version") != POLICY_VERSION:
        refuse("admission policy version mismatch")
    for key in ("issued_at", "expires_at", "review", "hosts"):
        if key not in policy:
            refuse("admission policy missing %s" % key)
    now = datetime.now(timezone.utc)
    issued = parse_utc(policy["issued_at"])
    expires = parse_utc(policy["expires_at"])
    if issued > now:
        refuse("admission policy not yet issued")
    if expires <= now:
        refuse("admission policy expired")
    if expires > parse_utc("2026-11-01T19:00:00Z"):
        refuse("admission policy expires after owner window")
    return policy


def validate_review_binding(policy: dict, repo: str, head: str, worktree_path: str) -> dict:
    review = policy["review"]
    for key in ("runtime_host", "repo", "worktree_path", "head"):
        if key not in review:
            refuse("admission policy review missing %s" % key)
    if normalize_repo(review["repo"]) != normalize_repo(repo):
        refuse("admission policy repo mismatch")
    if review["head"] != head:
        refuse("admission policy head mismatch")
    if review["worktree_path"] != worktree_path:
        refuse("admission policy worktree path mismatch")
    host = review["runtime_host"]
    if host not in policy["hosts"]:
        refuse("admission policy runtime_host not in hosts")
    return review


def validate_verifier(policy: dict, host: str, provider: str, model: str) -> None:
    hosts = policy["hosts"][host]
    providers = hosts.get("providers")
    if not isinstance(providers, dict) or provider not in providers:
        refuse("verifier provider not authorized on %s" % host)
    models = providers[provider].get("models")
    if not isinstance(models, list) or model not in models:
        refuse("verifier model not authorized on %s" % host)


def validate_admit_receipt(receipt: dict, requested_host: str, caps: dict) -> str | None:
    if not isinstance(receipt, dict):
        return "%s: malformed admit receipt" % requested_host
    if receipt.get("host") != requested_host:
        return "%s: admit host mismatch" % requested_host
    if receipt.get("admitted") is not True:
        return receipt.get("reason") or ("%s: not admitted" % requested_host)
    expected_cap = caps.get(requested_host)
    if type(expected_cap) is not int or expected_cap <= 0:
        return "invalid cap in fleet config for %s" % requested_host
    cap, occupied = receipt.get("cap"), receipt.get("occupied")
    if type(cap) is not int or type(occupied) is not int:
        return "%s: invalid cap or occupied in admit receipt" % requested_host
    if cap != expected_cap:
        return "%s: admit cap mismatch" % requested_host
    if occupied < 0 or occupied >= cap:
        return "%s: admit occupied out of range" % requested_host
    return None


def run_orca(orca: str, *args: str) -> dict:
    proc = subprocess.run([orca, *args, "--json"], capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        refuse("orca %s failed" % " ".join(args))
    try:
        payload = json.loads(proc.stdout)
    except ValueError:
        refuse("orca %s returned invalid JSON" % args[0])
    if payload.get("ok") is not True:
        refuse("orca %s returned ok=false" % args[0])
    return payload


def list_environments(orca: str) -> dict[str, dict]:
    payload = run_orca(orca, "environment", "list")
    envs = payload.get("result", {}).get("environments") or []
    by_name: dict[str, dict] = {}
    by_id: dict[str, dict] = {}
    for entry in envs:
        if not isinstance(entry, dict):
            refuse("invalid Orca environment entry")
        name, eid = entry.get("name"), entry.get("id")
        if not name or not eid:
            refuse("incomplete Orca environment entry")
        if name in by_name or eid in by_id:
            refuse("ambiguous Orca environment identity")
        by_name[name] = entry
        by_id[eid] = entry
    return by_name


def resolve_saved_environment(review: dict, by_name: dict[str, dict], local_hostname: str) -> tuple[str, str | None]:
    """Return (environment_id for --on, saved name). LOCAL means Run home on this machine."""
    saved = review.get("saved_environment_id")
    saved_name = review.get("saved_environment_name")
    runtime = review["runtime_host"]
    if saved_name:
        if saved_name not in by_name:
            refuse("saved Orca environment name not found: %s" % saved_name)
        if saved_name != runtime and saved_name not in (local_hostname, runtime):
            refuse("saved environment name does not match runtime host")
        return by_name[saved_name]["id"], saved_name
    if saved:
        return saved, saved_name
    if runtime == local_hostname:
        return "LOCAL", None
    if runtime in by_name:
        return by_name[runtime]["id"], runtime
    refuse("no saved Orca environment for runtime host %s" % runtime)


def worktree_selector(entry: dict) -> str:
    ident = entry.get("identity") or {}
    key = ident.get("key")
    if isinstance(key, str) and key:
        return "identity:" + key
    wid = entry.get("id")
    if isinstance(wid, str) and wid:
        return "id:" + wid
    refuse("worktree missing native identity")


def fetch_worktrees(orca: str, environment_id: str | None, repo: str) -> list[dict]:
    repo_sel = normalize_repo(repo)
    if not repo_sel.startswith("github:"):
        repo_sel = "path:" + repo if repo.startswith("/") else repo
    args = ["worktree", "list", "--repo", repo_sel, "--limit", "100"]
    if environment_id and environment_id != "LOCAL":
        args = ["worktree", "list", "--environment", environment_id, "--repo", repo_sel, "--limit", "100"]
    payload = run_orca(orca, *args)
    result = payload.get("result") or {}
    page = result.get("page") or {}
    if page.get("truncated") is True:
        refuse("worktree inventory truncated")
    if page.get("hasMore") is True:
        refuse("worktree inventory incomplete")
    worktrees = result.get("worktrees")
    if not isinstance(worktrees, list):
        refuse("worktree inventory missing")
    return worktrees


def match_worktree(worktrees: list[dict], path: str, head: str) -> dict:
    matches = [w for w in worktrees if isinstance(w, dict) and w.get("path") == path and w.get("head") == head]
    if not matches:
        refuse("no Orca worktree at authorized path and head")
    if len(matches) > 1:
        refuse("ambiguous Orca worktree for path and head")
    return matches[0]


def read_load(host: str, ceiling: float, fleet_load: str, self_observation: str | None) -> None:
    load_1m = None
    obs_blob = os.environ.get("QA_ADMISSION_LOAD_OBS")
    if obs_blob:
        try:
            load_1m = float(json.loads(obs_blob).get(host, {}).get("load_1m"))
        except (ValueError, TypeError, AttributeError):
            refuse("invalid load observation map")
    if load_1m is None and self_observation:
        try:
            obs = json.loads(self_observation)
            load_1m = float(obs.get("load_1m"))
        except (ValueError, TypeError):
            refuse("invalid self load observation")
    elif os.path.isfile(fleet_load):
        text = open(fleet_load).read() if fleet_load.endswith(".json") else None
        if fleet_load.endswith(".json") and text:
            try:
                load_1m = float(json.load(open(fleet_load)).get(host, {}).get("load_1m"))
            except (ValueError, TypeError, AttributeError):
                refuse("invalid fleet load snapshot")
        else:
            proc = subprocess.run(["bash", fleet_load], capture_output=True, text=True, timeout=30)
            for line in proc.stdout.splitlines():
                if line.startswith(host):
                    m = re.search(r"load=([0-9.]+)", line)
                    if m:
                        load_1m = float(m.group(1))
                    elif "unreachable" in line:
                        refuse("fleet load unreachable for %s" % host)
    if load_1m is None:
        refuse("load unknown for %s" % host)
    if load_1m >= ceiling:
        refuse("load %.2f at or above ceiling %.2f on %s" % (load_1m, ceiling, host))


def fleet_admit(fleet_watch: str, fleet_config: str, host: str, caps: dict) -> None:
    proc = subprocess.run([fleet_watch, "--config", fleet_config, "--admit", host],
                          capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        reason = proc.stderr.strip() or proc.stdout.strip()
        try:
            reason = json.loads(proc.stdout).get("reason") or reason
        except ValueError:
            pass
        refuse(reason or ("admit exit %d" % proc.returncode))
    try:
        receipt = json.loads(proc.stdout)
    except ValueError:
        refuse("malformed admit receipt")
    err = validate_admit_receipt(receipt, host, caps)
    if err:
        refuse(err)


def admit(args: argparse.Namespace) -> dict:
    policy = load_policy(args.policy)
    review = validate_review_binding(policy, args.repo, args.head, args.worktree_path)
    host = review["runtime_host"]
    validate_verifier(policy, host, args.verifier_provider, args.verifier_model)

    try:
        fleet_cfg = json.load(open(args.fleet_config))
    except (OSError, ValueError):
        refuse("invalid fleet config")
    caps = fleet_cfg.get("host_caps")
    if not isinstance(caps, dict) or host not in caps:
        refuse("fleet config missing host_caps for %s" % host)

    orca = os.environ.get("ORCA_CLI_COMMAND", "orca")
    by_name = list_environments(orca)
    local_hostname = os.environ.get("QA_ADMISSION_LOCAL_HOST") or os.uname().nodename.split(".")[0]
    environment_id, _ = resolve_saved_environment(review, by_name, local_hostname)

    fleet_watch = os.environ.get("ON_WORKER_DONE_FLEET_WATCH") or os.path.join(
        os.path.dirname(__file__), "fleet-watch.py")
    fleet_admit(fleet_watch, args.fleet_config, host, caps)

    host_policy = policy["hosts"][host]
    read_load(host, float(host_policy["load_ceiling"]), args.fleet_load,
              os.environ.get("QA_ADMISSION_SELF_LOAD"))

    worktrees = fetch_worktrees(orca, environment_id if environment_id != "LOCAL" else None, args.repo)
    entry = match_worktree(worktrees, args.worktree_path, args.head)

    return {
        "environment_id": environment_id,
        "worktree_selector": worktree_selector(entry),
        "host": host,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--policy", default=os.environ.get("ON_WORKER_DONE_ADMISSION_POLICY", ""))
    ap.add_argument("--fleet-config", default=os.environ.get("ON_WORKER_DONE_FLEET_CONFIG", ""))
    ap.add_argument("--fleet-load", default=os.environ.get("QA_ADMISSION_FLEET_LOAD",
                                                            os.path.expanduser("~/.claude/state/fleet-load.sh")))
    ap.add_argument("--repo", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--worktree-path", required=True)
    ap.add_argument("--verifier-provider", required=True)
    ap.add_argument("--verifier-model", required=True)
    ns = ap.parse_args(argv)
    if not ns.fleet_config:
        refuse("fleet config path not set")
    result = admit(ns)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
