#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.
#
# Updates nanvix-version in .nanvix/nanvix.toml, runs preflight via
# `./z resolve --shallow`, and either:
#
#   - commits + opens a PR (on successful preflight), or
#   - records retry state and exits 0 (on EXIT_MISSING_DEP / 3), or
#   - bubbles up the error (on any other failure).
#
# Retry state is persisted as a repository variable PREFLIGHT_RETRY_STATE
# (JSON-encoded). The companion `preflight-retry-dispatcher.yml` workflow
# in nanvix/workflows fires hourly and re-dispatches consumers whose
# next_attempt_unix has passed. After MAX_RETRIES consecutive skips an
# issue is opened in the consumer repo and state is cleared.
#
# Required environment:
#   GH_TOKEN        — GitHub token with contents + pull-requests + actions write.
#   LATEST_VERSION  — Version string to pin (e.g. 0.12.337).
#   LATEST_TAG      — Full release tag (e.g. v0.12.337).
#   REPO            — Owner/repo slug (e.g. nanvix/foo).
#
# Optional environment:
#   MAX_RETRIES           — Cap on retry attempts before opening an issue (default 3).
#   BACKOFF_BASE_SECONDS  — Initial backoff window in seconds (default 3600).

set -euo pipefail

TOML=".nanvix/nanvix.toml"
BRANCH="automation/update-nanvix-version"
COMMIT_MSG="[ci] E: Pin nanvix to ${LATEST_TAG}"

MAX_RETRIES="${MAX_RETRIES:-3}"
BACKOFF_BASE_SECONDS="${BACKOFF_BASE_SECONDS:-3600}"
STATE_VAR="PREFLIGHT_RETRY_STATE"
ISSUE_LABEL="ci-failure"

# --- retry-state helpers ----------------------------------------------------

read_retry_state() {
	gh variable get "$STATE_VAR" --repo "$REPO" 2>/dev/null || echo ""
}

write_retry_state() {
	local json="$1"
	gh variable set "$STATE_VAR" --repo "$REPO" --body "$json"
}

clear_retry_state() {
	gh variable delete "$STATE_VAR" --repo "$REPO" 2>/dev/null || true
}

open_stuck_issue() {
	local count="$1"
	local title="[ci] Cannot pin nanvix to ${LATEST_TAG}: preflight failing after ${count} attempts"

	local existing
	existing=$(gh issue list \
		--repo "$REPO" \
		--state open \
		--search "in:title \"${title}\"" \
		--json number \
		--jq '.[0].number // empty' 2>/dev/null || true)
	if [ -n "$existing" ]; then
		echo "::notice::Issue #${existing} already open for this version; not re-creating."
		return
	fi

	local body run_url
	run_url="https://github.com/${REPO}/actions/runs/${GITHUB_RUN_ID:-unknown}"
	body=$(cat <<EOF
The automated nanvix-version bump to [\`${LATEST_TAG}\`](https://github.com/nanvix/nanvix/releases/tag/${LATEST_TAG}) has failed preflight resolution **${count} times in a row**, exhausting the retry budget.

This usually means one or more upstream Nanvix dependency releases have not been published yet for this nanvix version, and the retries did not catch them in time.

**What to investigate:**

1. Open the most recent [failing run](${run_url}) and scroll to the \`./z resolve --shallow\` step. It will list the missing \`*-nanvix-${LATEST_VERSION}\` tag(s).
2. Verify the corresponding upstream repos have published those tags. If not, that's the upstream blocker.
3. Once the missing tags exist, manually re-run \`Nanvix CI\` (\`workflow_dispatch\`) on this repo, or wait for tomorrow's scheduled cron.

This issue was opened automatically by the preflight retry mechanism and will not auto-close. Close it manually once the pin lands successfully.
EOF
)
	if ! gh issue create \
		--repo "$REPO" \
		--title "$title" \
		--body "$body" \
		--label "$ISSUE_LABEL" 2>/dev/null; then
		# Label may not exist yet in this repo — retry unlabelled.
		echo "::warning::Could not apply label '${ISSUE_LABEL}' (does it exist in ${REPO}?); opening unlabelled."
		gh issue create \
			--repo "$REPO" \
			--title "$title" \
			--body "$body" || \
			echo "::error::Failed to open stuck-preflight issue in ${REPO}"
	fi
}

record_skip() {
	local now state count first next backoff new_state
	now=$(date -u +%s)
	state=$(read_retry_state)

	# Reset counter on a new nanvix version; otherwise increment.
	if [ -n "$state" ] && [ "$(echo "$state" | jq -r '.version // empty')" = "$LATEST_VERSION" ]; then
		count=$(echo "$state" | jq -r '.count // 0')
		first=$(echo "$state" | jq -r '.first_attempt_unix // 0')
		count=$((count + 1))
	else
		count=1
		first="$now"
	fi

	if [ "$count" -gt "$MAX_RETRIES" ]; then
		echo "::warning::Preflight skipped ${count} times for v${LATEST_VERSION}; exhausted MAX_RETRIES=${MAX_RETRIES}, opening tracking issue."
		open_stuck_issue "$count"
		clear_retry_state
		return
	fi

	# Exponential backoff: BACKOFF_BASE_SECONDS * 2^(count-1)
	#   count=1 → 1h, count=2 → 2h, count=3 → 4h (with default base).
	backoff=$(( BACKOFF_BASE_SECONDS * (1 << (count - 1)) ))
	next=$((now + backoff))

	new_state=$(jq -nc \
		--arg ver "$LATEST_VERSION" \
		--argjson count "$count" \
		--argjson first "$first" \
		--argjson next "$next" \
		'{version: $ver, count: $count, first_attempt_unix: $first, next_attempt_unix: $next}')
	write_retry_state "$new_state"

	local next_iso
	next_iso=$(date -u -d "@${next}" +%FT%TZ 2>/dev/null || date -u -r "$next" +%FT%TZ)
	echo "::notice::Preflight skipped (attempt ${count}/${MAX_RETRIES}); next retry scheduled at ${next_iso} (in ${backoff}s)."
}

# --- main flow --------------------------------------------------------------

function main() {
    # Update the version in the TOML file (anchored to skip comments).
    sed -i -E "s/^([[:space:]]*nanvix-version[[:space:]]*=[[:space:]]*\")[^\"]*/\1${LATEST_VERSION}/" "$TOML"

    # Verify the substitution took effect.
    if ! grep -qE "^[[:space:]]*nanvix-version[[:space:]]*=[[:space:]]*\"${LATEST_VERSION}\"" "$TOML"; then
    	echo "::error::sed substitution failed — nanvix-version not updated in $TOML"
    	exit 1
    fi

    # Preflight: ensure the new pin resolves cleanly against published artifacts.
    set +e
    ./z resolve --shallow
    resolve_status=$?
    set -e

    case "$resolve_status" in
    	0)
    		: # proceed to commit + PR
    		;;
    	3)
    		# EXIT_MISSING_DEP — upstream Nanvix releases not yet published.
    		# Persist retry state; the dispatcher will re-trigger when due.
    		record_skip
    		if [ -n "${GITHUB_OUTPUT:-}" ]; then
    			echo "skipped=true" >> "$GITHUB_OUTPUT"
    		fi
    		exit 0
    		;;
    	*)
    		echo "::error::Preflight failed with exit ${resolve_status} (not a missing-dep skip); bubbling up."
    		exit "$resolve_status"
    		;;
    esac

    # Preflight passed — clear any leftover retry state from a previous attempt.
    clear_retry_state

    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"

    git checkout -B "$BRANCH"
    git add "$TOML"
    git commit -m "$COMMIT_MSG"
    git push origin "$BRANCH" --force

    # Resolve default branch and open or refresh a PR.
    DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef \
    	--jq '.defaultBranchRef.name')

    PR_TITLE="[ci] E: Pin nanvix to ${LATEST_TAG}"
    printf -v PR_BODY "%s\n\n%s" \
    	"Automated bump of \`nanvix-version\` to [\`${LATEST_TAG}\`](https://github.com/nanvix/nanvix/releases/tag/${LATEST_TAG})." \
    	"Generated by the [Nanvix CI](https://github.com/nanvix/workflows/blob/main/.github/workflows/nanvix-ci.yml) reusable workflow."

    EXISTING_PR=$(gh pr list \
    	--repo "$REPO" \
    	--head "$BRANCH" \
    	--base "$DEFAULT_BRANCH" \
    	--state open \
    	--json number \
    	--jq '.[0].number // empty' 2>/dev/null || true)

    if [ -n "$EXISTING_PR" ]; then
    	gh pr edit "$EXISTING_PR" \
    		--repo "$REPO" \
    		--title "$PR_TITLE" \
    		--body "$PR_BODY"
    	echo "Updated existing PR #$EXISTING_PR."
    else
    	gh pr create \
    		--repo "$REPO" \
    		--title "$PR_TITLE" \
    		--body "$PR_BODY" \
    		--base "$DEFAULT_BRANCH" \
    		--head "$BRANCH"
    	echo "Opened new PR."
    fi
}

# Only execute main when this file is invoked directly, not sourced (so the
# test harness can load helpers in isolation without running the real flow).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	main "$@"
fi
