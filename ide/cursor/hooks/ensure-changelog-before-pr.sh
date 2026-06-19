#!/usr/bin/env bash
# User-level Cursor hook: gate `gh pr create` until the repo changelog includes a Recent Changes update.
# Config: <repo>/.cursor/changelog-hook.json (optional). Auto-detects Obsidian HOME.md vaults.
set -euo pipefail

input=$(cat)
command=$(echo "$input" | jq -r '.command // empty')

if [[ ! "$command" =~ gh[[:space:]]+pr[[:space:]]+create ]]; then
	echo '{ "permission": "allow" }'
	exit 0
fi

REPO_ROOT="$(git -C "${CURSOR_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

CONFIG_PATH=".cursor/changelog-hook.json"
BASE="${PR_BASE_BRANCH:-main}"
CHANGELOG_REL=""
RECENT_HEADING="## Recent Changes"
SHIP_PREFIXES=()

load_config() {
	if [[ ! -f "$CONFIG_PATH" ]]; then
		return 1
	fi
	CHANGELOG_REL="$(jq -r '.changelog // empty' "$CONFIG_PATH")"
	local heading
	heading="$(jq -r '.recentHeading // empty' "$CONFIG_PATH")"
	if [[ -n "$heading" ]]; then
		RECENT_HEADING="$heading"
	fi
	while IFS= read -r prefix; do
		[[ -n "$prefix" ]] && SHIP_PREFIXES+=("$prefix")
	done < <(jq -r '.shippablePrefixes[]? // empty' "$CONFIG_PATH")
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
		echo '{ "permission": "allow" }'
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
	echo '{ "permission": "allow" }'
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
	jq -cn \
		--arg user "Update ${CHANGELOG_REL} (${RECENT_HEADING}) before opening this PR." \
		--arg agent "Prepend one line under ${RECENT_HEADING} in ${CHANGELOG_REL}, commit, then run gh pr create again. Helper: bun ${PREPEND} --link NOTE --label Label --summary \"...\" (repo root)." \
		'{ permission: "deny", user_message: $user, agent_message: $agent }'
	exit 0
fi

echo '{ "permission": "allow" }'
exit 0
