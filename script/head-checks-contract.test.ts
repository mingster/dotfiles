import { expect, test } from "bun:test";
import {
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dotfiles = join(import.meta.dir, "..");
const headChecks = join(dotfiles, "script/head-checks.sh");

function git(cwd: string, ...args: string[]) {
	const result = Bun.spawnSync(["git", "-C", cwd, ...args], {
		stdout: "pipe",
		stderr: "pipe",
	});
	if (result.exitCode !== 0) {
		throw new Error(
			`git ${args.join(" ")}: ${result.stderr.toString() || result.stdout.toString()}`,
		);
	}
	return result.stdout.toString().trim();
}

function parseTscDuration(receipt: string): number | null {
	const lines = receipt.split("\n");
	for (let i = 0; i < lines.length; i++) {
		if (!lines[i]?.includes("head-checks-tsc")) continue;
		for (let j = i + 1; j < lines.length; j++) {
			const match = lines[j]?.match(/^Duration: (\d+)s$/);
			if (match) return Number(match[1]);
			if (lines[j]?.startsWith("Command: ")) break;
		}
	}
	return null;
}

function fixture() {
	const root = mkdtempSync(join(tmpdir(), "head-checks-tsc-"));
	const home = join(root, "home");
	const repo = join(root, "fixture");
	const binpath = join(root, "bin");
	mkdirSync(home, { recursive: true });
	mkdirSync(binpath, { recursive: true });
	mkdirSync(join(repo, "src"), { recursive: true });

	const gh = join(binpath, "gh");
	writeFileSync(
		gh,
		`#!/usr/bin/env python3
import json, os, sys
if sys.argv[2] == "view":
    print(json.dumps({"headRefOid": os.environ["GH_HEAD"], "baseRefOid": os.environ["GH_BASE"]}))
elif sys.argv[2] == "comment":
    open(os.environ["COMMENTS"], "w").write(open(sys.argv[sys.argv.index("--body-file") + 1]).read())
else:
    sys.exit(1)
`,
	);
	Bun.spawnSync(["chmod", "+x", gh]);

	const gateReader = join(binpath, "reader");
	writeFileSync(
		gateReader,
		'#!/usr/bin/env bash\ncase "$1" in hardware) echo "12 8 1000000000";; model) echo fixture;; *) echo "0 90";; esac\n',
	);
	Bun.spawnSync(["chmod", "+x", gateReader]);

	git(repo, "init", "-q");
	git(repo, "config", "user.name", "Fixture");
	git(repo, "config", "user.email", "fixture@example.invalid");
	writeFileSync(
		join(repo, "tsconfig.json"),
		JSON.stringify({
			compilerOptions: {
				strict: true,
				noEmit: true,
				skipLibCheck: true,
			},
			include: ["src/**/*.ts"],
		}),
	);
	writeFileSync(
		join(repo, "package.json"),
		JSON.stringify({ devDependencies: { typescript: "5.8.3" } }),
	);
	writeFileSync(join(repo, "src", "ok.ts"), "export const value = 1;\n");
	mkdirSync(join(repo, ".agents"), { recursive: true });
	const tscCommand =
		"bun install --ignore-scripts\n" +
		'files=({files}); need=false; for f in ${files[@]+"${files[@]}"}; do case "$f" in *.ts) need=true ;; esac; done; ' +
		'[ "$need" = true ] || { echo Skipped; exit 0; }; ' +
		`bash "${join(dotfiles, "script/head-checks-tsc.sh")}"`;
	writeFileSync(join(repo, ".agents/head-checks.conf"), `${tscCommand}\n`);
	git(repo, "add", ".");
	git(repo, "commit", "-qm", "base");
	const base = git(repo, "rev-parse", "HEAD");
	git(repo, "update-ref", "refs/remotes/origin/main", base);

	return {
		root,
		home,
		repo,
		binpath,
		base,
		buildInfo: join(home, "orca/workspaces/fixture/tsc-_checks.tsbuildinfo"),
		worktree: join(home, "orca/workspaces/fixture/_checks"),
	};
}

function runHeadChecks(
	fix: ReturnType<typeof fixture>,
	head: string,
	comments: string,
) {
	const env = {
		...process.env,
		HOME: fix.home,
		PATH: `/usr/bin:${fix.binpath}:${process.env.PATH ?? ""}`,
		GH_BASE: fix.base,
		GH_HEAD: head,
		COMMENTS: comments,
		DOTFILES_DIR: dotfiles,
		HEAVY_GATE_READER: join(fix.binpath, "reader"),
		HEAVY_GATE_POLL_SECONDS: "0.02",
		HEAD_CHECKS_WAIT_SECONDS: "0",
		HEAD_CHECKS_GATE_HELD: "1",
		HEAD_CHECKS_SLOTS: "1",
		HEAD_CHECKS_LOG_DIR: join(fix.root, "logs"),
	};
	const result = Bun.spawnSync(
		["bash", headChecks, "--repo", fix.repo, "--ref", head, "--base", fix.base],
		{ env, stdout: "pipe", stderr: "pipe" },
	);
	const stdout = result.stdout.toString();
	const stderr = result.stderr.toString();
	const receipt = existsSync(comments) ? readFileSync(comments, "utf8") : stdout;
	return { code: result.exitCode, receipt, stdout, stderr };
}

test(
	"head-checks keeps incremental tsc build info outside the checkout",
	() => {
	const fix = fixture();
	const comments = join(fix.root, "comments");
	let coldDuration: number | null = null;
	let warmDuration: number | null = null;

	try {
		writeFileSync(join(fix.repo, "src", "changed.ts"), "export const n = 1;\n");
		git(fix.repo, "add", "src/changed.ts");
		git(fix.repo, "commit", "-qm", "add ts");
		const head = git(fix.repo, "rev-parse", "HEAD");

		rmSync(fix.buildInfo, { force: true });
		const cold = runHeadChecks(fix, head, comments);
		expect(cold.code).toBe(0);
		expect(existsSync(fix.buildInfo)).toBe(true);
		expect(existsSync(join(fix.worktree, "tsc.tsbuildinfo"))).toBe(false);
		coldDuration = parseTscDuration(cold.receipt);
		expect(coldDuration).not.toBeNull();

		const warm = runHeadChecks(fix, head, comments);
		expect(warm.code).toBe(0);
		expect(existsSync(fix.buildInfo)).toBe(true);
		warmDuration = parseTscDuration(warm.receipt);
		expect(warmDuration).not.toBeNull();

		writeFileSync(
			join(fix.repo, "src", "changed.ts"),
			"export const n: string = 1;\n",
		);
		git(fix.repo, "add", "src/changed.ts");
		git(fix.repo, "commit", "-qm", "type error");
		const badHead = git(fix.repo, "rev-parse", "HEAD");
		const bad = runHeadChecks(fix, badHead, comments);
		expect(bad.code).not.toBe(0);
		expect(existsSync(fix.buildInfo)).toBe(true);

		console.log(
			`tsc durations cold=${coldDuration}s warm=${warmDuration}s planted-error-exit=${bad.code}`,
		);
	} finally {
		rmSync(fix.root, { recursive: true, force: true });
	}
},
120_000,
);
