#!/usr/bin/env python3
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

"""Validate paths and modes in a Git binary patch before trusted publication."""

from __future__ import annotations

import json
import re
import shlex
import sys
from pathlib import PurePosixPath

VALID_MODES = {"100644", "100755"}
FORBIDDEN_MODES = {"120000", "160000"}


def fail(message: str) -> None:
    """Exit with one concise validation error."""
    raise SystemExit(f"error: {message}")


def validate_path(raw: str) -> str:
    """Validate and normalize one a/ or b/ patch path."""
    if raw == "/dev/null":
        return raw
    if not raw.startswith(("a/", "b/")):
        fail(f"patch path has no a/ or b/ prefix: {raw}")
    path = PurePosixPath(raw[2:])
    if path.is_absolute() or not path.parts or ".." in path.parts:
        fail(f"unsafe patch path: {raw}")
    normalized = path.as_posix()
    if normalized.startswith("/") or "\0" in normalized:
        fail(f"unsafe patch path: {raw}")
    return normalized


def main() -> None:
    """Validate a patch against a JSON allowlist and print its changed paths."""
    if len(sys.argv) != 3:
        fail("usage: validate-update-patch.py PATCH ALLOWLIST_JSON")
    patch_path, allowlist_json = sys.argv[1:]
    try:
        allowlist = set(json.loads(allowlist_json))
    except (json.JSONDecodeError, TypeError) as exc:
        fail(f"invalid allowlist JSON: {exc}")
    if not allowlist or not all(isinstance(item, str) for item in allowlist):
        fail("allowlist must be a non-empty JSON string array")

    changed: set[str] = set()
    current: str | None = None
    with open(patch_path, encoding="utf-8", errors="surrogateescape") as patch:
        for raw_line in patch:
            line = raw_line.rstrip("\n")
            if line.startswith("diff --git "):
                try:
                    fields = shlex.split(line)
                except ValueError as exc:
                    fail(f"malformed diff header: {exc}")
                if len(fields) != 4:
                    fail("malformed diff header")
                old_path = validate_path(fields[2])
                new_path = validate_path(fields[3])
                if old_path != new_path:
                    fail("renames and copies are not permitted")
                current = old_path
                changed.add(current)
            elif line.startswith(("rename from ", "rename to ", "copy from ", "copy to ")):
                fail("renames and copies are not permitted")
            elif re.match(r"^(old mode|new mode|new file mode|deleted file mode) ", line):
                mode = line.rsplit(" ", maxsplit=1)[-1]
                if mode in FORBIDDEN_MODES:
                    fail(f"symlink or submodule mode is not permitted: {mode}")
                if mode not in VALID_MODES:
                    fail(f"unexpected file mode: {mode}")
            elif line.startswith(("--- ", "+++ ")):
                header_path = validate_path(line[4:].split("\t", maxsplit=1)[0])
                if header_path != "/dev/null" and (
                    current is None
                    or header_path != current
                    or header_path not in allowlist
                ):
                    fail(f"file header disagrees with its diff path: {header_path}")

    if not changed:
        fail("patch contains no file changes")
    unexpected = changed - allowlist
    if unexpected:
        fail(f"patch changes unexpected paths: {', '.join(sorted(unexpected))}")
    for path in sorted(changed):
        print(path)


if __name__ == "__main__":
    main()
