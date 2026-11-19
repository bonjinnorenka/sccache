#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <package-version> <tag>" >&2
  exit 2
fi

version="$1"
tag="$2"
version_regex='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-fork\.[1-9][0-9]*)?$'

if [[ ! "$version" =~ $version_regex ]]; then
  echo "Unsupported package version: '$version'" >&2
  exit 1
fi

if [[ "$tag" != "v$version" ]]; then
  echo "Tag '$tag' must exactly match package version '$version' as 'v$version'" >&2
  exit 1
fi
