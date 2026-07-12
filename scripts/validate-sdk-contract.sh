#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

set -euo pipefail

CONTRACT="${1:?usage: validate-sdk-contract.sh CONTRACT}"

jq -e '
    .schema_version == 1
    and (.sdk_version | type == "string"
        and test("^v[0-9]+\\.[0-9]+\\.[0-9]+-sdk\\.[0-9]+$"))
    and (.provider_id | type == "string" and length > 0)
    and (.provider | type == "string" and length > 0)
    and (.image.name | type == "string" and startswith("ghcr.io/"))
    and (.image.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
    and .image.ref == (.image.name + "@" + .image.digest)
    and (.libc.nanvix_tag | type == "string"
        and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    and .libc.nanvix_version == (.libc.nanvix_tag | ltrimstr("v"))
    and (.libc.nanvix_commit | type == "string" and test("^[0-9a-f]{40}$"))
    and (.libc.sysroot_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.compat.c_abi | type == "string" and length > 0)
    and (.target.triple | type == "string" and length > 0)
    and (.target.alias | type == "string" and length > 0)
' "$CONTRACT" >/dev/null || {
    echo "error: malformed or inconsistent SDK release contract: $CONTRACT" >&2
    exit 1
}
