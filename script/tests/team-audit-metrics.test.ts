// Offline tests for script/team-audit-metrics.ts. No network, no gh.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { computeMetrics, median, parseDispatches, percentile, toPr, type Data } from "../team-audit-metrics";

const dir = import.meta.dir;
const script = join(dir, "..", "team-audit-metrics.ts");
const fixture = join(dir, "fixtures", "team-audit-metrics.json");
const dispatchLog = join(dir, "fixtures", "team-audit-dispatches.tsv");
const dispatches = parseDispatches(readFileSync(dispatchLog, "utf8"));
const data = JSON.parse(readFileSync(fixture, "utf8")) as Data;

test("median handles empty, odd and even", () => {
  expect(median([])).toBeNull();
  expect(median([3, 1, 2])).toBe(2);
  expect(median([1, 2, 3, 4])).toBe(2.5);
  expect(percentile([20, 60, 120], 0.75)).toBe(120);
  expect(percentile([10, 30], 0.75)).toBe(30);
});

test("dispatch log keeps the earliest valid row per issue", () => {
  expect(dispatches.get(10)).toBe("2026-11-08T11:10:00Z");
  expect(dispatches.get(11)).toBe("2026-11-07T08:30:00Z");
  expect(dispatches.has(99)).toBe(false);
});

test("dispatch log filters by repo and still accepts legacy two column rows", () => {
  const tsv = [
    "issue\tdispatched_at\trepo",
    "10\t2026-11-08T11:10:00Z\tmingster/dotfiles",
    "10\t2026-11-01T00:00:00Z\tmingster/project-a",
    "12\t2026-11-02T00:00:00Z\tMingster/Project-A",
    "13\t2026-11-03T00:00:00Z",
  ].join("\n");
  const dot = parseDispatches(tsv, "mingster/dotfiles");
  expect(dot.get(10)).toBe("2026-11-08T11:10:00Z");
  expect(dot.has(12)).toBe(false);
  expect(dot.get(13)).toBe("2026-11-03T00:00:00Z");
  const pa = parseDispatches(tsv, "mingster/project-a");
  expect(pa.get(10)).toBe("2026-11-01T00:00:00Z");
  expect(pa.get(12)).toBe("2026-11-02T00:00:00Z");
  expect(parseDispatches(tsv).get(10)).toBe("2026-11-01T00:00:00Z");
});

test("delivery metrics over the 7 day window", () => {
  const m = computeMetrics(data, 7, dispatches);
  expect(m.median_ticket_start_to_merge_minutes).toBe("150"); // 60 and 240 minutes
  expect(m.median_ticket_start_to_merge_minutes_n).toBe("2");
  expect(m.first_pass_checks_fail_rate).toBe("0.33");
  expect(m.first_pass_checks_fail_rate_n).toBe("3");
  expect(m.p0_filed_this_month).toBe("1");
  expect(m.p1_filed_this_month).toBe("2");
  expect(m.reopened_or_hotfix_rate).toBe("0.67");
  expect(m.reopened_or_hotfix_rate_n).toBe("3");
});

test("stage times run from dispatch to the first Checks result", () => {
  const m = computeMetrics(data, 7, dispatches);
  expect(m.stage_samples).toBe("3");
  expect(m.stage_samples_verified).toBe("2"); // the PR without a closing issue has no dispatch
  expect([m.median_stage_queue_minutes, m.p75_stage_queue_minutes, m.max_stage_queue_minutes]).toEqual(["20", "30", "30"]);
  expect([m.median_stage_build_minutes, m.p75_stage_build_minutes, m.max_stage_build_minutes]).toEqual(["60", "90", "90"]);
  expect(m.median_stage_build_minutes_n).toBe("2");
  expect([m.median_stage_merge_minutes, m.p75_stage_merge_minutes, m.max_stage_merge_minutes]).toEqual(["60", "120", "120"]);
  expect(m.median_stage_merge_minutes_n).toBe("3");
  expect(m.stage_merge_verified).toBe("2");
});

test("without a dispatch log build reads unknown", () => {
  const m = computeMetrics(data, 7);
  expect(m.median_stage_build_minutes).toBe("unknown");
  expect(m.stage_samples_verified).toBe("0");
});

test("GraphQL nodes map to the fixture shape", () => {
  const raw = JSON.parse(readFileSync(join(dir, "fixtures", "team-audit-graphql.json"), "utf8"));
  const prs = raw.data.search.nodes.filter((p: { number?: number }) => p.number).map(toPr);
  expect(prs).toEqual(data.prs);
});

test("missing data reads unknown, never zero", () => {
  const m = computeMetrics({ now: data.now, prs: [], issues: [] }, 7);
  expect(m.median_ticket_start_to_merge_minutes).toBe("unknown");
  expect(m.first_pass_checks_fail_rate).toBe("unknown");
  expect(m.reopened_or_hotfix_rate).toBe("unknown");
  expect(m.median_stage_queue_minutes).toBe("unknown");
  expect(m.p0_filed_this_month).toBe("0");
});

test("cli prints key=value lines from a fixture", () => {
  const r = Bun.spawnSync(["bun", script, "--fixture", fixture, "--dispatches", dispatchLog]);
  expect(r.exitCode).toBe(0);
  const out = r.stdout.toString();
  expect(out).toContain("first_pass_checks_fail_rate=0.33\n");
  expect(out).toContain("p1_filed_this_month=2\n");
  expect(out).toContain("median_stage_build_minutes=60\n");
});

test("cli --json prints an object", () => {
  const r = Bun.spawnSync(["bun", script, "--fixture", fixture, "--json"]);
  expect(JSON.parse(r.stdout.toString()).p0_filed_this_month).toBe("1");
});

test("cli without --repo or --fixture is a usage error", () => {
  const r = Bun.spawnSync(["bun", script]);
  expect(r.exitCode).toBe(2);
});
