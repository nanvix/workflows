#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

set -euo pipefail

REPO="${TARGET_REPO:?TARGET_REPO is required}"
KIND="${UPDATE_KIND:?UPDATE_KIND is required}"
BRANCH="${UPDATE_BRANCH:?UPDATE_BRANCH is required}"
TITLE="${PR_TITLE:?PR_TITLE is required}"
BODY="${PR_BODY:?PR_BODY is required}"
EXPECTED_DIGEST="${EXPECTED_PATCH_SHA256:?EXPECTED_PATCH_SHA256 is required}"
EXPECTED_BUNDLE_DIGEST="${EXPECTED_BUNDLE_SHA256:?EXPECTED_BUNDLE_SHA256 is required}"
ARTIFACT_INPUT="${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -d "$ARTIFACT_INPUT" ] || [ -L "$ARTIFACT_INPUT" ]; then
    echo "error: publication artifact directory is missing or unsafe" >&2
    exit 1
fi
ARTIFACT_DIR="$(cd "$ARTIFACT_INPUT" && pwd -P)"

case "$KIND" in
    nanvix)
        TRUSTED_ALLOWLIST=(
            ".github/workflows/nanvix-ci.yml"
            ".nanvix/nanvix.lock"
            ".nanvix/nanvix.toml"
            ".nanvix/z.py"
        )
        ;;
    zutils)
        TRUSTED_ALLOWLIST=(
            ".nanvix/.gitignore"
            ".zutils-version"
            "z"
            "z.ps1"
            "z.sh"
        )
        ;;
    *)
        echo "error: UPDATE_KIND must be 'nanvix' or 'zutils'" >&2
        exit 1
        ;;
esac
TRUSTED_ALLOWLIST_JSON="$(
    printf '%s\n' "${TRUSTED_ALLOWLIST[@]}" | jq -R . | jq -csS .
)"

UPDATE_FLAG="update_$KIND"
if ! jq -e \
    --arg repository "$REPO" \
    --arg update_flag "$UPDATE_FLAG" '
        [.consumers[]
         | select(
             .repo == $repository
             and .[$update_flag] == true
         )]
        | length == 1
    ' "${REPO_ROOT}/consumer-registry.json" >/dev/null; then
    echo "error: publisher target is not enabled in the trusted consumer registry" >&2
    exit 1
fi

PATCH="${ARTIFACT_DIR}/update.patch"
METADATA="${ARTIFACT_DIR}/metadata.json"
RESULT="${ARTIFACT_DIR}/result.json"
for path in "$PATCH" "$METADATA" "$RESULT"; do
    if [ ! -f "$path" ] || [ -L "$path" ]; then
        echo "error: missing or unsafe publication artifact: $path" >&2
        exit 1
    fi
done

BUNDLE_DIGEST="$(
    for name in metadata.json result.json update.patch; do
        sha256sum "${ARTIFACT_DIR}/$name" | awk -v name="$name" '{print $1, name}'
    done | sha256sum | awk '{print $1}'
)"
if [ "$BUNDLE_DIGEST" != "$EXPECTED_BUNDLE_DIGEST" ]; then
    echo "error: publication bundle digest mismatch" >&2
    exit 1
fi

ACTUAL_DIGEST="$(sha256sum "$PATCH" | awk '{print $1}')"
STORED_DIGEST="$(jq -r '.patch_sha256' "$METADATA")"
if [ "$ACTUAL_DIGEST" != "$EXPECTED_DIGEST" ] ||
    [ "$STORED_DIGEST" != "$EXPECTED_DIGEST" ]; then
    echo "error: patch digest mismatch" >&2
    exit 1
fi
if [ "$(jq -r '.repository' "$METADATA")" != "$REPO" ] ||
    [ "$(jq -r '.kind' "$METADATA")" != "$KIND" ]; then
    echo "error: patch metadata does not match publisher target" >&2
    exit 1
fi

ARTIFACT_ALLOWLIST="$(jq -cS '.allowlist' "$METADATA")"
if [ "$ARTIFACT_ALLOWLIST" != "$TRUSTED_ALLOWLIST_JSON" ]; then
    echo "error: artifact allowlist disagrees with the trusted publisher policy" >&2
    exit 1
fi
mapfile -t PATCH_PATHS < <(
    python3 "${REPO_ROOT}/scripts/validate-update-patch.py" \
        "$PATCH" "$TRUSTED_ALLOWLIST_JSON"
)
PATCH_PATH_LIST="$(printf '%s\n' "${PATCH_PATHS[@]}" | sort)"
RESULT_PATH_LIST="$(jq -r '.changed_files[]' "$RESULT" | sort)"
if [ "$PATCH_PATH_LIST" != "$RESULT_PATH_LIST" ]; then
    echo "error: patch paths disagree with the structured updater result" >&2
    exit 1
fi

CLONE_DIR="${PUBLISH_WORKDIR:-.publisher-repository}"
rm -rf "$CLONE_DIR"
if [ -n "${PUBLISH_CLONE_URL:-}" ]; then
    git clone --depth=1 "$PUBLISH_CLONE_URL" "$CLONE_DIR"
else
    GH_TOKEN="$TOKEN" gh repo clone "$REPO" "$CLONE_DIR" -- --depth=1
fi
cd "$CLONE_DIR"
git config core.hooksPath /dev/null

if [ -n "${PUBLISH_CLONE_URL:-}" ]; then
    DEFAULT_BRANCH="$(git branch --show-current)"
else
    DEFAULT_BRANCH="$(GH_TOKEN="$TOKEN" gh repo view "$REPO" \
        --json defaultBranchRef --jq '.defaultBranchRef.name')"
fi
if [ "$(git branch --show-current)" != "$DEFAULT_BRANCH" ]; then
    echo "error: clone did not check out the default branch" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "error: default branch clone is not clean" >&2
    exit 1
fi
if [ "$(git rev-parse HEAD)" != "$(jq -r '.base_sha' "$METADATA")" ]; then
    echo "error: default branch advanced after mutation; refusing stale patch" >&2
    exit 1
fi

for path in "${PATCH_PATHS[@]}"; do
    mode="$(git ls-files -s -- "$path" | awk '{print $1}')"
    if [ -n "$mode" ] && [ "$mode" != "100644" ] && [ "$mode" != "100755" ]; then
        echo "error: target path is a symlink, submodule, or has an unexpected mode: $path" >&2
        exit 1
    fi
done

git apply --check --index "$PATCH"
git apply --index "$PATCH"

mapfile -t STAGED < <(git diff --cached --name-only)
STAGED_PATH_LIST="$(printf '%s\n' "${STAGED[@]}" | sort)"
if [ "$PATCH_PATH_LIST" != "$STAGED_PATH_LIST" ]; then
    echo "error: applied patch staged unexpected paths" >&2
    exit 1
fi
for path in "${STAGED[@]}"; do
    mode="$(git ls-files -s -- "$path" | awk '{print $1}')"
    expected_mode="100644"
    if [ "$path" = "z" ] || [ "$path" = "z.sh" ]; then
        expected_mode="100755"
    fi
    if [ "$mode" != "$expected_mode" ]; then
        echo "error: applied patch created an unsafe file mode: $path" >&2
        exit 1
    fi
done

if [ "${PUBLISH_VALIDATE_ONLY:-false}" = "true" ]; then
    echo "Patch is safe and applies to a clean current default branch."
    exit 0
fi

REMOTE_SHA="$(git ls-remote --heads origin "refs/heads/$BRANCH" | awk '{print $1}')"
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git checkout -b "$BRANCH"
git commit -m "$TITLE"

AUTH_HEADER="$(printf 'x-access-token:%s' "$TOKEN" | base64 -w 0)"
git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $AUTH_HEADER" \
    push origin "HEAD:refs/heads/$BRANCH" \
    "--force-with-lease=refs/heads/$BRANCH:$REMOTE_SHA"

EXISTING_PR="$(GH_TOKEN="$TOKEN" gh pr list \
    --repo "$REPO" \
    --head "$BRANCH" \
    --base "$DEFAULT_BRANCH" \
    --state open \
    --json number \
    --jq '.[0].number // empty')"
if [ -n "$EXISTING_PR" ]; then
    GH_TOKEN="$TOKEN" gh api --method PATCH \
        "repos/$REPO/pulls/$EXISTING_PR" \
        -f title="$TITLE" \
        -f body="$BODY" >/dev/null
    echo "Refreshed $REPO PR #$EXISTING_PR."
else
    GH_TOKEN="$TOKEN" gh pr create \
        --repo "$REPO" \
        --base "$DEFAULT_BRANCH" \
        --head "$BRANCH" \
        --title "$TITLE" \
        --body "$BODY"
fi
