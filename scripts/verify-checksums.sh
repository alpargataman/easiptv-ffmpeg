#!/usr/bin/env bash
# Compares the files built in dist/ with a reference SHA256SUMS (the one of a
# published release). BUILD.md is skipped: it records the JVM of the machine
# that built it. Every other file must be byte-for-byte identical.
#
# Usage: scripts/verify-checksums.sh <reference SHA256SUMS> [dist dir]
set -euo pipefail

readonly REFERENCE="${1:?usage: verify-checksums.sh <reference SHA256SUMS> [dist dir]}"
readonly DIST_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist}"
[[ -s "$REFERENCE" ]] || { echo "verify-checksums.sh: $REFERENCE is missing or empty" >&2; exit 2; }

mismatches=0
while read -r expected_hash file_name; do
    [[ "$file_name" == BUILD.md ]] && continue
    actual_hash="$(sha256sum "$DIST_DIR/$file_name" | cut -d' ' -f1)"
    if [[ "$actual_hash" == "$expected_hash" ]]; then
        echo "SAME $file_name $actual_hash"
    else
        echo "DIFF $file_name expected $expected_hash, built $actual_hash"
        mismatches=$((mismatches + 1))
    fi
done < "$REFERENCE"

if (( mismatches > 0 )); then
    echo "verify-checksums.sh: $mismatches file(s) differ from $REFERENCE" >&2
    exit 1
fi
