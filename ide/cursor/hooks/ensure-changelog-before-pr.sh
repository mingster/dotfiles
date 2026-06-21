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
if [[ ! "$command" =~ (^|[[:space:];]|&&[[:space:]]*)gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]; then
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
	if matches_prefix "$file"; then
		needs_changelog=true
	fi
done < <(collect_changed_files)

if [[ "$needs_changelog" == true && "$has_changelog" == false ]]; then
	PREPEND="${DOTFILES:-$HOME/dotfiles}/script/prepend-recent-change.ts"
	emit_deny \
		"Update ${CHANGELOG_REL} (${RECENT_HEADING}) before opening this PR." \
		"Prepend one line under ${RECENT_HEADING} in ${CHANGELOG_REL}, commit, then run gh pr create again. Helper: bun ${PREPEND} --link NOTE --label Label --summary \"...\" (repo root)."
	exit 2
fi

exit 0
