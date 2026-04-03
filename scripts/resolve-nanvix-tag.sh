#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.
#
# Resolves the latest nanvix/nanvix release tag and writes the tag and
# stripped version to $GITHUB_OUTPUT.
#
# Required environment:
#   GH_TOKEN          — GitHub token with read access to nanvix/nanvix.
#   GITHUB_OUTPUT     — GitHub Actions output file.

set -euo pipefail

TAG=$(gh api repos/nanvix/nanvix/releases/latest --jq '.tag_name')
if [ -z "$TAG" ]; then
	echo "::error::Could not resolve latest release tag for nanvix/nanvix"
	exit 1
fi

# Strip the leading 'v' prefix if present (e.g. v0.12.337 -> 0.12.337).
VERSION="${TAG#v}"
echo "tag=$TAG" >>"$GITHUB_OUTPUT"
echo "version=$VERSION" >>"$GITHUB_OUTPUT"
echo "Resolved latest nanvix tag: $TAG (version: $VERSION)"
