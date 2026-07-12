#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

set -euo pipefail

IMAGE_REF="${NANVIX_DOCKER_IMAGE:?NANVIX_DOCKER_IMAGE is required}"
SDK_IMAGE_REF="${SDK_IMAGE_REF:?SDK_IMAGE_REF is required}"
SDK_VERSION="${SDK_VERSION:?SDK_VERSION is required}"
SDK_PROVIDER="${SDK_PROVIDER:?SDK_PROVIDER is required}"
SDK_DIGEST="${SDK_DIGEST:?SDK_DIGEST is required}"
SDK_C_ABI="${SDK_C_ABI:?SDK_C_ABI is required}"
SDK_LIBC_TAG="${SDK_LIBC_TAG:?SDK_LIBC_TAG is required}"
SDK_LIBC_COMMIT="${SDK_LIBC_COMMIT:?SDK_LIBC_COMMIT is required}"
SDK_SYSROOT_SHA256="${SDK_SYSROOT_SHA256:?SDK_SYSROOT_SHA256 is required}"

if [[ ! "$IMAGE_REF" =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "error: SDK build image must use an immutable digest: $IMAGE_REF" >&2
    exit 1
fi
docker pull "$IMAGE_REF"

MANIFEST="$(docker run --rm "$IMAGE_REF" cat /opt/nanvix/nanvix-sdk.json)"
LABELS="$(docker image inspect "$IMAGE_REF" --format '{{json .Config.Labels}}')"

jq -e \
    --arg version "$SDK_VERSION" \
    --arg provider "$SDK_PROVIDER" \
    --arg c_abi "$SDK_C_ABI" \
    --arg libc_tag "$SDK_LIBC_TAG" \
    --arg libc_commit "$SDK_LIBC_COMMIT" \
    --arg sysroot "$SDK_SYSROOT_SHA256" '
    .sdk_version == $version
    and .provider == $provider
    and .compat.c_abi == $c_abi
    and .libc.nanvix_tag == $libc_tag
    and .libc.nanvix_commit == $libc_commit
    and .libc.sysroot_sha256 == $sysroot
' <<<"$MANIFEST" >/dev/null || {
    echo "error: embedded SDK manifest disagrees with lockfile provenance" >&2
    exit 1
}

while IFS=$'\t' read -r key expected; do
    label="dev.nanvix.sdk.$key"
    actual="$(jq -r --arg label "$label" '.[$label] // empty' <<<"$LABELS")"
    if [ -z "$actual" ] && [ "$key" = "libc.sysroot_sha256" ]; then
        continue
    fi
    if [ "$actual" != "$expected" ]; then
        echo "error: OCI label $label is missing or disagrees with the embedded SDK manifest" >&2
        exit 1
    fi
done < <(
    jq -r 'paths(type != "array" and type != "object") as $path
        | [($path | map(tostring) | join(".")), (getpath($path) | tostring)]
        | @tsv
    ' <<<"$MANIFEST"
)

while IFS=$'\t' read -r label actual; do
    key="${label#dev.nanvix.sdk.}"
    case "$key" in
        base.digest | image.* | provider_id | libc.nanvix_version)
            continue
            ;;
        manifest)
            if ! jq -e --argjson manifest "$MANIFEST" '. == $manifest' \
                <<<"$actual" >/dev/null; then
                echo "error: OCI manifest label disagrees with the embedded SDK manifest" >&2
                exit 1
            fi
            continue
            ;;
    esac
    expected="$(jq -r --arg key "$key" '
        ($key | split(".")) as $path
        | if any(paths(type != "array" and type != "object"); . == $path)
          then getpath($path) | tostring
          else empty
          end
    ' <<<"$MANIFEST")"
    if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
        echo "error: unknown or mismatched SDK OCI label: $label" >&2
        exit 1
    fi
done < <(
    jq -r 'to_entries[]
        | select(.key | startswith("dev.nanvix.sdk."))
        | [.key, .value]
        | @tsv
    ' <<<"$LABELS"
)

IMAGE_LABEL_DIGEST="$(jq -r '
    .["dev.nanvix.sdk.image.digest"] // empty
' <<<"$LABELS")"
if [ -n "$IMAGE_LABEL_DIGEST" ] && [ "$IMAGE_LABEL_DIGEST" != "$SDK_DIGEST" ]; then
    echo "error: SDK image digest label disagrees with lockfile provenance" >&2
    exit 1
fi

if [ "$IMAGE_REF" != "$SDK_IMAGE_REF" ]; then
    BASE_DIGEST="$(jq -r '
        .["dev.nanvix.sdk.base.digest"]
        // .["dev.nanvix.sdk.image.digest"]
        // empty
    ' <<<"$LABELS")"
    if [ "$BASE_DIGEST" != "$SDK_DIGEST" ]; then
        echo "error: derived image does not prove its immutable base SDK digest" >&2
        exit 1
    fi
fi
