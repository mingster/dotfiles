// Offline tests for script/team-audit-metrics.ts. No network, no gh.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { computeMetrics, median, parseTimes, type Data } from "../team-audit-metrics";

const dir = import.meta.dir;
const script = join(dir, "..", "team-audit-metrics.ts");
const fixture = join(dir, "fixtures", "team-audit-metrics.json");
const times = join(dir, "fixtures", "team-audit-stages.tsv");
const data = JSON.parse(readFileSync(fixture, "utf8")) as Data;

test("median handles empty, odd and even", () => {
  expect(median([])).toBeNull();
  expect(median([3, 1, 2])).toBe(2);
  expect(median([1, 2, 3, 4])).toBe(2.5);
});

test("delivery metrics over the 7 day window", () => {
  const m = computeMetrics(data, 7, parseTimes(readFileSync(times, "utf8")));
  expect(m.median_ticket_start_to_merge_minutes).toBe("150"); // 60 and 240 minutes
  expect(m.median_ticket_start_to_merge_minutes_n).toBe("2");
  expect(m.first_pass_checks_fail_rate).toBe("0.33");
  expect(m.first_pass_checks_fail_rate_n).toBe("3");
  expect(m.p0_filed_this_month).toBe("1");
  expect(m.p1_filed_this_month).toBe("2");
  expect(m.reopened_or_hotfix_rate).toBe("0.67");
  expect(m.reopened_or_hotfix_rate_n).toBe("3");
  expect(m.median_stage_queue_minutes).toBe("6");
  expect(m.median_stage_build_minutes).toBe("20");
  expect(m.median_stage_merge_minutes).toBe("unknown");
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
  const r = Bun.spawnSync(["bun", script, "--fixture", fixture, "--times", times]);
  expect(r.exitCode).toBe(0);
  const out = r.stdout.toString();
  expect(out).toContain("first_pass_checks_fail_rate=0.33\n");
  expect(out).toContain("p1_filed_this_month=2\n");
});

test("cli --json prints an object", () => {
  const r = Bun.spawnSync(["bun", script, "--fixture", fixture, "--json"]);
  expect(JSON.parse(r.stdout.toString()).p0_filed_this_month).toBe("1");
});

test("cli without --repo or --fixture is a usage error", () => {
  const r = Bun.spawnSync(["bun", script]);
  expect(r.exitCode).toBe(2);
});
