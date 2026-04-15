#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

# Selects the tier-appropriate subset of target repositories based on
# the GitHub Actions event context.  Reads tier definitions from
# tier-config.json in the repository root so that the cron-to-repo
# mapping lives in a single place shared by all dispatch workflows.
#
# Required environment variables:
#   EVENT_NAME     – github.event_name
#   EVENT_SCHEDULE – github.event.schedule (empty for non-schedule events)
#   DEFAULT_REPOS  – JSON array of all consumer repos (fallback)
#
# Outputs (written to $GITHUB_OUTPUT):
#   tier  – tier label (e.g. "tier1") or "all"
#   repos – JSON array of target repo slugs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/tier-config.json"

if [ ! -f "$CONFIG" ]; then
  echo "::error::Tier config not found: $CONFIG"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "::error::jq is required but not installed"
  exit 1
fi

# --- Config validation ------------------------------------------------

# No duplicate cron entries.
DUPLICATE_CRONS=$(jq '[.tiers[].cron] | group_by(.) | map(select(length > 1)) | length' "$CONFIG")
if [ "$DUPLICATE_CRONS" -ne 0 ]; then
  echo "::error::Duplicate cron entries in $CONFIG"
  exit 1
fi

# No duplicate tier names.
DUPLICATE_NAMES=$(jq '[.tiers[].name] | group_by(.) | map(select(length > 1)) | length' "$CONFIG")
if [ "$DUPLICATE_NAMES" -ne 0 ]; then
  echo "::error::Duplicate tier names in $CONFIG"
  exit 1
fi

# Union of tier repos must match consumer-repos.json.
CONSUMER_REPOS="${REPO_ROOT}/consumer-repos.json"
if [ -f "$CONSUMER_REPOS" ]; then
  TIER_REPOS=$(jq -c '[.tiers[].repos[]] | sort | unique' "$CONFIG")
  ALL_REPOS=$(jq -c 'sort | unique' "$CONSUMER_REPOS")
  if [ "$TIER_REPOS" != "$ALL_REPOS" ]; then
    echo "::error::Tier repos in $CONFIG do not match $CONSUMER_REPOS"
    echo "  Tier repos:     $TIER_REPOS"
    echo "  Consumer repos: $ALL_REPOS"
    exit 1
  fi
fi

# --- Tier selection ---------------------------------------------------

if [ "$EVENT_NAME" = "schedule" ] && [ -n "${EVENT_SCHEDULE:-}" ]; then
  TIER=$(jq -r --arg cron "$EVENT_SCHEDULE" \
    '.tiers[] | select(.cron == $cron) | .name' "$CONFIG")

  if [ -z "$TIER" ]; then
    echo "::error::Unrecognized schedule '${EVENT_SCHEDULE}'; no matching tier in $CONFIG"
    exit 1
  fi

  REPOS=$(jq -c --arg cron "$EVENT_SCHEDULE" \
    '.tiers[] | select(.cron == $cron) | .repos' "$CONFIG")

  echo "tier=$TIER"  >> "$GITHUB_OUTPUT"
  echo "repos=$REPOS" >> "$GITHUB_OUTPUT"
  echo "Selected tier: $TIER (cron: $EVENT_SCHEDULE)"
else
  echo "tier=all"              >> "$GITHUB_OUTPUT"
  echo "repos=$DEFAULT_REPOS"  >> "$GITHUB_OUTPUT"
  echo "Selected tier: all (event: $EVENT_NAME)"
fi
