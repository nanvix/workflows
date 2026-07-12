#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${OUTPUT_CONTRACT:-${REPO_ROOT}/sdk-release.json}"
DOWNLOAD_DIR="${REPO_ROOT}/.sdk-release"
TAG="${SDK_TAG:-}"

rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

if [ -n "${SDK_DISPATCH_CONTRACT:-}" ]; then
    printf '%s\n' "$SDK_DISPATCH_CONTRACT" | jq -S . >"${DOWNLOAD_DIR}/dispatch.json"
    TAG=$(jq -r '.sdk_version' "${DOWNLOAD_DIR}/dispatch.json")
fi

if [ -z "$TAG" ]; then
    TAG=$(gh api repos/nanvix/sdk/releases/latest --jq '.tag_name')
fi
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-sdk\.[0-9]+$ ]]; then
    echo "error: invalid verified SDK release tag: $TAG" >&2
    exit 1
fi

gh release download "$TAG" \
    --repo nanvix/sdk \
    --pattern sdk-release.json \
    --dir "$DOWNLOAD_DIR"
"${REPO_ROOT}/scripts/validate-sdk-contract.sh" "${DOWNLOAD_DIR}/sdk-release.json"
if [ "$(jq -r '.sdk_version' "${DOWNLOAD_DIR}/sdk-release.json")" != "$TAG" ]; then
    echo "error: SDK release tag and contract sdk_version disagree" >&2
    exit 1
fi

if [ -f "${DOWNLOAD_DIR}/dispatch.json" ]; then
    "${REPO_ROOT}/scripts/validate-sdk-contract.sh" "${DOWNLOAD_DIR}/dispatch.json"
    if ! cmp -s "${DOWNLOAD_DIR}/dispatch.json" <(jq -S . "${DOWNLOAD_DIR}/sdk-release.json"); then
        echo "error: SDK dispatch contract disagrees with the GitHub Release asset" >&2
        exit 1
    fi
fi

jq -S . "${DOWNLOAD_DIR}/sdk-release.json" >"$OUTPUT"
KEY="$(jq -r '.sdk_version + ":" + .image.digest' "$OUTPUT")"
if [ -n "${SDK_IDEMPOTENCY_KEY:-}" ] && [ "$SDK_IDEMPOTENCY_KEY" != "$KEY" ]; then
    echo "error: SDK dispatch idempotency key disagrees with the contract" >&2
    exit 1
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "contract=$(base64 -w 0 "$OUTPUT")"
        echo "sdk_version=$(jq -r '.sdk_version' "$OUTPUT")"
        echo "idempotency_key=$KEY"
    } >>"$GITHUB_OUTPUT"
fi

rm -rf "$DOWNLOAD_DIR"
