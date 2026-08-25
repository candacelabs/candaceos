#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" -eq 2 ]] || {
  printf 'Usage: record-bootstrap-revision.sh CONTROL_DIR REVISION\n' >&2
  exit 2
}

control_dir=$1
revision=$2
[[ "$control_dir" == /* ]] || {
  printf 'record-bootstrap-revision: CONTROL_DIR must be absolute\n' >&2
  exit 2
}
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'record-bootstrap-revision: REVISION must be a full lowercase Git commit ID\n' >&2
  exit 2
}
mkdir -p "$control_dir"

current_file="$control_dir/current"
if [[ -f "$current_file" ]]; then
  current=$(tr -d '\r\n' <"$current_file")
  [[ "$current" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'record-bootstrap-revision: existing current revision is malformed\n' >&2
    exit 1
  }
  # A later bootstrap may run from a different source checkout. Never replace
  # the revision already advanced by a verified updater deployment.
  exit 0
fi

write_state() {
  local path=$1 value=$2 tmp
  tmp=$(mktemp "$control_dir/.bootstrap-state.XXXXXX")
  printf '%s\n' "$value" >"$tmp"
  mv -f "$tmp" "$path"
}

# `current` is the commit marker and is written last. If the process is
# interrupted first, the next bootstrap safely repairs the incomplete record.
write_state "$control_dir/current-origin" bootstrap
printf '{"at":"%s","candidate":"%s","previous":"","outcome":"bootstrap","rollback":"not-needed"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$revision" \
  >>"$control_dir/deployments.jsonl"
write_state "$current_file" "$revision"
