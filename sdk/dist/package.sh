#!/usr/bin/env bash
set -euo pipefail

umask 022
export LC_ALL=C

bazel_image='gcr.io/bazel-public/bazel:9.2.0@sha256:e59bd66f8daf69f02dbfc18dbd72f0ecfe7926bbda95a5c9eb62433d83b8bd02'
source_repository_slug=${CANDACEOS_SDK_REPOSITORY:?CANDACEOS_SDK_REPOSITORY is required as owner/name}
cleanup_root=''

cleanup() {
  if [[ -n "$cleanup_root" ]]; then
    chmod -R u+w "$cleanup_root" 2>/dev/null || true
    rm -rf -- "$cleanup_root"
  fi
}

trap cleanup EXIT

usage() {
  printf 'usage: CANDACEOS_SDK_REPOSITORY=OWNER/NAME %s OUTPUT_PATH [SOURCE_REF]\n' \
    "$(basename "$0")" >&2
}

die() {
  printf 'candaceos SDK package: %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local command
  for command in awk basename chmod cmp cp dirname docker find git grep gzip id install mkdir mktemp mv rm sha256sum sort tar wc xargs; do
    command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
  done
}

read_allowlist() {
  local repository=$1 revision=$2 destination=$3 path
  git -C "$repository" show "$revision:candaceos/sdk/dist/allowlist.txt" >"$destination"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" =~ ^go/[A-Za-z0-9._/-]+$ ]] && \
      [[ "/$path/" != *'/../'* ]] && \
      [[ "$path" != *'//'* ]] || \
      die "invalid SDK allowlist path: $path"
    git -C "$repository" cat-file -e "$revision:$path" || \
      die "SDK allowlist path is absent at $revision: $path"
  done <"$destination"
}

extract_selected_source() {
  local repository=$1 revision=$2 allowlist=$3 destination=$4
  local -a paths=()
  mapfile -t paths <"$allowlist"
  [[ ${#paths[@]} -gt 0 ]] || die 'SDK allowlist is empty'

  git -C "$repository" archive "$revision" -- "${paths[@]}" | tar -xf - -C "$destination"

  git -C "$repository" ls-tree -r --name-only "$revision" -- "${paths[@]}" | sort >"$destination.expected"
  find "$destination" \( -type f -o -type l \) -printf '%P\n' | sort >"$destination.actual"
  cmp "$destination.expected" "$destination.actual" >/dev/null || \
    die 'selected Git archive differs from the tracked SDK allowlist'
}

install_distribution_metadata() {
  local repository=$1 revision=$2 metadata=$3 destination=$4 template
  git -C "$repository" archive "$revision" -- candaceos/sdk/dist/templates | tar -xf - -C "$metadata"
  for template in .bazelversion MODULE.bazel BUILD.bazel README.md LICENSE LICENSES.md; do
    install -m 0644 \
      "$metadata/candaceos/sdk/dist/templates/$template" \
      "$destination/$template"
  done
  install -m 0644 \
    "$metadata/candaceos/sdk/dist/templates/candacelib.BUILD.bazel" \
    "$destination/candacelib/BUILD.bazel"
}

remove_monorepo_candacelib_override() {
  local go_mod=$1 rewritten=$2
  awk '
    $1 == "github.com/candacelabs/candacelib" { next }
    $1 == "replace" && $2 == "github.com/candacelabs/candacelib" { next }
    { print }
  ' "$go_mod" >"$rewritten"
  install -m 0644 "$rewritten" "$go_mod"
  if grep -Eq '(^|[[:space:]])github\.com/candacelabs/candacelib([[:space:]]|$)' "$go_mod"; then
    die 'archive go.mod still contains the monorepo-local candacelib dependency'
  fi
}

write_manifest() {
  local destination=$1 revision=$2 selection_sha=$3 file_count=$4 allowlist=$5
  local path separator=''
  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "source_repository": "%s",\n' "$source_repository_slug"
    printf '  "source_revision": "%s",\n' "$revision"
    printf '  "source_selection_sha256": "%s",\n' "$selection_sha"
    printf '  "selected_file_count": %s,\n' "$file_count"
    printf '  "bazel_version": "9.2.0",\n'
    printf '  "rules_go_version": "0.62.0",\n'
    printf '  "gazelle_version": "0.52.2",\n'
    printf '  "go_sdk_version": "1.26.5",\n'
    printf '  "source_allowlist": ['
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      printf '%s\n    "%s"' "$separator" "$path"
      separator=,
    done <"$allowlist"
    printf '\n  ]\n}\n'
  } >"$destination/candaceos-sdk-manifest.json"
  chmod 0644 "$destination/candaceos-sdk-manifest.json"
}

run_bazel() {
  local source_root=$1 cache_root=$2 bazel_command=$3
  local -a command_options=(--repository_cache=/bazel-cache/repository)
  shift 3
  if [[ "$bazel_command" == run ]]; then
    command_options+=(--symlink_prefix=/bazel-cache/links/)
  fi
  docker run --rm \
    --platform linux/amd64 \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp/candaceos-bazel-home \
    --volume "$source_root:/workspace" \
    --volume "$cache_root:/bazel-cache" \
    --workdir /workspace \
    "$bazel_image" \
    --output_user_root=/bazel-cache/output \
    "$bazel_command" \
    "${command_options[@]}" \
    "$@"
}

snapshot_bazel_metadata() {
  local source_root=$1 destination=$2
  find "$source_root" -type f \
    \( -name BUILD.bazel -o -name MODULE.bazel -o -name MODULE.bazel.lock \) \
    -print0 | sort -z | xargs -0 sha256sum >"$destination"
}

generate_bazel_metadata() {
  local source_root=$1 cache_root=$2 first=$3 second=$4
  run_bazel "$source_root" "$cache_root" run //:gazelle 1>&2
  run_bazel "$source_root" "$cache_root" mod tidy 1>&2
  snapshot_bazel_metadata "$source_root" "$first"

  run_bazel "$source_root" "$cache_root" run //:gazelle 1>&2
  run_bazel "$source_root" "$cache_root" mod tidy 1>&2
  snapshot_bazel_metadata "$source_root" "$second"
  cmp "$first" "$second" >/dev/null || die 'Gazelle or Bzlmod metadata is not deterministic'

  run_bazel "$source_root" "$cache_root" query //... >/dev/null
}

create_archive() {
  local parent=$1 prefix=$2 destination=$3
  tar \
    --format=ustar \
    --sort=name \
    --mtime=@0 \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -cf - \
    -C "$parent" "$prefix" | gzip -n -9 >"$destination"
}

main() {
  [[ $# -ge 1 && $# -le 2 ]] || {
    usage
    exit 2
  }
  [[ $1 != -h && $1 != --help ]] || {
    usage
    exit 0
  }
  require_commands
  [[ "$source_repository_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
    die "CANDACEOS_SDK_REPOSITORY must be OWNER/NAME: $source_repository_slug"

  local output=$1 source_ref=${2:-HEAD}
  [[ "$output" == *.tar.gz ]] || die 'OUTPUT_PATH must end in .tar.gz'
  mkdir -p "$(dirname "$output")"
  output="$(cd "$(dirname "$output")" && pwd -P)/$(basename "$output")"

  local script_dir repository revision prefix work selection metadata source_root cache_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  repository="$(git -C "$script_dir" rev-parse --show-toplevel)"
  revision="$(git -C "$repository" rev-parse --verify "$source_ref^{commit}")"
  prefix="candaceos-sdk-${revision:0:12}"
  work="$(mktemp -d)"
  cleanup_root="$work"
  selection="$work/selection"
  metadata="$work/metadata"
  source_root="$work/$prefix"
  cache_root="$work/bazel-cache"
  mkdir -p "$selection" "$metadata" "$source_root" "$cache_root"

  read_allowlist "$repository" "$revision" "$work/allowlist.txt"
  extract_selected_source "$repository" "$revision" "$work/allowlist.txt" "$selection"
  cp -a "$selection/go/." "$source_root/"
  remove_monorepo_candacelib_override "$source_root/go.mod" "$work/go.mod"
  install_distribution_metadata "$repository" "$revision" "$metadata" "$source_root"

  local selection_sha file_count
  local -a source_paths=()
  mapfile -t source_paths <"$work/allowlist.txt"
  selection_sha="$(git -C "$repository" ls-tree -r "$revision" -- "${source_paths[@]}" | sha256sum | awk '{print $1}')"
  file_count="$(wc -l <"$selection.expected" | awk '{print $1}')"
  write_manifest "$source_root" "$revision" "$selection_sha" "$file_count" "$work/allowlist.txt"

  generate_bazel_metadata "$source_root" "$cache_root" "$work/bazel.first" "$work/bazel.second"
  find "$source_root" -type d -exec chmod 0755 {} +

  create_archive "$work" "$prefix" "$work/first.tar.gz"
  create_archive "$work" "$prefix" "$work/second.tar.gz"
  cmp "$work/first.tar.gz" "$work/second.tar.gz" >/dev/null || \
    die 'source archive is not reproducible'

  install -m 0644 "$work/first.tar.gz" "$output.tmp"
  mv -f "$output.tmp" "$output"
  (
    cd "$(dirname "$output")"
    sha256sum "$(basename "$output")" >"$(basename "$output").sha256.tmp"
    mv -f "$(basename "$output").sha256.tmp" "$(basename "$output").sha256"
  )

  printf 'archive=%s\n' "$output"
  printf 'sha256=%s\n' "$(sha256sum "$output" | awk '{print $1}')"
}

main "$@"
