#!/usr/bin/env bun
/**
 * Prepend one line to a vault HOME.md ## Recent Changes section.
 *
 * Reads `<repo>/.cursor/changelog-hook.json` when present (changelog path + heading).
 *
 * Usage (from repo root):
 *   bun ~/dotfiles/script/prepend-recent-change.ts --link NOTE --label Label --summary "one line"
 *   bun ~/dotfiles/script/prepend-recent-change.ts --changelog fileServer/docs/HOME.md --link NOTE --label Label --summary "..."
 */
import { statSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const RECENT_HEADING_DEFAULT = "## Recent Changes";
const MAX_LINES = 10;
const CONFIG_PATH = ".cursor/changelog-hook.json";

interface HookConfig {
	changelog?: string;
	recentHeading?: string;
}

interface Args {
	changelog?: string;
	link: string;
	label: string;
	summary: string;
	date: string;
	recentHeading: string;
}

function findRepoRoot(start: string): string {
	let dir = path.resolve(start);
	for (let i = 0; i < 12; i += 1) {
		if (path.basename(dir) === ".git") {
			return path.dirname(dir);
		}
		const gitDir = path.join(dir, ".git");
		try {
			statSync(gitDir);
			return dir;
		} catch {
			// continue
		}
		const parent = path.dirname(dir);
		if (parent === dir) break;
		dir = parent;
	}
	return process.cwd();
}

async function loadHookConfig(repoRoot: string): Promise<HookConfig> {
	const configPath = path.join(repoRoot, CONFIG_PATH);
	try {
		const raw = await readFile(configPath, "utf8");
		return JSON.parse(raw) as HookConfig;
	} catch {
		return {};
	}
}

async function resolveChangelogPath(
	repoRoot: string,
	explicit?: string,
): Promise<string | null> {
	if (explicit) {
		return path.isAbsolute(explicit)
			? explicit
			: path.join(repoRoot, explicit);
	}
	const config = await loadHookConfig(repoRoot);
	if (config.changelog) {
		return path.join(repoRoot, config.changelog);
	}
	const candidates = [
		"fileServer/docs/HOME.md",
		"web/doc/HOME.md",
		"doc/HOME.md",
	];
	for (const rel of candidates) {
		const full = path.join(repoRoot, rel);
		try {
			const content = await readFile(full, "utf8");
			const heading = config.recentHeading ?? RECENT_HEADING_DEFAULT;
			if (content.includes(heading)) {
				return full;
			}
		} catch {
			// try next
		}
	}
	return null;
}

function parseArgs(argv: string[]): Omit<Args, "recentHeading"> & {
	recentHeading?: string;
} {
	const get = (flag: string): string | undefined => {
		const i = argv.indexOf(flag);
		if (i === -1 || i + 1 >= argv.length) return undefined;
		return argv[i + 1];
	};

	const link = get("--link");
	const label = get("--label");
	const summary = get("--summary");
	if (!link || !label || !summary) {
		console.error(
			'Usage: bun prepend-recent-change.ts --link NOTE --label Label --summary "one line" [--changelog path] [--date YYYY-MM-DD]',
		);
		process.exit(1);
	}

	return {
		changelog: get("--changelog"),
		link,
		label,
		summary,
		date: get("--date") ?? new Date().toISOString().slice(0, 10),
		recentHeading: get("--recent-heading"),
	};
}

function normalizeLink(link: string, changelogPath: string): string {
	const docsRoot = changelogPath.includes(`${path.sep}fileServer${path.sep}docs${path.sep}`)
		? "fileServer/docs/"
		: changelogPath.includes(`${path.sep}web${path.sep}doc${path.sep}`)
			? "web/doc/"
			: changelogPath.includes(`${path.sep}doc${path.sep}`)
				? "doc/"
				: "";
	let note = link.replace(/\.md$/i, "");
	if (docsRoot && note.startsWith(docsRoot)) {
		note = note.slice(docsRoot.length);
	}
	return note;
}

function buildLine(
	args: Pick<Args, "link" | "label" | "summary" | "date">,
	changelogPath: string,
): string {
	const note = normalizeLink(args.link, changelogPath);
	return `- ${args.date} — [[${note}|${args.label}]] — ${args.summary}`;
}

async function main(): Promise<void> {
	const repoRoot = findRepoRoot(process.cwd());
	const parsed = parseArgs(process.argv.slice(2));
	const config = await loadHookConfig(repoRoot);
	const recentHeading =
		parsed.recentHeading ??
		config.recentHeading ??
		RECENT_HEADING_DEFAULT;
	const changelogPath = await resolveChangelogPath(
		repoRoot,
		parsed.changelog,
	);

	if (!changelogPath) {
		console.error(
			`Could not find changelog (set --changelog or ${CONFIG_PATH}). Run from a git repo root.`,
		);
		process.exit(1);
	}

	const line = buildLine(parsed, changelogPath);
	const content = await readFile(changelogPath, "utf8");
	const headingIndex = content.indexOf(recentHeading);

	if (headingIndex === -1) {
		console.error(`Missing "${recentHeading}" in ${changelogPath}`);
		process.exit(1);
	}

	const afterHeading = headingIndex + recentHeading.length;
	const rest = content.slice(afterHeading);
	const bodyStart =
		afterHeading +
		(rest.startsWith("\r\n") ? 2 : rest.startsWith("\n") ? 1 : 0);

	const existingBlock = content.slice(bodyStart);
	const existingLines = existingBlock.split(/\r?\n/);
	const bulletLines: string[] = [];
	const tailLines: string[] = [];
	let inBullets = true;

	for (const raw of existingLines) {
		const trimmed = raw.trim();
		if (inBullets && trimmed.startsWith("- ")) {
			bulletLines.push(raw);
			continue;
		}
		if (inBullets && trimmed === "") {
			continue;
		}
		inBullets = false;
		tailLines.push(raw);
	}

	if (bulletLines.some((l) => l.trim() === line.trim())) {
		console.log("Recent Changes already contains this line; no change.");
		return;
	}

	const nextBullets = [line, ...bulletLines].slice(0, MAX_LINES);
	const prefix = content.slice(0, bodyStart);
	const rebuilt =
		prefix +
		nextBullets.join("\n") +
		"\n\n" +
		tailLines.join("\n").replace(/^\n+/, "");

	await writeFile(
		changelogPath,
		rebuilt.endsWith("\n") ? rebuilt : `${rebuilt}\n`,
		"utf8",
	);
	const rel = path.relative(repoRoot, changelogPath);
	console.log(`Prepended to ${rel}:`);
	console.log(line);
}

main().catch((err: unknown) => {
	console.error(err instanceof Error ? err.message : String(err));
	process.exit(1);
});
