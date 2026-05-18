#!/bin/bash

set -euo pipefail

if [ ! -f consumer-repos.json ]; then
echo "::error::consumer-repos.json not found at repo root"
exit 1
fi

now=$(date -u +%s)
dispatched=()
pending=()
stale=()
errored=()

while read -r repo; do
    [ -z "$repo" ] && continue

    # Repository variable may not exist — treat as "no retry pending".
    state=$(gh variable get PREFLIGHT_RETRY_STATE --repo "$repo" 2>/dev/null || echo "")
    if [ -z "$state" ]; then
        continue
    fi

    # Validate JSON shape before trusting it.
    if ! echo "$state" | jq -e '.next_attempt_unix and .version and .count' >/dev/null 2>&1; then
        stale+=("$repo (malformed state)")
        continue
    fi

    next=$(echo "$state" | jq -r '.next_attempt_unix')
    ver=$(echo "$state" | jq -r '.version')
    count=$(echo "$state" | jq -r '.count')

    if [ "$now" -lt "$next" ]; then
        pending+=("$repo (v${ver}, attempt ${count}, due in $((next - now))s)")
        continue
    fi

    echo "::group::Dispatch ${repo} (attempt $((count + 1)) for v${ver})"

    default_branch=$(gh repo view "$repo" \
        --json defaultBranchRef \
        --jq '.defaultBranchRef.name' 2>/dev/null || echo "")
    if [ -z "$default_branch" ]; then
        echo "::warning::Could not resolve default branch for ${repo}"
        errored+=("$repo (default branch lookup failed)")
        echo "::endgroup::"
        continue
    fi

    if gh workflow run nanvix-ci.yml \
        --repo "$repo" \
        --ref "$default_branch"; then
        dispatched+=("$repo (ref ${default_branch})")
    else
        echo "::warning::gh workflow run failed for ${repo}"
        errored+=("$repo (dispatch failed)")
    fi
    echo "::endgroup::"
done < <(jq -r '.[]' consumer-repos.json)

{
    echo "## Preflight retry dispatch — $(date -u +%FT%TZ)"
    echo ""
    if [ "${#dispatched[@]}" -gt 0 ]; then
        echo "### Dispatched (${#dispatched[@]})"
        printf -- '- %s\n' "${dispatched[@]}"
        echo ""
    fi
    if [ "${#pending[@]}" -gt 0 ]; then
        echo "### Not yet due (${#pending[@]})"
        printf -- '- %s\n' "${pending[@]}"
        echo ""
    fi
    if [ "${#stale[@]}" -gt 0 ]; then
        echo "### Malformed state (${#stale[@]})"
        printf -- '- %s\n' "${stale[@]}"
        echo ""
    fi
    if [ "${#errored[@]}" -gt 0 ]; then
        echo "### Errored (${#errored[@]})"
        printf -- '- %s\n' "${errored[@]}"
        echo ""
    fi
    if [ "${#dispatched[@]}" -eq 0 ] \
        && [ "${#pending[@]}" -eq 0 ] \
        && [ "${#stale[@]}" -eq 0 ] \
        && [ "${#errored[@]}" -eq 0 ]; then
        echo "No consumers currently in retry state."
    fi
} >> "$GITHUB_STEP_SUMMARY"
