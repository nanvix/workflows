# Nanvix reusable workflows

## Consumer update registry

`consumer-registry.json` is the only consumer and tier source. Each entry
declares its tier, SDK provider/toolchain, derived-image use, and independent
`update_nanvix` / `update_zutils` kill switches. `scripts/select-tier-repos.sh`
validates the registry and derives schedule or dispatch selections from it.

The six cron entries in each updater workflow mirror the registry's tier
offsets. `tests/run-tests.sh` rejects drift between those tuples.

The final Nanvix update tier contains `nanvix-python`. When that consumer is
current or has a publishable update, the tier dispatches the exact verified SDK
version to `nanvix-distro`. The distro independently preflights its complete
release set, so blocked final-tier updates do not advertise readiness and a
premature candidate remains a safe deferred no-op.

## Secure consumer updates

`nanvix-update-nanvix.yml` and `nanvix-update-zutils.yml` share this boundary:

1. A mutation job clones public consumers without credentials, installs the
   selected zutils implementation, runs its standalone updater, validates its
   structured result and exact changed-file allowlist, then uploads a binary
   patch plus digests binding the patch, metadata, and result.
2. `publish-update.yml` independently selects the kind-specific path policy,
   creates a GitHub App installation token scoped to one consumer, and applies
   the expected patch to a fresh default-branch clone. It rejects unsafe paths,
   modes, symlinks, submodules, and mutation-supplied policy changes, and pushes
   only with `--force-with-lease`. It never executes consumer code.

Configure `CONSUMER_UPDATE_APP_ID` and
`CONSUMER_UPDATE_APP_PRIVATE_KEY` in this repository. The App requires
contents and pull-request write permissions on registered consumers.
Until the App is configured, the existing `DISPATCH_TOKEN` is accepted only
inside the credential-free publisher boundary as a transitional fallback.

Blocked dependency resolution creates no publication artifact. Updated,
current, blocked, and failed consumers appear separately in the run summary.
Automation branches remain `automation/update-nanvix-version` and
`automation/update-zutils-version`, preserving guarded auto-merge.
BusyBox is enabled after canonicalizing its Nanvix port and making that port
the repository default branch.

The Nanvix updater accepts the `nanvix-sdk-released` dispatch contract from
`nanvix/sdk`. It compares the payload with the authoritative GitHub Release
`sdk-release.json` asset. Scheduled/manual runs read that same asset, so all
events resolve an identical immutable tuple. Repeated dispatches are naturally
idempotent. `ZUTILS_UPDATE_VERSION` pins the command implementation used by the
SDK updater.

The zutils updater resolves the latest stable GitHub Release unless a manual
tag is supplied. It installs the release wheel and templates archive only after
checking their GitHub-provided SHA-256 digests.

## Reusable CI

`.nanvix/nanvix.toml` and `.nanvix/nanvix.lock` are mandatory and authoritative.
Legacy manifests and caller-supplied build images are rejected.

SDK CI:

- exports resolver provenance to Linux build, benchmark, Windows, and release;
- pulls the effective image by digest;
- compares lock provenance, `/opt/nanvix/nanvix-sdk.json`, and
  `dev.nanvix.sdk.*` OCI labels before building;
- uses release tags `<package-version>-nanvix-<runtime>-sdk.N`;
- publishes `nanvix.lock` and `sdk-provenance.json`; and
- refuses to replace an existing SDK release carrying different provenance.

Run local foundation checks with:

```sh
tests/run-tests.sh
```
