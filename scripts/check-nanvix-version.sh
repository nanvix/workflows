#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.
#
# Reads the current nanvix-version value from .nanvix/nanvix.toml and
# writes it to $GITHUB_OUTPUT. Fails if the key is missing or appears
# more than once.
#
# Required environment:
#   GITHUB_OUTPUT — GitHub Actions output file.

set -euo pipefail

TOML=".nanvix/nanvix.toml"
if [ ! -f "$TOML" ]; then
	echo "::error::$TOML not found"
	exit 1
fi

CURRENT=$(awk '
  /^[[:space:]]*nanvix-version[[:space:]]*=[[:space:]]*"[^"]*"/ {
    match($0, /"[^"]*"/)
    value = substr($0, RSTART + 1, RLENGTH - 2)
    count++
  }
  END {
    if (count == 0) exit 1
    if (count > 1) exit 2
    print value
  }
' "$TOML") || {
	status=$?
	if [ "$status" -eq 1 ]; then
		echo "::error::No nanvix-version value found in $TOML"
	elif [ "$status" -eq 2 ]; then
		echo "::error::Multiple nanvix-version values found in $TOML"
	else
		echo "::error::Failed to parse nanvix-version from $TOML"
	fi
	exit 1
}

echo "version=$CURRENT" >>"$GITHUB_OUTPUT"
echo "Current nanvix-version: $CURRENT"
