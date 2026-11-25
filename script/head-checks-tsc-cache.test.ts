import { expect, test } from "bun:test";
import {
	existsSync,
	mkdirSync,
	mkdtempSync,
	readdirSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const tscScript = join(import.meta.dir, "head-checks-tsc.sh");

// A fake bun stands in for tsc: it logs the build info it was handed, then writes a new one.
function setup() {
	const root = mkdtempSync(join(tmpdir(), "tsc-cache-"));
	const bin = join(root, "bin");
	mkdirSync(bin);
	const fakeBun = join(bin, "bun");
	writeFileSync(
		fakeBun,
		`#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = --tsBuildInfoFile ] && f=$2; shift; done
printf '%s|%s\\n' "$(basename "$PWD")" "$( [ -f "$f" ] && cat "$f" || echo none )" >> "$FAKE_LOG"
printf 'info-from-%s-%s' "$(basename "$PWD")" "$RANDOM" > "$f"
[ -z "\${FAKE_HANG:-}" ] || { sleep 300 & echo $! > "$FAKE_CHILD"; sleep 300; }
[ -z "\${FAKE_FAIL:-}" ] || exit 2
`,
		{ mode: 0o755 },
	);
	const cache = join(root, "cache");
	const log = join(root, "log");
	const tree = (name: string, lock = "lock-v1") => {
		const dir = join(root, name);
		mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, "bun.lock"), lock);
		writeFileSync(join(dir, "tsconfig.json"), "{}");
		return dir;
	};
	const run = (dir: string, extra: Record<string, string> = {}) =>
		Bun.spawn(["bash", tscScript], {
			cwd: dir,
			env: {
				...process.env,
				PATH: `${bin}:${process.env.PATH ?? ""}`,
				HEAD_CHECKS_TSC_CACHE_DIR: cache,
				FAKE_LOG: log,
				...extra,
			},
			stdout: "pipe",
			stderr: "pipe",
		});
	const lines = () =>
		existsSync(log) ? readFileSync(log, "utf8").trim().split("\n") : [];
	const entries = () => (existsSync(cache) ? readdirSync(cache).sort() : []);
	return { root, cache, tree, run, lines, entries };
}

test("a second worktree starts from the shared cache (hit)", async () => {
	const t = setup();
	try {
		const a = t.tree("wt-a");
		const b = t.tree("wt-b");
		expect(await t.run(a).exited).toBe(0);
		expect(await t.run(b).exited).toBe(0);
		const [first, second] = t.lines();
		expect(first).toBe("wt-a|none");
		expect(second).toMatch(/^wt-b\|info-from-wt-a-/);
		expect(t.entries()).toHaveLength(1);
	} finally {
		rmSync(t.root, { recursive: true, force: true });
	}
});

test("a changed lockfile or tsconfig runs full and replaces the cache", async () => {
	const t = setup();
	try {
		const a = t.tree("wt-a");
		await t.run(a).exited;
		const before = t.entries();
		const b = t.tree("wt-b", "lock-v2");
		await t.run(b).exited;
		expect(t.lines()[1]).toBe("wt-b|none");
		const after = t.entries();
		expect(after).toHaveLength(1);
		expect(after).not.toEqual(before);
		writeFileSync(join(b, "tsconfig.json"), '{"strict":true}');
		await t.run(b).exited;
		expect(t.lines()[2]).toBe("wt-b|none");
		expect(t.entries()).toHaveLength(1);
	} finally {
		rmSync(t.root, { recursive: true, force: true });
	}
});

test("runs at once leave one whole cache file and no temp files", async () => {
	const t = setup();
	try {
		const trees = ["a", "b", "c", "d", "e", "f"].map((n) => t.tree(`wt-${n}`));
		const procs = trees.map((d) => t.run(d));
		const codes = await Promise.all(procs.map((p) => p.exited));
		expect(codes.every((c) => c === 0)).toBe(true);
		const files = t.entries();
		expect(files).toHaveLength(1);
		expect(files[0]).toMatch(/^[0-9a-f]{16}\.tsbuildinfo$/);
		expect(readFileSync(join(t.cache, files[0] as string), "utf8")).toMatch(
			/^info-from-wt-[a-f]-\d+$/,
		);
	} finally {
		rmSync(t.root, { recursive: true, force: true });
	}
});

function alive(pid: number) {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

test("a tsc run past HEAD_CHECKS_TSC_TIMEOUT_SECONDS is stopped with its children and leaves the cache alone", async () => {
	const t = setup();
	try {
		const a = t.tree("wt-a");
		expect(await t.run(a).exited).toBe(0);
		const before = new Map(
			t.entries().map((n) => [n, readFileSync(join(t.cache, n), "utf8")]),
		);
		const childFile = join(t.root, "child.pid");
		const proc = t.run(a, {
			HEAD_CHECKS_TSC_TIMEOUT_SECONDS: "1",
			FAKE_HANG: "1",
			FAKE_CHILD: childFile,
		});
		const started = Date.now();
		const [code, stderr] = await Promise.all([
			proc.exited,
			new Response(proc.stderr).text(),
		]);
		expect(Date.now() - started).toBeLessThan(10_000);
		expect(code).toBe(124);
		expect(stderr).toContain("HEAD_CHECKS_TSC_TIMEOUT_SECONDS=1");
		const after = new Map(
			t.entries().map((n) => [n, readFileSync(join(t.cache, n), "utf8")]),
		);
		expect(after).toEqual(before);
		const child = Number(readFileSync(childFile, "utf8").trim());
		for (let i = 0; i < 20 && alive(child); i++) {
			await Bun.sleep(100);
		}
		expect(alive(child)).toBe(false);
	} finally {
		rmSync(t.root, { recursive: true, force: true });
	}
}, 20_000);

test("a failing tsc still exits non-zero and keeps the cache", async () => {
	const t = setup();
	try {
		const code = await t.run(t.tree("wt-a"), { FAKE_FAIL: "1" }).exited;
		expect(code).toBe(2);
		expect(t.entries()).toHaveLength(1);
	} finally {
		rmSync(t.root, { recursive: true, force: true });
	}
});
