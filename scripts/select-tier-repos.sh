#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

# Selects enabled consumers for an updater and event from the canonical
# registry.
#
# Required environment variables:
#   EVENT_NAME     – github.event_name
#   EVENT_SCHEDULE – github.event.schedule (empty for non-schedule events)
#   UPDATER        – "nanvix" or "zutils"
#
# Outputs (written to $GITHUB_OUTPUT):
#   tier  – tier label (e.g. "tier1") or "all"
#   repos – JSON array of target repo slugs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REGISTRY:-${REPO_ROOT}/consumer-registry.json}"

if [ ! -f "$CONFIG" ]; then
    echo "::error::Tier config not found: $CONFIG"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "::error::jq is required but not installed"
    exit 1
fi

"${REPO_ROOT}/scripts/validate-consumer-registry.sh" "$CONFIG" >/dev/null

case "${UPDATER:-}" in
    nanvix) ENABLE_KEY="update_nanvix" ;;
    zutils) ENABLE_KEY="update_zutils" ;;
    *)
        echo "::error::UPDATER must be 'nanvix' or 'zutils'"
        exit 1
        ;;
esac

# --- Tier selection ---------------------------------------------------

if [ "$EVENT_NAME" = "schedule" ] && [ -n "${EVENT_SCHEDULE:-}" ]; then
    TIER_NUMBER=$(jq -r --arg cron "$EVENT_SCHEDULE" \
        '.tiers[] | select(.cron == $cron) | .tier' "$CONFIG")

    if [ -z "$TIER_NUMBER" ]; then
        echo "::error::Unrecognized schedule '${EVENT_SCHEDULE}'; no matching tier in $CONFIG"
        exit 1
    fi

    TIER="tier${TIER_NUMBER}"
    REPOS=$(jq -c --argjson tier "$TIER_NUMBER" --arg key "$ENABLE_KEY" \
        '[.consumers[] | select(.tier == $tier and .[$key]) | .repo] | sort' "$CONFIG")

    echo "tier=$TIER" >>"$GITHUB_OUTPUT"
    echo "repos=$REPOS" >>"$GITHUB_OUTPUT"
    echo "Selected tier: $TIER (cron: $EVENT_SCHEDULE)"
else
    REPOS=$(jq -c --arg key "$ENABLE_KEY" \
        '[.consumers[] | select(.[$key]) | .repo] | sort' "$CONFIG")
    echo "tier=all" >>"$GITHUB_OUTPUT"
    echo "repos=$REPOS" >>"$GITHUB_OUTPUT"
    echo "Selected tier: all (event: $EVENT_NAME)"
fi
