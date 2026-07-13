#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/tests/.work"
PASS=0
cd "$ROOT"

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT
cleanup
mkdir -p "$WORK"

ok() {
    PASS=$((PASS + 1))
    echo "ok $PASS - $1"
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        echo "not ok - command unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

"$ROOT/scripts/validate-consumer-registry.sh" >/dev/null
jq -e '.consumers[] | select(.repo == "nanvix/busybox" and .tier == 1)' \
    "$ROOT/consumer-registry.json" >/dev/null
ok "registry accepts unique structured consumers and BusyBox"

jq '.consumers += [.consumers[0]]' "$ROOT/consumer-registry.json" >"$WORK/duplicate.json"
expect_failure "$ROOT/scripts/validate-consumer-registry.sh" "$WORK/duplicate.json"
ok "registry rejects duplicate repositories"

jq '(.consumers[] | select(.repo == "nanvix/busybox")).update_nanvix = false' \
    "$ROOT/consumer-registry.json" >"$WORK/killed.json"
: >"$WORK/output"
REGISTRY="$WORK/killed.json" \
    EVENT_NAME=schedule \
    EVENT_SCHEDULE="0 9 * * *" \
    UPDATER=nanvix \
    GITHUB_OUTPUT="$WORK/output" \
    "$ROOT/scripts/select-tier-repos.sh" >/dev/null
if grep -q 'nanvix/busybox' "$WORK/output"; then
    echo "kill-switched repository was selected" >&2
    exit 1
fi
ok "per-updater kill switch removes a scheduled consumer"

for workflow in \
    nanvix-update-nanvix.yml \
    nanvix-update-workflows.yml \
    nanvix-update-zutils.yml; do
    yq_crons="$(
        grep -E '^[[:space:]]*- cron: "' \
            "$ROOT/.github/workflows/$workflow" |
            sed -E 's/.*cron: "([^"]*)".*/\1/' |
            sort
    )"
    registry_crons="$(jq -r '.tiers[].cron' "$ROOT/consumer-registry.json" | sort)"
    [ "$yq_crons" = "$registry_crons" ]
done
ok "registry and updater schedules contain identical tier tuples"

"$ROOT/scripts/validate-sdk-contract.sh" \
    "$ROOT/tests/fixtures/sdk-release.json"
jq '.libc.nanvix_version = "0.21.0"' \
    "$ROOT/tests/fixtures/sdk-release.json" >"$WORK/skewed.json"
expect_failure "$ROOT/scripts/validate-sdk-contract.sh" "$WORK/skewed.json"
printf '{"schema_version":1}\n' >"$WORK/malformed.json"
expect_failure "$ROOT/scripts/validate-sdk-contract.sh" "$WORK/malformed.json"
ok "SDK contract validation accepts coherent and rejects malformed or skewed metadata"

mkdir -p "$WORK/bin"
cat >"$WORK/bin/nanvix-zutil" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1#update-}"
output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--output" ]; then
        output="$2"
        shift 2
    else
        shift
    fi
done
case "${FAKE_MODE:?}" in
    current)
        : >.nanvix/.nanvix-zutil-update.lock
        printf '{"command":"update-%s","status":"up-to-date","changed_files":[]}\n' \
            "$command_name" >"$output"
        ;;
    blocked)
        : >.nanvix/.nanvix-zutil-update.lock
        printf '{"command":"update-%s","status":"blocked","changed_files":[],"blocker":{"reason":"dependency"}}\n' \
            "$command_name" >"$output"
        exit 3
        ;;
    update)
        : >.nanvix/.nanvix-zutil-update.lock
        printf 'new manifest\n' >.nanvix/nanvix.toml
        printf 'new lock\n' >.nanvix/nanvix.lock
        printf '{"command":"update-%s","status":"updated","changed_files":[".nanvix/nanvix.lock",".nanvix/nanvix.toml"]}\n' \
            "$command_name" >"$output"
        ;;
    unexpected)
        printf 'bad\n' >unexpected
        printf '{"command":"update-%s","status":"updated","changed_files":["unexpected"]}\n' \
            "$command_name" >"$output"
        ;;
    malformed)
        printf '{"bad":true}\n' >"$output"
        ;;
esac
FAKE
chmod +x "$WORK/bin/nanvix-zutil"

make_consumer() {
    rm -rf "$WORK/consumer"
    mkdir -p "$WORK/consumer/.nanvix"
    (
        cd "$WORK/consumer"
        git init -q -b main
        git config user.name Test
        git config user.email test@example.com
        printf 'old manifest\n' >.nanvix/nanvix.toml
        printf 'old lock\n' >.nanvix/nanvix.lock
        git add .
        git commit -qm initial
    )
}

run_mutation() {
    (
        cd "$WORK/consumer"
        PATH="$WORK/bin:$PATH" \
            FAKE_MODE="$1" \
            UPDATE_KIND=nanvix \
            UPDATE_TARGET="$ROOT/tests/fixtures/sdk-release.json" \
            TARGET_REPO=nanvix/zlib \
            ARTIFACT_DIR="$WORK/artifact" \
            "$ROOT/scripts/create-update-artifact.sh"
    )
}

make_consumer
run_mutation current >/dev/null
[ ! -e "$WORK/artifact" ]
run_mutation blocked >/dev/null
[ ! -e "$WORK/artifact" ]
expect_failure run_mutation malformed
expect_failure run_mutation unexpected
ok "mutation handles no-op, blocked, malformed, and unexpected-path results"

make_consumer
run_mutation update >/dev/null
test -s "$WORK/artifact/update.patch"
sha256sum -c <(
    printf '%s  %s\n' \
        "$(cat "$WORK/artifact/update.patch.sha256")" \
        "$WORK/artifact/update.patch"
) >/dev/null
ok "mutation emits deterministic binary patch, result, metadata, and SHA-256"

ALLOW='[".nanvix/nanvix.lock",".nanvix/nanvix.toml"]'
"$ROOT/scripts/validate-update-patch.py" "$WORK/artifact/update.patch" "$ALLOW" \
    >/dev/null
expect_failure "$ROOT/scripts/validate-update-patch.py" \
    "$WORK/artifact/update.patch" '[".nanvix/nanvix.toml"]'

cat >"$WORK/unsafe.patch" <<'PATCH'
diff --git a/link b/link
new file mode 120000
index 0000000..fa49b07
--- /dev/null
+++ b/link
@@ -0,0 +1 @@
+target
diff --git a/module b/module
new file mode 160000
index 0000000..1111111
--- /dev/null
+++ b/module
@@ -0,0 +1 @@
+Subproject commit 1111111111111111111111111111111111111111
PATCH
expect_failure "$ROOT/scripts/validate-update-patch.py" \
    "$WORK/unsafe.patch" '["link","module"]'
sed 's/new file mode 120000/new file mode 100600/; /module/,$d' \
    "$WORK/unsafe.patch" >"$WORK/mode.patch"
expect_failure "$ROOT/scripts/validate-update-patch.py" \
    "$WORK/mode.patch" '["link"]'
sed 's|a/link b/link|a/../link b/../link|' "$WORK/unsafe.patch" >"$WORK/traversal.patch"
expect_failure "$ROOT/scripts/validate-update-patch.py" \
    "$WORK/traversal.patch" '["link","module"]'
ok "publisher rejects extra paths, symlinks, submodules, modes, and traversal"

digest="$(cat "$WORK/artifact/update.patch.sha256")"
bundle_digest="$(
    for name in metadata.json result.json update.patch; do
        sha256sum "$WORK/artifact/$name" | awk -v name="$name" '{print $1, name}'
    done | sha256sum | awk '{print $1}'
)"
artifact_relative="${WORK#"$ROOT"/}/artifact"
TARGET_REPO=nanvix/zlib \
    UPDATE_KIND=nanvix \
    UPDATE_BRANCH=automation/update-nanvix-version \
    PR_TITLE="test update" \
    PR_BODY="test update" \
    EXPECTED_BUNDLE_SHA256="$bundle_digest" \
    EXPECTED_PATCH_SHA256="$digest" \
    ARTIFACT_DIR="$artifact_relative" \
    GH_TOKEN=test \
    PUBLISH_CLONE_URL="$WORK/consumer" \
    PUBLISH_WORKDIR="$WORK/published" \
    PUBLISH_VALIDATE_ONLY=true \
    "$ROOT/scripts/publish-update.sh" >/dev/null

(
    cd "$WORK/consumer"
    git reset --hard -q HEAD
    printf 'advanced\n' >other
    git add other
    git commit -qm advanced
)
expect_failure env \
    TARGET_REPO=nanvix/zlib \
    UPDATE_KIND=nanvix \
    UPDATE_BRANCH=automation/update-nanvix-version \
    PR_TITLE="test update" \
    PR_BODY="test update" \
    EXPECTED_BUNDLE_SHA256="$bundle_digest" \
    EXPECTED_PATCH_SHA256="$digest" \
    ARTIFACT_DIR="$WORK/artifact" \
    GH_TOKEN=test \
    PUBLISH_CLONE_URL="$WORK/consumer" \
    PUBLISH_WORKDIR="$WORK/published" \
    PUBLISH_VALIDATE_ONLY=true \
    "$ROOT/scripts/publish-update.sh"
grep -q -- '--force-with-lease' "$ROOT/scripts/publish-update.sh"
if grep -Eq -- '(^|[[:space:]])--force([[:space:]]|$)' \
    "$ROOT/scripts/publish-update.sh"; then
    echo "publisher contains an unsafe plain --force" >&2
    exit 1
fi
ok "publisher applies clean patches, rejects stale refreshes, and uses force-with-lease"

jq '.allowlist += ["README.md"]' \
    "$WORK/artifact/metadata.json" >"$WORK/artifact/metadata.json.tmp"
mv "$WORK/artifact/metadata.json.tmp" "$WORK/artifact/metadata.json"
expect_failure env \
    TARGET_REPO=nanvix/zlib \
    UPDATE_KIND=nanvix \
    UPDATE_BRANCH=automation/update-nanvix-version \
    PR_TITLE="test update" \
    PR_BODY="test update" \
    EXPECTED_BUNDLE_SHA256="$bundle_digest" \
    EXPECTED_PATCH_SHA256="$digest" \
    ARTIFACT_DIR="$WORK/artifact" \
    GH_TOKEN=test \
    PUBLISH_CLONE_URL="$WORK/consumer" \
    PUBLISH_WORKDIR="$WORK/published" \
    PUBLISH_VALIDATE_ONLY=true \
    "$ROOT/scripts/publish-update.sh"
ok "publisher binds metadata and updater results to the transferred digest"

tampered_bundle_digest="$(
    for name in metadata.json result.json update.patch; do
        sha256sum "$WORK/artifact/$name" | awk -v name="$name" '{print $1, name}'
    done | sha256sum | awk '{print $1}'
)"
expect_failure env \
    TARGET_REPO=nanvix/zlib \
    UPDATE_KIND=nanvix \
    UPDATE_BRANCH=automation/update-nanvix-version \
    PR_TITLE="test update" \
    PR_BODY="test update" \
    EXPECTED_BUNDLE_SHA256="$tampered_bundle_digest" \
    EXPECTED_PATCH_SHA256="$digest" \
    ARTIFACT_DIR="$WORK/artifact" \
    GH_TOKEN=test \
    PUBLISH_CLONE_URL="$WORK/consumer" \
    PUBLISH_WORKDIR="$WORK/published" \
    PUBLISH_VALIDATE_ONLY=true \
    "$ROOT/scripts/publish-update.sh"
ok "publisher derives its path policy independently of mutation artifacts"

expect_failure env \
    TARGET_REPO=nanvix/busybox \
    UPDATE_KIND=nanvix \
    UPDATE_BRANCH=automation/update-nanvix-version \
    PR_TITLE="test update" \
    PR_BODY="test update" \
    EXPECTED_BUNDLE_SHA256="$tampered_bundle_digest" \
    EXPECTED_PATCH_SHA256="$digest" \
    ARTIFACT_DIR="$WORK/artifact" \
    GH_TOKEN=test \
    PUBLISH_CLONE_URL="$WORK/consumer" \
    PUBLISH_WORKDIR="$WORK/published" \
    PUBLISH_VALIDATE_ONLY=true \
    "$ROOT/scripts/publish-update.sh"
ok "publisher rejects targets disabled in the trusted registry"

grep -q 'types: \[nanvix-sdk-released\]' \
    "$ROOT/.github/workflows/nanvix-update-nanvix.yml"
[ "$(grep -c 'scripts/resolve-sdk-contract.sh' \
    "$ROOT/.github/workflows/nanvix-update-nanvix.yml")" -eq 1 ]
ok "schedule and SDK dispatch share one verified tuple resolver"

grep -Fq "cp sdk-release.json \"\$clone/.git/sdk-release.json\"" \
    "$ROOT/.github/workflows/nanvix-update-nanvix.yml"
grep -Fq 'UPDATE_TARGET=.git/sdk-release.json' \
    "$ROOT/.github/workflows/nanvix-update-nanvix.yml"
ok "SDK contracts remain confined to each read-only consumer clone"

echo "1..$PASS"
