#!/usr/bin/env bun
// Weekly team audit metrics for one repository. One key=value line per metric on stdout.
// Missing data reads "unknown", never zero.
//
// Usage:
//   bun script/team-audit-metrics.ts --repo <owner/name> [--days <n>] [--json] [--dispatches <tsv>]
//   bun script/team-audit-metrics.ts --fixture <data.json> [--dispatches <tsv>] [--json]
//
// --repo makes two gh calls: one GraphQL search for the merged PRs (first commit GitHub Actions
// check runs, app id 15368, and the closing issue timeline inline; at most 100 PRs) and one gh
// issue list for the month.
// --fixture reads the data from a JSON file instead of GitHub (offline tests):
//   { "now": ISO, "prs": [{ "number", "title", "mergedAt", "labels": [name],
//       "firstChecksConclusion": "success"|"failure"|null, "firstChecksAt": ISO|null,
//       "closingIssue": { "number", "readyAt": ISO|null, "reopened": bool } | null }],
//     "issues": [{ "number", "createdAt", "labels": [name] }] }
// --dispatches reads the worker dispatch log (issue<TAB>dispatched_at ISO, header first; the
// earliest row per issue counts). Stages per merged PR: queue is ready-for-agent to dispatch,
// build is dispatch to the first Checks result on the PR's first commit, merge is that result to
// merge. A PR is fully verified when all four timestamps exist and run in order.
import { readFileSync } from "node:fs";

export type Pr = {
  number: number;
  title: string;
  mergedAt: string;
  labels: string[];
  firstChecksConclusion: string | null;
  firstChecksAt?: string | null;
  closingIssue: { number: number; readyAt: string | null; reopened: boolean } | null;
};
export type Issue = { number: number; createdAt: string; labels: string[] };
export type Data = { now: string; prs: Pr[]; issues: Issue[] };

const UNKNOWN = "unknown";

// Nearest rank percentile, matching the report table.
export function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const s = [...values].sort((a, b) => a - b);
  return s[Math.max(0, Math.ceil(p * s.length) - 1)];
}

export function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const s = [...values].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

const num = (v: number | null): string => (v === null ? UNKNOWN : String(Math.round(v * 100) / 100));
const rate = (hit: number, total: number): string => (total === 0 ? UNKNOWN : num(hit / total));

export function computeMetrics(data: Data, days = 7, dispatches: Map<number, string> = new Map()): Record<string, string> {
  const now = Date.parse(data.now);
  const since = now - days * 86400000;
  const prs = data.prs.filter((p) => {
    const t = Date.parse(p.mergedAt);
    return t >= since && t <= now;
  });
  const out: Record<string, string> = {};

  const mins = prs.flatMap((p) => {
    const ready = p.closingIssue?.readyAt;
    if (!ready) return [];
    return [(Date.parse(p.mergedAt) - Date.parse(ready)) / 60000];
  });
  out.median_ticket_start_to_merge_minutes = num(median(mins));
  out.median_ticket_start_to_merge_minutes_n = String(mins.length);

  const checked = prs.filter((p) => p.firstChecksConclusion);
  const failed = checked.filter((p) => p.firstChecksConclusion === "failure").length;
  out.first_pass_checks_fail_rate = rate(failed, checked.length);
  out.first_pass_checks_fail_rate_n = String(checked.length);

  const month = new Date(now).toISOString().slice(0, 7);
  const filed = (label: string) =>
    data.issues.filter((i) => i.createdAt.startsWith(month) && i.labels.some((l) => l.toLowerCase() === label)).length;
  out.p0_filed_this_month = String(filed("p0"));
  out.p1_filed_this_month = String(filed("p1"));

  const bad = prs.filter(
    (p) => p.closingIssue?.reopened || /hotfix/i.test(p.title) || p.labels.some((l) => /hotfix/i.test(l)),
  ).length;
  out.reopened_or_hotfix_rate = rate(bad, prs.length);
  out.reopened_or_hotfix_rate_n = String(prs.length);

  const minutes = (from?: string | null, to?: string | null): number | null => {
    if (!from || !to) return null;
    const m = (Date.parse(to) - Date.parse(from)) / 60000;
    return Number.isFinite(m) && m >= 0 ? m : null;
  };
  const samples: Record<string, { v: number; verified: boolean }[]> = { queue: [], build: [], merge: [] };
  let verified = 0;
  for (const p of prs) {
    const ready = p.closingIssue?.readyAt;
    const dispatched = p.closingIssue ? dispatches.get(p.closingIssue.number) : undefined;
    const stage = {
      queue: minutes(ready, dispatched),
      build: minutes(dispatched, p.firstChecksAt),
      merge: minutes(p.firstChecksAt, p.mergedAt),
    };
    const full = stage.queue !== null && stage.build !== null && stage.merge !== null;
    if (full) verified++;
    for (const [k, v] of Object.entries(stage)) if (v !== null) samples[k].push({ v, verified: full });
  }
  out.stage_samples = String(prs.length);
  out.stage_samples_verified = String(verified);
  for (const stage of ["queue", "build", "merge"]) {
    const v = samples[stage].map((x) => x.v);
    out[`median_stage_${stage}_minutes`] = num(median(v));
    out[`median_stage_${stage}_minutes_n`] = String(v.length);
    out[`p75_stage_${stage}_minutes`] = num(percentile(v, 0.75));
    out[`max_stage_${stage}_minutes`] = num(v.length ? Math.max(...v) : null);
    out[`stage_${stage}_verified`] = String(samples[stage].filter((x) => x.verified).length);
  }
  return out;
}

// Rows are issue<TAB>dispatched_at, optionally followed by <TAB>owner/repo (legacy rows have no repo).
export function parseDispatches(text: string, repo?: string): Map<number, string> {
  const out = new Map<number, string>();
  for (const line of text.split("\n").slice(1)) {
    const [issue, at, rowRepo] = line.split("\t").map((x) => x?.trim());
    if (repo && rowRepo && rowRepo.toLowerCase() !== repo.toLowerCase()) continue;
    const n = Number(issue);
    if (!Number.isInteger(n) || !at || !Number.isFinite(Date.parse(at))) continue;
    const prev = out.get(n);
    if (!prev || Date.parse(at) < Date.parse(prev)) out.set(n, at);
  }
  return out;
}

function gh(args: string[]): unknown {
  const r = Bun.spawnSync(["gh", ...args]);
  if (r.exitCode !== 0) throw new Error(`gh ${args.join(" ")} failed: ${r.stderr.toString().trim()}`);
  return JSON.parse(r.stdout.toString() || "null");
}

const PR_QUERY = `query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) {
    nodes { ... on PullRequest {
      number title mergedAt
      labels(first: 10) { nodes { name } }
      commits(first: 1) { nodes { commit { checkSuites(first: 5, filterBy: { appId: 15368 }) { nodes {
        checkRuns(first: 20) { nodes { conclusion completedAt } } } } } } }
      closingIssuesReferences(first: 1) { nodes { number
        timelineItems(itemTypes: [LABELED_EVENT, REOPENED_EVENT], first: 20) { nodes {
          __typename ... on LabeledEvent { createdAt label { name } } } } } }
    } }
  }
}`;

type Run = { conclusion: string | null; completedAt: string | null };
type RawPr = {
  number: number;
  title: string;
  mergedAt: string;
  labels: { nodes: { name: string }[] };
  commits: { nodes: { commit: { checkSuites: { nodes: { checkRuns: { nodes: Run[] } }[] } } }[] };
  closingIssuesReferences: {
    nodes: { number: number; timelineItems: { nodes: { __typename: string; createdAt?: string; label?: { name: string } }[] } }[];
  };
};

export function toPr(p: RawPr): Pr {
  const runs = (p.commits.nodes[0]?.commit.checkSuites.nodes ?? []).flatMap((s) => s.checkRuns.nodes);
  const done = runs.filter((r) => r.conclusion && r.completedAt);
  const conclusion = done.length === 0 ? null : done.some((r) => r.conclusion === "FAILURE") ? "failure" : "success";
  const firstChecksAt = done.map((r) => r.completedAt as string).sort()[0] ?? null;
  const issue = p.closingIssuesReferences.nodes[0];
  const events = issue?.timelineItems.nodes ?? [];
  const ready = events.find((e) => e.__typename === "LabeledEvent" && e.label?.name === "ready-for-agent");
  return {
    number: p.number,
    title: p.title,
    mergedAt: p.mergedAt,
    labels: p.labels.nodes.map((l) => l.name),
    firstChecksConclusion: conclusion,
    firstChecksAt,
    closingIssue: issue
      ? { number: issue.number, readyAt: ready?.createdAt ?? null, reopened: events.some((e) => e.__typename === "ReopenedEvent") }
      : null,
  };
}

export function fetchData(repo: string, days: number): Data {
  const now = process.env.TEAM_AUDIT_NOW ? new Date(process.env.TEAM_AUDIT_NOW) : new Date(); // fixed clock for tests
  const since = new Date(now.getTime() - days * 86400000).toISOString().slice(0, 10);
  const monthStart = now.toISOString().slice(0, 7) + "-01";
  const res = gh([
    "api", "graphql", "-f", `query=${PR_QUERY}`, "-f", `q=repo:${repo} is:pr is:merged merged:>=${since}`,
  ]) as { data: { search: { nodes: RawPr[] } } };
  const prs = res.data.search.nodes.filter((p) => p && p.number).map(toPr);
  const issues = (gh([
    "issue", "list", "--repo", repo, "--state", "all", "--limit", "500",
    "--search", `created:>=${monthStart}`, "--json", "number,createdAt,labels",
  ]) as { number: number; createdAt: string; labels: { name: string }[] }[]).map((i) => ({
    number: i.number,
    createdAt: i.createdAt,
    labels: i.labels.map((l) => l.name),
  }));
  return { now: now.toISOString(), prs, issues };
}

function main(argv: string[]): number {
  const opt = (name: string): string | undefined => {
    const i = argv.indexOf(name);
    return i >= 0 ? argv[i + 1] : undefined;
  };
  const repo = opt("--repo");
  const fixture = opt("--fixture");
  const days = Number(opt("--days") ?? 7);
  if ((!repo && !fixture) || !Number.isFinite(days) || days <= 0) {
    console.error("usage: team-audit-metrics.ts --repo <owner/name> [--days <n>] [--json] [--dispatches <tsv>]");
    return 2;
  }
  try {
    const data = fixture ? (JSON.parse(readFileSync(fixture, "utf8")) as Data) : fetchData(repo as string, days);
    const log = opt("--dispatches");
    const metrics = computeMetrics(data, days, log ? parseDispatches(readFileSync(log, "utf8"), repo) : new Map());
    if (argv.includes("--json")) console.log(JSON.stringify(metrics, null, 2));
    else for (const [k, v] of Object.entries(metrics)) console.log(`${k}=${v}`);
    return 0;
  } catch (e) {
    console.error(`team-audit-metrics: ${(e as Error).message}`);
    return 1;
  }
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
