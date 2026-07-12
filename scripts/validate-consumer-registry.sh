#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

set -euo pipefail

REGISTRY="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/consumer-registry.json}"

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required" >&2
    exit 1
fi

if ! jq -e '
    . as $registry
    | .schema_version == 1
    and (.tiers | type == "array" and length > 0)
    and (.consumers | type == "array" and length > 0)
    and all(.tiers[];
        (.tier | type == "number" and . >= 1 and floor == .)
        and (.cron | type == "string"
            and test("^[0-9*,-]+ [0-9*,-]+ [0-9*,-]+ [0-9*,-]+ [0-9*,-]+$")))
    and all(.consumers[];
        (keys | sort) == ([
            "derived_image", "provider", "repo", "tier", "toolchain",
            "update_nanvix", "update_zutils"
        ] | sort)
        and (.repo | type == "string"
            and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
        and (.tier | type == "number" and . >= 1 and floor == .)
        and (.update_nanvix | type == "boolean")
        and (.update_zutils | type == "boolean")
        and (.toolchain == "nanvix-sdk")
        and (.provider | type == "string" and length > 0)
        and (.derived_image | type == "boolean"))
    and ([.tiers[].tier] | length == (unique | length))
    and ([.tiers[].cron] | length == (unique | length))
    and ([.consumers[].repo] | length == (unique | length))
    and (([.tiers[].tier] | sort) == ([.consumers[].tier] | unique | sort))
    and all(.consumers[];
        .tier as $tier | any($registry.tiers[]; .tier == $tier))
' "$REGISTRY" >/dev/null; then
    echo "error: invalid consumer registry: $REGISTRY" >&2
    exit 1
fi

echo "Consumer registry is valid: $REGISTRY"
