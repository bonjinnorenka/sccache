#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
verifier="$script_dir/verify-release-version.sh"

expect_accept() {
  if ! bash "$verifier" "$1" "$2"; then
    echo "Expected version '$1' and tag '$2' to be accepted" >&2
    exit 1
  fi
}

expect_reject() {
  if bash "$verifier" "$1" "$2" >/dev/null 2>&1; then
    echo "Expected version '$1' and tag '$2' to be rejected" >&2
    exit 1
  fi
}

expect_accept 0.19.0 v0.19.0
expect_accept 0.19.0-fork.1 v0.19.0-fork.1
expect_accept 0.19.0-fork.2 v0.19.0-fork.2
expect_accept 0.20.0-fork.1 v0.20.0-fork.1

expect_reject 0.19.0-fork.1 v0.19.0
expect_reject 0.19.0-fork.1 v0.19.0-fork.2
expect_reject 0.19.0-fork.0 v0.19.0-fork.0
expect_reject 0.19.0-fork.01 v0.19.0-fork.01
expect_reject 0.19.0-fork.1-extra v0.19.0-fork.1-extra
expect_reject invalid vinvalid
expect_reject 01.19.0 v01.19.0

echo "Release version checks passed"
