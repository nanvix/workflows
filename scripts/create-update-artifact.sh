#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

set -euo pipefail

KIND="${UPDATE_KIND:?UPDATE_KIND is required}"
TARGET="${UPDATE_TARGET:?UPDATE_TARGET is required}"
REPO="${TARGET_REPO:?TARGET_REPO is required}"
ARTIFACT_DIR="${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
RESULT_PATH=".git/nanvix-workflows-update-result.json"

case "$KIND" in
    nanvix)
        COMMAND=(nanvix-zutil update-nanvix --to "$TARGET")
        ALLOWLIST=(
            ".github/workflows/nanvix-ci.yml"
            ".nanvix/nanvix.lock"
            ".nanvix/nanvix.toml"
            ".nanvix/z.py"
        )
        ;;
    zutils)
        : "${TEMPLATES_DIR:?TEMPLATES_DIR is required for zutils updates}"
        COMMAND=(
            nanvix-zutil update-zutils --to "$TARGET"
            --templates-dir "$TEMPLATES_DIR"
        )
        ALLOWLIST=(
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

rm -rf "$ARTIFACT_DIR"
rm -f "$RESULT_PATH"

set +e
"${COMMAND[@]}" --output-format json --output "$RESULT_PATH"
COMMAND_STATUS=$?
set -e

# Older bootstraps do not ignore the persistent inter-process lock yet.
if ! git ls-files --error-unmatch \
    .nanvix/.nanvix-zutil-update.lock >/dev/null 2>&1; then
    rm -f .nanvix/.nanvix-zutil-update.lock
fi

if [ ! -f "$RESULT_PATH" ] || ! jq -e --arg command "update-$KIND" '
    type == "object"
    and .command == $command
    and (.status == "updated" or .status == "up-to-date" or .status == "blocked")
    and (.changed_files | type == "array" and all(.[]; type == "string"))
' "$RESULT_PATH" >/dev/null; then
    echo "error: updater did not emit a valid structured result" >&2
    rm -f "$RESULT_PATH"
    exit 1
fi

STATUS="$(jq -r '.status' "$RESULT_PATH")"
if [ "$STATUS" = "blocked" ]; then
    if [ "$COMMAND_STATUS" -ne 3 ] ||
        [ "$(jq '.changed_files | length' "$RESULT_PATH")" -ne 0 ] ||
        [ -n "$(git status --porcelain)" ]; then
        echo "error: blocked update was not atomic" >&2
        rm -f "$RESULT_PATH"
        exit 1
    fi
    jq -cS . "$RESULT_PATH"
    rm -f "$RESULT_PATH"
    [ -n "${GITHUB_OUTPUT:-}" ] && echo "status=blocked" >>"$GITHUB_OUTPUT"
    exit 0
fi

if [ "$COMMAND_STATUS" -ne 0 ]; then
    echo "error: updater failed with status $COMMAND_STATUS" >&2
    rm -f "$RESULT_PATH"
    exit "$COMMAND_STATUS"
fi

mapfile -t CHANGED < <(jq -r '.changed_files[]' "$RESULT_PATH")
if [ "$STATUS" = "up-to-date" ]; then
    if [ "${#CHANGED[@]}" -ne 0 ] || [ -n "$(git status --porcelain)" ]; then
        echo "error: no-op updater result disagrees with the worktree" >&2
        rm -f "$RESULT_PATH"
        exit 1
    fi
    jq -cS . "$RESULT_PATH"
    rm -f "$RESULT_PATH"
    [ -n "${GITHUB_OUTPUT:-}" ] && echo "status=current" >>"$GITHUB_OUTPUT"
    exit 0
fi

if [ "${#CHANGED[@]}" -eq 0 ]; then
    echo "error: updated result has no changed files" >&2
    rm -f "$RESULT_PATH"
    exit 1
fi

for path in "${CHANGED[@]}"; do
    allowed=false
    for candidate in "${ALLOWLIST[@]}"; do
        if [ "$path" = "$candidate" ]; then
            allowed=true
            break
        fi
    done
    if [ "$allowed" != true ]; then
        echo "error: updater changed unexpected path: $path" >&2
        rm -f "$RESULT_PATH"
        exit 1
    fi
done

git add -f -- "${CHANGED[@]}"
mapfile -t STAGED < <(git diff --cached --name-only)
mapfile -t UNSTAGED < <(git status --porcelain | sed -E 's/^...//')
if [ "$(printf '%s\n' "${CHANGED[@]}" | sort)" != "$(printf '%s\n' "${STAGED[@]}" | sort)" ] ||
    [ "$(printf '%s\n' "${STAGED[@]}" | sort)" != "$(printf '%s\n' "${UNSTAGED[@]}" | sort)" ]; then
    echo "error: structured changed files disagree with the Git index" >&2
    rm -f "$RESULT_PATH"
    exit 1
fi

mkdir -p "$ARTIFACT_DIR"
git diff --cached --binary --full-index --no-color \
    --src-prefix=a/ --dst-prefix=b/ -- "${ALLOWLIST[@]}" >"${ARTIFACT_DIR}/update.patch"
if [ ! -s "${ARTIFACT_DIR}/update.patch" ]; then
    echo "error: updater produced an empty patch" >&2
    rm -rf "$ARTIFACT_DIR"
    rm -f "$RESULT_PATH"
    exit 1
fi

jq -S . "$RESULT_PATH" >"${ARTIFACT_DIR}/result.json"
sha256sum "${ARTIFACT_DIR}/update.patch" |
    awk '{print $1}' >"${ARTIFACT_DIR}/update.patch.sha256"
jq -nS \
    --arg repository "$REPO" \
    --arg kind "$KIND" \
    --arg base_sha "$(git rev-parse HEAD)" \
    --arg patch_sha256 "$(cat "${ARTIFACT_DIR}/update.patch.sha256")" \
    --argjson allowlist "$(printf '%s\n' "${ALLOWLIST[@]}" | jq -R . | jq -s .)" \
    '{
        repository: $repository,
        kind: $kind,
        base_sha: $base_sha,
        patch_sha256: $patch_sha256,
        allowlist: $allowlist
    }' >"${ARTIFACT_DIR}/metadata.json"
BUNDLE_SHA256="$(
    for name in metadata.json result.json update.patch; do
        sha256sum "${ARTIFACT_DIR}/$name" | awk -v name="$name" '{print $1, name}'
    done | sha256sum | awk '{print $1}'
)"

rm -f "$RESULT_PATH"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "status=updated"
        echo "patch_sha256=$(cat "${ARTIFACT_DIR}/update.patch.sha256")"
        echo "bundle_sha256=$BUNDLE_SHA256"
    } >>"$GITHUB_OUTPUT"
fi
