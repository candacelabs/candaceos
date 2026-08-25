#!/usr/bin/env bash
set -Eeuo pipefail

repository=${CANDACEOS_SDK_REPOSITORY:?CANDACEOS_SDK_REPOSITORY is required as owner/name}
cleanup_root=''

cleanup() {
  if [[ -n "$cleanup_root" ]]; then
    chmod -R u+w "$cleanup_root" 2>/dev/null || true
    rm -rf -- "$cleanup_root"
  fi
}

trap cleanup EXIT

usage() {
  printf 'usage: CANDACEOS_SDK_REPOSITORY=OWNER/NAME %s [SOURCE_REF]\n' \
    "$(basename "$0")" >&2
}

die() {
  printf 'candaceos SDK publish: %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local command_name
  for command_name in awk base64 basename chmod gh git grep mktemp openssl rm sha256sum sort tar tr; do
    command -v "$command_name" >/dev/null 2>&1 || \
      die "required command is unavailable: $command_name"
  done
}

release_exists() {
  local tag=$1 error_path=$2
  if gh release view "$tag" --repo "$repository" --json tagName \
    >/dev/null 2>"$error_path"; then
    return 0
  fi
  if grep -Fxq 'release not found' "$error_path"; then
    return 1
  fi
  die "checking release $tag: $(<"$error_path")"
}

ensure_release() {
  local tag=$1 revision=$2 error_path=$3
  if ! release_exists "$tag" "$error_path"; then
    if ! gh release create "$tag" \
      --repo "$repository" \
      --target "$revision" \
      --title "CandaceOS SDK $revision" \
      --notes "Deterministic CandaceOS SDK source distribution for commit $revision." \
      --prerelease \
      --latest=false \
      >/dev/null; then
      release_exists "$tag" "$error_path" || \
        die "creating release $tag"
    fi
  fi

  local released_revision
  released_revision="$(gh api "repos/$repository/commits/$tag" --jq .sha)" || \
    die "resolving release tag $tag"
  [[ "$released_revision" == "$revision" ]] || \
    die "release tag $tag resolves to $released_revision, expected $revision"
}

asset_coordinates() {
  local tag=$1 asset_name=$2
  local -a matches=()
  local assets name id api_url
  assets="$(
    gh release view "$tag" \
      --repo "$repository" \
      --json assets \
      --jq '.assets[] | [.name, .apiUrl] | @tsv'
  )" || die "listing release assets for $tag"
  while IFS=$'\t' read -r name api_url; do
    [[ -n "$name" ]] || continue
    [[ "$name" == "$asset_name" ]] || continue
    id=${api_url##*/}
    [[ "$id" =~ ^[0-9]+$ ]] && \
      [[ "$api_url" == "https://api.github.com/repos/$repository/releases/assets/$id" ]] || \
      die "release asset $asset_name returned an invalid API URL"
    matches+=("$id"$'\t'"$api_url")
  done <<<"$assets"
  [[ ${#matches[@]} -le 1 ]] || \
    die "release $tag contains duplicate assets named $asset_name"
  if [[ ${#matches[@]} == 1 ]]; then
    printf '%s\n' "${matches[0]}"
  fi
}

ensure_asset() {
  local tag=$1 path=$2
  local asset_name expected_digest coordinates id api_url actual_digest
  asset_name="$(basename "$path")"
  expected_digest="sha256:$(sha256sum "$path" | awk '{print $1}')"
  coordinates="$(asset_coordinates "$tag" "$asset_name")"
  if [[ -z "$coordinates" ]]; then
    gh release upload "$tag" "$path" --repo "$repository" >/dev/null || \
      die "uploading release asset $asset_name"
    coordinates="$(asset_coordinates "$tag" "$asset_name")"
    [[ -n "$coordinates" ]] || \
      die "uploaded release asset $asset_name is absent"
  fi
  IFS=$'\t' read -r id api_url <<<"$coordinates"
  [[ "$id" =~ ^[0-9]+$ && "$api_url" == https://api.github.com/* ]] || \
    die "release asset $asset_name returned invalid coordinates"
  actual_digest="$(gh api "$api_url" --jq '.digest // ""')" || \
    die "reading release asset digest for $asset_name"
  [[ "$actual_digest" == "$expected_digest" ]] || \
    die "release asset $asset_name has $actual_digest, expected $expected_digest; refusing to overwrite it"
  printf '%s\t%s\n' "$id" "$api_url"
}

archive_prefix() {
  local archive_path=$1
  local -a roots=()
  mapfile -t roots < <(tar -tzf "$archive_path" | awk -F/ 'NF { print $1 }' | sort -u)
  [[ ${#roots[@]} == 1 && "${roots[0]}" =~ ^candaceos-sdk-[0-9a-f]{12}$ ]] || \
    die 'packaged SDK archive has an invalid top-level directory'
  printf '%s\n' "${roots[0]}"
}

main() {
  [[ $# -le 1 ]] || {
    usage
    exit 2
  }
  [[ ${1:-} != -h && ${1:-} != --help ]] || {
    usage
    exit 0
  }
  require_commands
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
    die "CANDACEOS_SDK_REPOSITORY must be OWNER/NAME: $repository"

  local source_ref=${1:-HEAD}
  local script_dir source_repository revision tag prefix work packager
  local archive checksum archive_sha integrity release_url
  local archive_coordinates archive_id archive_api_url
  local checksum_coordinates checksum_id checksum_api_url
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  source_repository="$(git -C "$script_dir" rev-parse --show-toplevel)"
  revision="$(git -C "$source_repository" rev-parse --verify "$source_ref^{commit}")" || \
    die "invalid source ref: $source_ref"
  tag="candaceos-sdk-$revision"
  prefix="candaceos-sdk-${revision:0:12}"
  work="$(mktemp -d)"
  cleanup_root="$work"
  archive="$work/$tag.tar.gz"
  checksum="$archive.sha256"
  packager="${CANDACEOS_SDK_PACKAGER:-$script_dir/dist/package.sh}"
  [[ -x "$packager" ]] || die "SDK packager is not executable: $packager"

  "$packager" "$archive" "$revision" >/dev/null
  [[ -f "$archive" && -f "$checksum" ]] || \
    die 'SDK packager did not produce the archive and checksum assets'
  [[ "$(archive_prefix "$archive")" == "$prefix" ]] || \
    die "SDK archive prefix does not match commit $revision"
  archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
  grep -Fxq "$archive_sha  $(basename "$archive")" "$checksum" || \
    die 'SDK checksum asset does not authenticate the packaged archive'
  integrity="sha256-$(openssl dgst -sha256 -binary "$archive" | base64 | tr -d '\n')"

  ensure_release "$tag" "$revision" "$work/release-error"
  archive_coordinates="$(ensure_asset "$tag" "$archive")"
  IFS=$'\t' read -r archive_id archive_api_url <<<"$archive_coordinates"
  checksum_coordinates="$(ensure_asset "$tag" "$checksum")"
  IFS=$'\t' read -r checksum_id checksum_api_url <<<"$checksum_coordinates"
  release_url="$(gh release view "$tag" --repo "$repository" --json url --jq .url)" || \
    die "reading release URL for $tag"

  printf 'repository=%s\n' "$repository"
  printf 'source_revision=%s\n' "$revision"
  printf 'release_tag=%s\n' "$tag"
  printf 'release_url=%s\n' "$release_url"
  printf 'archive_name=%s\n' "$(basename "$archive")"
  printf 'archive_type=tar.gz\n'
  printf 'asset_id=%s\n' "$archive_id"
  printf 'api_url=%s\n' "$archive_api_url"
  printf 'sha256=%s\n' "$archive_sha"
  printf 'integrity=%s\n' "$integrity"
  printf 'strip_prefix=%s\n' "$prefix"
  printf 'checksum_asset_id=%s\n' "$checksum_id"
  printf 'checksum_api_url=%s\n' "$checksum_api_url"
}

main "$@"
