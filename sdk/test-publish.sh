#!/usr/bin/env bash
set -Eeuo pipefail

cleanup_root=''

cleanup() {
  if [[ -n "$cleanup_root" ]]; then
    chmod -R u+w "$cleanup_root" 2>/dev/null || true
    rm -rf -- "$cleanup_root"
  fi
}

trap cleanup EXIT

die() {
  printf 'candaceos SDK publish test: %s\n' "$*" >&2
  exit 1
}

main() {
  local script_dir repository revision temporary bin state first second failure
  local create_count upload_count helper_output token_file
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  repository="$(git -C "$script_dir" rev-parse --show-toplevel)"
  revision="$(git -C "$repository" rev-parse HEAD)"
  temporary="$(mktemp -d /tmp/candaceos-sdk-publish-test.XXXXXX)"
  cleanup_root="$temporary"
  bin="$temporary/bin"
  state="$temporary/state"
  first="$temporary/first.out"
  second="$temporary/second.out"
  failure="$temporary/failure.err"
  mkdir -p "$bin" "$state"
  install -m 0755 "$script_dir/testdata/publish/fake-gh" "$bin/gh"

  export CANDACEOS_SDK_REPOSITORY=example-org/example-repo

  PATH="$bin:$PATH" \
    FAKE_GH_STATE="$state" \
    CANDACEOS_SDK_PACKAGER="$script_dir/testdata/publish/fake-packager.sh" \
    "$script_dir/publish.sh" HEAD >"$first"

  grep -Fxq "repository=example-org/example-repo" "$first" || die 'repository output is absent'
  grep -Fxq "source_revision=$revision" "$first" || die 'source revision output is absent'
  grep -Fxq "release_tag=candaceos-sdk-$revision" "$first" || die 'release tag output is absent'
  grep -Fxq 'archive_type=tar.gz' "$first" || die 'archive type output is absent'
  grep -Eq '^asset_id=[0-9]+$' "$first" || die 'asset ID output is absent'
  grep -Eq '^api_url=https://api\.github\.com/.+$' "$first" || die 'asset API URL output is absent'
  grep -Eq '^sha256=[0-9a-f]{64}$' "$first" || die 'SHA-256 output is absent'
  grep -Eq '^integrity=sha256-[A-Za-z0-9+/]+={0,2}$' "$first" || die 'SRI output is absent'
  grep -Fxq "strip_prefix=candaceos-sdk-${revision:0:12}" "$first" || die 'strip prefix output is absent'

  create_count=$(grep -c '^release create ' "$state/calls.log")
  upload_count=$(grep -c '^release upload ' "$state/calls.log")
  [[ "$create_count" == 1 && "$upload_count" == 2 ]] || \
    die "first publish made $create_count releases and $upload_count uploads"

  PATH="$bin:$PATH" \
    FAKE_GH_STATE="$state" \
    CANDACEOS_SDK_PACKAGER="$script_dir/testdata/publish/fake-packager.sh" \
    "$script_dir/publish.sh" HEAD >"$second"
  cmp "$first" "$second" >/dev/null || die 'idempotent publish output changed'
  [[ "$(grep -c '^release create ' "$state/calls.log")" == 1 ]] || \
    die 'idempotent publish created another release'
  [[ "$(grep -c '^release upload ' "$state/calls.log")" == 2 ]] || \
    die 'idempotent publish uploaded another asset'

  sed -i 's/sha256:[0-9a-f]\{64\}$/sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
    "$state/assets/1001.meta"
  if PATH="$bin:$PATH" \
    FAKE_GH_STATE="$state" \
    CANDACEOS_SDK_PACKAGER="$script_dir/testdata/publish/fake-packager.sh" \
    "$script_dir/publish.sh" HEAD >/dev/null 2>"$failure"; then
    die 'publish accepted a mismatched existing release asset'
  fi
  grep -Fq 'refusing to overwrite it' "$failure" || \
    die 'mismatched asset failure did not explain the non-overwrite contract'
  [[ "$(grep -c '^release upload ' "$state/calls.log")" == 2 ]] || \
    die 'mismatched asset was uploaded over'

  token_file="$temporary/github-token"
  (umask 077; printf 'dummy_token\n' >"$token_file")
  helper_output="$(
    printf '{"uri":"https://api.github.com/repos/example-org/example-repo/releases/assets/1001"}\n' |
      CANDACEOS_SDK_GITHUB_TOKEN_FILE="$token_file" \
        "$script_dir/github-credential-helper.sh" get 2>"$temporary/helper.err"
  )"
  [[ ! -s "$temporary/helper.err" ]] || die 'credential helper wrote to stderr'
  [[ "$helper_output" == *'"Authorization":["Bearer dummy_token"]'* ]] || \
    die 'credential helper omitted bearer authorization'
  [[ "$helper_output" == *'"Accept":["application/octet-stream"]'* ]] || \
    die 'credential helper omitted the release-asset media type'
  local spoofed_request
  for spoofed_request in \
    '{"uri":"https://api.github.com.evil.invalid/archive"}' \
    '{"uri":"https://example.invalid/archive","nested":{"uri":"https://api.github.com/repos/example-org/example-repo/releases/assets/1001"}}'; do
    if printf '%s\n' "$spoofed_request" |
      CANDACEOS_SDK_GITHUB_TOKEN_FILE="$token_file" \
        "$script_dir/github-credential-helper.sh" get \
        >"$temporary/unsupported.out" 2>"$temporary/unsupported.err"; then
      die 'credential helper returned a token for a spoofed host'
    fi
    [[ ! -s "$temporary/unsupported.out" && ! -s "$temporary/unsupported.err" ]] || \
      die 'credential helper logged output for a spoofed host'
  done

  chmod 0644 "$token_file"
  if printf '{"uri":"https://api.github.com/repos/example-org/example-repo/releases/assets/1001"}\n' |
    CANDACEOS_SDK_GITHUB_TOKEN_FILE="$token_file" \
      "$script_dir/github-credential-helper.sh" get \
      >"$temporary/permissive.out" 2>"$temporary/permissive.err"; then
    die 'credential helper accepted a permissive token file'
  fi
  [[ ! -s "$temporary/permissive.out" && ! -s "$temporary/permissive.err" ]] || \
    die 'credential helper logged output for a permissive token file'

  if printf '{"uri":"https://api.github.com/repos/example-org/example-repo/releases/assets/1001"}\n' |
    CANDACEOS_SDK_GITHUB_TOKEN='rejected_direct_token' \
    GH_TOKEN='rejected_gh_token' \
    GITHUB_TOKEN='rejected_github_token' \
      "$script_dir/github-credential-helper.sh" get \
      >"$temporary/direct-environment.out" 2>"$temporary/direct-environment.err"; then
    die 'credential helper accepted a direct token environment variable'
  fi
  [[ ! -s "$temporary/direct-environment.out" && \
    ! -s "$temporary/direct-environment.err" ]] || \
    die 'credential helper logged output for a direct token environment variable'

  helper_output="$(
    printf '{"uri":"https://api.github.com/repos/example-org/example-repo/releases/assets/1001"}\n' |
      PATH="$bin:$PATH" \
      FAKE_GH_STATE="$state" \
        "$script_dir/github-credential-helper.sh" get 2>"$temporary/fallback.err"
  )"
  [[ ! -s "$temporary/fallback.err" ]] || die 'credential helper fallback wrote to stderr'
  [[ "$helper_output" == *'"Authorization":["Bearer fake-gh-token"]'* ]] || \
    die 'credential helper did not use authenticated gh fallback'

  if CANDACEOS_SDK_REPOSITORY= PATH="$bin:$PATH" FAKE_GH_STATE="$state" \
    CANDACEOS_SDK_PACKAGER="$script_dir/testdata/publish/fake-packager.sh" \
    "$script_dir/publish.sh" HEAD >/dev/null 2>&1; then
    die 'publish ran without a configured release repository'
  fi

  printf 'CandaceOS SDK publication tests passed: release=1 uploads=2 rerun_uploads=0 mismatched_asset=blocked spoofed_host=blocked token_file_mode=0600 direct_token_env=rejected gh_fallback=passed credential_output=quiet\n'
}

main "$@"
