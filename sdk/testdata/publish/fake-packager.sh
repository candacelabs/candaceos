#!/usr/bin/env bash
set -euo pipefail

output=$1
revision=$2
work=$(mktemp -d)

cleanup() {
  rm -rf -- "$work"
}

trap cleanup EXIT

prefix="candaceos-sdk-${revision:0:12}"
mkdir -p "$work/$prefix"
printf '%s\n' "$revision" >"$work/$prefix/source-revision"
tar \
  --format=ustar \
  --sort=name \
  --mtime=@0 \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -cf - \
  -C "$work" "$prefix" | gzip -n -9 >"$output"
(
  cd "$(dirname "$output")"
  sha256sum "$(basename "$output")" >"$(basename "$output").sha256"
)
