#!/usr/bin/env bun
// Weekly team audit metrics for one repository. One key=value line per metric on stdout.
// Missing data reads "unknown", never zero.
//
// Usage:
//   bun script/team-audit-metrics.ts --repo <owner/name> [--days <n>] [--json] [--times <stages.tsv>]
//   bun script/team-audit-metrics.ts --fixture <data.json> [--times <stages.tsv>] [--json]
//
// --fixture reads the data from a JSON file instead of GitHub (offline tests):
//   { "now": ISO, "prs": [{ "number", "title", "mergedAt", "labels": [name],
//       "firstChecksConclusion": "success"|"failure"|null,
//       "closingIssue": { "number", "readyAt": ISO|null, "reopened": bool } | null }],
//     "issues": [{ "number", "createdAt", "labels": [name] }] }
// --times reads the Orca stage samples (stage<TAB>minutes<TAB>verified, header first).
import { readFileSync } from "node:fs";

export type Pr = {
  number: number;
  title: string;
  mergedAt: string;
  labels: string[];
  firstChecksConclusion: string | null;
  closingIssue: { number: number; readyAt: string | null; reopened: boolean } | null;
};
export type Issue = { number: number; createdAt: string; labels: string[] };
export type Data = { now: string; prs: Pr[]; issues: Issue[] };

const UNKNOWN = "unknown";

export function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const s = [...values].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

const num = (v: number | null): string => (v === null ? UNKNOWN : String(Math.round(v * 100) / 100));
const rate = (hit: number, total: number): string => (total === 0 ? UNKNOWN : num(hit / total));

export function computeMetrics(data: Data, days = 7, stageRows: string[][] = []): Record<string, string> {
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

  for (const stage of ["queue", "build", "merge"]) {
    const v = stageRows.filter((r) => r[0] === stage).map((r) => Number(r[1])).filter((n) => Number.isFinite(n));
    out[`median_stage_${stage}_minutes`] = num(median(v));
    out[`median_stage_${stage}_minutes_n`] = String(v.length);
  }
  return out;
}

export function parseTimes(text: string): string[][] {
  return text
    .split("\n")
    .slice(1)
    .filter((l) => l.trim())
    .map((l) => l.split("\t"));
}

function gh(args: string[]): unknown {
  const r = Bun.spawnSync(["gh", ...args]);
  if (r.exitCode !== 0) throw new Error(`gh ${args.join(" ")} failed: ${r.stderr.toString().trim()}`);
  return JSON.parse(r.stdout.toString() || "null");
}

function tryGh(args: string[]): unknown {
  try {
    return gh(args);
  } catch {
    return null;
  }
}

type RawPr = {
  number: number;
  title: string;
  mergedAt: string;
  labels: { name: string }[];
  commits: { oid: string }[];
  closingIssuesReferences: { number: number }[];
};

export function fetchData(repo: string, days: number): Data {
  const now = new Date();
  const since = new Date(now.getTime() - days * 86400000).toISOString().slice(0, 10);
  const monthStart = now.toISOString().slice(0, 7) + "-01";
  const raw = gh([
    "pr", "list", "--repo", repo, "--state", "merged", "--limit", "200",
    "--search", `merged:>=${since}`,
    "--json", "number,title,mergedAt,labels,commits,closingIssuesReferences",
  ]) as RawPr[];
  const prs: Pr[] = raw.map((p) => {
    const first = p.commits[0]?.oid;
    const runs = first
      ? (tryGh(["api", `repos/${repo}/commits/${first}/check-runs`]) as { check_runs: { conclusion: string | null }[] } | null)
      : null;
    const done = runs?.check_runs.filter((c) => c.conclusion) ?? [];
    const conclusion = done.length === 0 ? null : done.some((c) => c.conclusion === "failure") ? "failure" : "success";
    const n = p.closingIssuesReferences[0]?.number;
    let closingIssue: Pr["closingIssue"] = null;
    if (n) {
      const events = (tryGh(["api", `repos/${repo}/issues/${n}/timeline`, "--paginate"]) as
        | { event: string; created_at?: string; label?: { name: string } }[]
        | null) ?? [];
      const ready = events.find((e) => e.event === "labeled" && e.label?.name === "ready-for-agent");
      closingIssue = {
        number: n,
        readyAt: ready?.created_at ?? null,
        reopened: events.some((e) => e.event === "reopened"),
      };
    }
    return {
      number: p.number,
      title: p.title,
      mergedAt: p.mergedAt,
      labels: p.labels.map((l) => l.name),
      firstChecksConclusion: conclusion,
      closingIssue,
    };
  });
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
    console.error("usage: team-audit-metrics.ts --repo <owner/name> [--days <n>] [--json] [--times <tsv>]");
    return 2;
  }
  try {
    const data = fixture ? (JSON.parse(readFileSync(fixture, "utf8")) as Data) : fetchData(repo as string, days);
    const times = opt("--times");
    const metrics = computeMetrics(data, days, times ? parseTimes(readFileSync(times, "utf8")) : []);
    if (argv.includes("--json")) console.log(JSON.stringify(metrics, null, 2));
    else for (const [k, v] of Object.entries(metrics)) console.log(`${k}=${v}`);
    return 0;
  } catch (e) {
    console.error(`team-audit-metrics: ${(e as Error).message}`);
    return 1;
  }
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
