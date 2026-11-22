#!/usr/bin/env bash
# User-level Cursor hook: gate `gh pr create` until the repo changelog includes a Recent Changes update.
# Config: <repo>/.cursor/changelog-hook.json (optional). Auto-detects Obsidian HOME.md vaults.
set -uo pipefail

HOOK_JSON_EMITTED=0
HOOK_EXIT_CODE=0

emit_allow() {
	jq -nc '{permission:"allow"}'
	HOOK_JSON_EMITTED=1
}

emit_deny() {
	local user_msg="$1"
	local agent_msg="$2"
	jq -nc \
		--arg user "$user_msg" \
		--arg agent "$agent_msg" \
		'{permission:"deny", user_message:$user, agent_message:$agent}'
	HOOK_JSON_EMITTED=1
	HOOK_EXIT_CODE=2
}

on_exit() {
	local code=$?
	if [[ "$HOOK_JSON_EMITTED" -eq 0 ]]; then
		emit_allow
	fi
	exit "${HOOK_EXIT_CODE:-$code}"
}
trap on_exit EXIT

if ! command -v jq >/dev/null 2>&1; then
	exit 0
fi

input="$(cat || true)"
if [[ -z "$input" ]]; then
	exit 0
fi

command=""
if ! command="$(jq -er '.command // ""' <<<"$input" 2>/dev/null)"; then
	exit 0
fi

# Only gate actual gh pr create invocations (not unrelated commands that mention the phrase).
# Must stay identical to the matcher in ide/cursor/hooks.json (the test enforces it).
GH_PR_CREATE_RE='(^|[[:space:];&|(])gh[[:space:]]+pr[[:space:]]+create([[:space:]);&|]|$)'
if [[ ! "$command" =~ $GH_PR_CREATE_RE ]]; then
	exit 0
fi

hook_cwd=""
hook_cwd="$(jq -er '.cwd // ""' <<<"$input" 2>/dev/null || true)"

resolve_repo_root() {
	local dir root
	for dir in "${CURSOR_PROJECT_DIR:-}" "$hook_cwd" "."; do
		[[ -z "$dir" ]] && continue
		if root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"; then
			echo "$root"
			return 0
		fi
	done
	pwd
}

REPO_ROOT="$(resolve_repo_root)"
cd "$REPO_ROOT" || exit 0

CONFIG_PATH=".cursor/changelog-hook.json"
BASE="${PR_BASE_BRANCH:-main}"
CHANGELOG_REL=""
RECENT_HEADING="## Recent Changes"
SHIP_PREFIXES=()
FRAGMENTS_DIR=""

load_config() {
	if [[ ! -f "$CONFIG_PATH" ]]; then
		return 1
	fi
	if ! CHANGELOG_REL="$(jq -er '.changelog // empty' "$CONFIG_PATH" 2>/dev/null)"; then
		return 1
	fi
	local heading
	heading="$(jq -r '.recentHeading // empty' "$CONFIG_PATH" 2>/dev/null || true)"
	if [[ -n "$heading" ]]; then
		RECENT_HEADING="$heading"
	fi
	local base
	base="$(jq -r '.base // empty' "$CONFIG_PATH" 2>/dev/null || true)"
	if [[ -n "$base" && -z "${PR_BASE_BRANCH:-}" ]]; then
		BASE="$base"
	fi
	FRAGMENTS_DIR="$(jq -r '.fragments // empty' "$CONFIG_PATH" 2>/dev/null || true)"
	if [[ -n "$FRAGMENTS_DIR" ]]; then
		FRAGMENTS_DIR="${FRAGMENTS_DIR%/}/"
	fi
	while IFS= read -r prefix; do
		[[ -n "$prefix" ]] && SHIP_PREFIXES+=("$prefix")
	done < <(jq -r '.shippablePrefixes[]? // empty' "$CONFIG_PATH" 2>/dev/null || true)
	[[ -n "$CHANGELOG_REL" && ${#SHIP_PREFIXES[@]} -gt 0 ]]
}

autodetect_config() {
	local candidate
	for candidate in fileServer/docs/HOME.md web/doc/HOME.md doc/HOME.md; do
		if [[ -f "$candidate" ]] && grep -qF "$RECENT_HEADING" "$candidate" 2>/dev/null; then
			CHANGELOG_REL="$candidate"
			SHIP_PREFIXES=(web/src/ web/bin/ web/prisma/ fileServer/docs/)
			return 0
		fi
	done
	return 1
}

if ! load_config; then
	if ! autodetect_config; then
		exit 0
	fi
fi

resolve_merge_base() {
	if git rev-parse --verify "origin/${BASE}" >/dev/null 2>&1; then
		echo "origin/${BASE}"
	elif git rev-parse --verify "${BASE}" >/dev/null 2>&1; then
		echo "${BASE}"
	else
		echo ""
	fi
}

MERGE_BASE="$(resolve_merge_base)"
if [[ -z "$MERGE_BASE" ]]; then
	exit 0
fi

collect_changed_files() {
	{
		git diff --name-only "${MERGE_BASE}...HEAD" 2>/dev/null || true
		git diff --name-only 2>/dev/null || true
		git diff --cached --name-only 2>/dev/null || true
	} | sed '/^$/d' | sort -u
}

matches_prefix() {
	local file="$1"
	local prefix
	for prefix in "${SHIP_PREFIXES[@]}"; do
		case "$file" in
			"${prefix}"*) return 0 ;;
		esac
	done
	return 1
}

needs_changelog=false
has_changelog=false

while IFS= read -r file; do
	[[ -z "$file" ]] && continue
	if [[ "$file" == "$CHANGELOG_REL" ]]; then
		has_changelog=true
	fi
	# A new fragment under the fragments dir counts like a changelog edit (README is never a fragment).
	if [[ -n "$FRAGMENTS_DIR" && "$file" == "$FRAGMENTS_DIR"* && "$file" != "${FRAGMENTS_DIR}README.md" ]]; then
		has_changelog=true
	fi
	if matches_prefix "$file"; then
		needs_changelog=true
	fi
done < <(collect_changed_files)

# Zero-Env Disclosure Gate: inspect only the lines this PR adds to markdown, json and yaml files.
added_lines() {
	local file="$1"
	{
		git diff -U0 "${MERGE_BASE}...HEAD" -- "$file" 2>/dev/null || true
		git diff -U0 -- "$file" 2>/dev/null || true
		git diff -U0 --cached -- "$file" 2>/dev/null || true
	} | awk '/^\+\+\+ /{next} /^\+/{print substr($0,2)}'
}

# A documented placeholder password is not a secret.
is_placeholder_password() {
	case "$1" in
		password | changeme | "<"*">" | '${'*'}' | "[Omitted/Configured via Env]") return 0 ;;
	esac
	return 1
}

has_raw_secret() {
	local text="$1" url
	if grep -E -q '(sk_live_[0-9a-zA-Z]{24,}|LINE_PAY_SECRET=[0-9a-zA-Z]{16,})' <<<"$text"; then
		return 0
	fi
	local url_re='^postgres(ql)?://([^:]+):([^@]+)@[^/]+'
	while IFS= read -r url; do
		[[ -z "$url" ]] && continue
		if [[ "$url" =~ $url_re ]] && ! is_placeholder_password "${BASH_REMATCH[3]}"; then
			return 0
		fi
	done < <(grep -E -o 'postgres(ql)?://[^:[:space:]]+:[^@[:space:]]+@[^/[:space:]]+' <<<"$text")
	return 1
}

while IFS= read -r file; do
	[[ -z "$file" ]] && continue
	if [[ "$file" =~ \.(md|mdx|json|ya?ml)$ ]] && [[ -f "$file" ]]; then
		if has_raw_secret "$(added_lines "$file")"; then
			emit_deny \
				"Zero-Env Disclosure violation in ${file}." \
				"Found raw secret or credential in ${file}. Replace with [Omitted/Configured via Env] before opening PR (Lean Startup SDLC Guardrail)."
			exit 2
		fi
	fi
done < <(collect_changed_files)

if [[ "$needs_changelog" == true && "$has_changelog" == false && -n "$FRAGMENTS_DIR" ]]; then
	emit_deny \
		"Add a changelog fragment under ${FRAGMENTS_DIR} before opening this PR." \
		"Add one new file ${FRAGMENTS_DIR}<issue>-<slug>.md (or <branch-slug>.md with no issue) holding only the entry line(s) in the ${CHANGELOG_REL} format. Do not edit ${CHANGELOG_REL}. Commit, then run gh pr create again."
	exit 2
fi

if [[ "$needs_changelog" == true && "$has_changelog" == false ]]; then
	PREPEND="${DOTFILES:-$HOME/dotfiles}/script/prepend-recent-change.ts"
	emit_deny \
		"Update ${CHANGELOG_REL} (${RECENT_HEADING}) before opening this PR." \
		"Prepend one line under ${RECENT_HEADING} in ${CHANGELOG_REL}, commit, then run gh pr create again. Helper: bun ${PREPEND} --link NOTE --label Label --summary \"...\" (repo root)."
	exit 2
fi

exit 0

