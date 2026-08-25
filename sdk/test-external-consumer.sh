#!/usr/bin/env bash
set -Eeuo pipefail

bazel_image='gcr.io/bazel-public/bazel:9.2.0@sha256:e59bd66f8daf69f02dbfc18dbd72f0ecfe7926bbda95a5c9eb62433d83b8bd02'
http_image='busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0'
cleanup_root=
http_container=
http_container_created=false
test_network=
test_network_created=false

die() {
  printf 'candaceos external consumer: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name=$1
  command -v "$command_name" >/dev/null || die "$command_name is required"
}

cleanup() {
  if [[ "$http_container_created" == true ]]; then
    [[ "$http_container" =~ ^candaceos-sdk-http-[[:alnum:]]+$ ]] || {
      printf 'candaceos external consumer: refusing to remove unexpected container: %s\n' "$http_container" >&2
      return 1
    }
    docker container rm --force -- "$http_container" >/dev/null 2>&1 || true
  fi
  if [[ "$test_network_created" == true ]]; then
    [[ "$test_network" =~ ^candaceos-sdk-test-[[:alnum:]]+$ ]] || {
      printf 'candaceos external consumer: refusing to remove unexpected network: %s\n' "$test_network" >&2
      return 1
    }
    docker network rm -- "$test_network" >/dev/null 2>&1 || true
  fi
  [[ -n "$cleanup_root" ]] || return 0
  [[ "$cleanup_root" == /tmp/candaceos-external-consumer.* ]] || {
    printf 'candaceos external consumer: refusing to remove unexpected path: %s\n' "$cleanup_root" >&2
    return 1
  }
  chmod -R u+w "$cleanup_root" 2>/dev/null || true
  rm -rf -- "$cleanup_root"
}

archive_prefix() {
  local archive_path=$1
  local -a roots
  mapfile -t roots < <(tar -tzf "$archive_path" | awk -F/ 'NF { print $1 }' | sort -u)
  [[ "${#roots[@]}" == 1 ]] || die "SDK archive must contain exactly one top-level directory"
  [[ "${roots[0]}" =~ ^candaceos-sdk-[0-9a-f]{12}$ ]] || \
    die "SDK archive has an invalid top-level directory: ${roots[0]}"
  printf '%s\n' "${roots[0]}"
}

materialize_http_archive_module() {
  local template_path=$1 output_path=$2 archive_sha256=$3 prefix=$4 archive_url=$5
  sed \
    -e "s/@CANDACEOS_ARCHIVE_SHA256@/$archive_sha256/g" \
    -e "s/@CANDACEOS_ARCHIVE_PREFIX@/$prefix/g" \
    -e "s|@CANDACEOS_ARCHIVE_URL@|$archive_url|g" \
    "$template_path" >"$output_path"
}

materialize_archive_override_module() {
  local template_path=$1 output_path=$2 archive_integrity=$3 prefix=$4 archive_url=$5
  sed \
    -e "s|@CANDACEOS_ARCHIVE_INTEGRITY@|$archive_integrity|g" \
    -e "s/@CANDACEOS_ARCHIVE_PREFIX@/$prefix/g" \
    -e "s|@CANDACEOS_ARCHIVE_URL@|$archive_url|g" \
    "$template_path" >"$output_path"
}

sha256_integrity() {
  local archive_sha256=$1
  printf 'sha256-'
  printf '%s' "$archive_sha256" | xxd -r -p | base64 | tr -d '\n'
  printf '\n'
}

start_archive_server() {
  local artifacts=$1 credential_state=$2 suffix=$3 attempt
  test_network="candaceos-sdk-test-$suffix"
  http_container="candaceos-sdk-http-$suffix"
  docker network create "$test_network" >/dev/null
  test_network_created=true
  docker run --detach \
    --name "$http_container" \
    --network "$test_network" \
    --volume "$artifacts:/www:ro" \
    --volume "$credential_state:/requests" \
    "$http_image" \
    httpd -f -p 8080 -h /www >/dev/null
  http_container_created=true
  for ((attempt = 0; attempt < 50; attempt++)); do
    if docker exec "$http_container" \
      wget -q -O /dev/null http://127.0.0.1:8080/candaceos-sdk.tar.gz; then
      return 0
    fi
    sleep 0.1
  done
  die 'SDK archive HTTP server did not become ready'
}

run_credential_cache_consumer() {
  local consumer=$1 bazel_home=$2 bazel_output=$3 network=$4
  local token_directory=$5 credential_state=$6
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --env HOME=/bazel-home \
    --env CANDACEOS_SDK_GITHUB_TOKEN_FILE=/run/secrets/github-token \
    --network "$network" \
    --volume "$consumer:/workspace" \
    --volume "$bazel_home:/bazel-home" \
    --volume "$bazel_output:/bazel-output" \
    --volume "$token_directory:/run/secrets" \
    --volume "$credential_state:/credential-test-state" \
    --workdir /workspace \
    --entrypoint /bin/bash \
    "$bazel_image" \
    -euo pipefail -c '
      bazel --output_user_root=/bazel-output build @credential_first//:payload.txt

      printf "%s\n" credential-cache-rotated >/run/secrets/github-token
      chmod 0600 /run/secrets/github-token
      printf "%s\n" credential-cache-rotated >/credential-test-state/expected-token
      bazel --output_user_root=/bazel-output build @credential_rotated//:payload.txt

      rm -- /run/secrets/github-token
      printf "%s\n" credential-cache-deleted >/credential-test-state/expected-token
      if bazel --output_user_root=/bazel-output build @credential_deleted//:payload.txt; then
        printf "deleted token file was accepted\n" >&2
        exit 1
      fi
    '
}

run_external_consumer() {
  local consumer=$1 bazel_home=$2 bazel_output=$3 network=$4
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --env HOME=/bazel-home \
    --network "$network" \
    --volume "$consumer:/workspace" \
    --volume "$bazel_home:/bazel-home" \
    --volume "$bazel_output:/bazel-output" \
    --workdir /workspace \
    --entrypoint /bin/bash \
    "$bazel_image" \
    -euo pipefail -c '
      bazel --batch --output_user_root=/bazel-output build //cmd:custom-candaceos
      bazel --batch --output_user_root=/bazel-output test //:external_harness_test --test_output=errors
    '
}

main() {
  local script_dir repository revision fixture_root credential_fixture packager temporary artifacts suffix
  local http_archive_consumer archive_override_consumer
  local credential_cache_consumer credential_state token_directory
  local first_archive second_archive first_sha second_sha prefix archive_url archive_integrity
  local bootstrap_build bootstrap_source helper_count first_authorization_count rotated_authorization_count

  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  fixture_root="$script_dir/testdata/external-consumer"
  credential_fixture="$script_dir/testdata/credential-cache"
  packager="$script_dir/dist/package.sh"

  for command_name in awk base64 chmod cmp cp docker git mktemp rm sed sha256sum sleep sort tar tr xxd; do
    require_command "$command_name"
  done
  [[ -x "$packager" ]] || die "SDK packager is not executable: $packager"
  docker info >/dev/null 2>&1 || die "Docker is unavailable"
  repository=$(git -C "$script_dir" rev-parse --show-toplevel)
  revision=$(git -C "$repository" rev-parse --verify 'HEAD^{commit}')

  temporary=$(mktemp -d /tmp/candaceos-external-consumer.XXXXXX)
  cleanup_root=$temporary
  trap cleanup EXIT
  artifacts="$temporary/artifacts"
  http_archive_consumer="$temporary/http-archive-consumer"
  archive_override_consumer="$temporary/archive-override-consumer"
  credential_cache_consumer="$temporary/credential-cache-consumer"
  credential_state="$temporary/credential-state"
  token_directory="$temporary/credential-token"
  mkdir -p \
    "$artifacts/cgi-bin" \
    "$http_archive_consumer" \
    "$archive_override_consumer" \
    "$credential_cache_consumer/tools" \
    "$credential_state" \
    "$token_directory" \
    "$temporary/http-archive-bazel-home" \
    "$temporary/http-archive-bazel-output" \
    "$temporary/archive-override-bazel-home" \
    "$temporary/archive-override-bazel-output" \
    "$temporary/credential-cache-bazel-home" \
    "$temporary/credential-cache-bazel-output"

  cp "$credential_fixture/credential-server" "$artifacts/cgi-bin/credentials"
  chmod 0755 "$artifacts/cgi-bin/credentials"

  first_archive="$artifacts/candaceos-sdk.tar.gz"
  second_archive="$artifacts/candaceos-sdk-second.tar.gz"
  CANDACEOS_SDK_REPOSITORY=example-org/example-repo \
    "$packager" "$first_archive" "$revision" >/dev/null
  CANDACEOS_SDK_REPOSITORY=example-org/example-repo \
    "$packager" "$second_archive" "$revision" >/dev/null
  cmp -s "$first_archive" "$second_archive" || die "SDK archive is not deterministic"

  first_sha=$(sha256sum "$first_archive" | awk '{print $1}')
  second_sha=$(sha256sum "$second_archive" | awk '{print $1}')
  [[ "$first_sha" == "$second_sha" ]] || die "SDK archive checksums differ"
  prefix=$(archive_prefix "$first_archive")
  for required_path in \
    BUILD.bazel go.mod go.sum \
    candacelib/config/environment.go \
    candacelib/redact/redact.go \
    pkg/candaceos/component/BUILD.bazel \
    pkg/candaceos/component/component.go \
    pkg/candaceos/harness/harness.go \
    pkg/candaceos/harness/runner.go \
    services/candaceos-core/bootstrap/BUILD.bazel \
    services/candaceos-core/bootstrap/bootstrap.go \
    services/candaceos-core/bootstrap/core.go \
    services/candaceos-core/bootstrap/reporter.go; do
    tar -tzf "$first_archive" "$prefix/$required_path" >/dev/null || \
      die "SDK archive is missing $required_path"
  done
  bootstrap_build=$(tar -xOzf \
    "$first_archive" "$prefix/services/candaceos-core/bootstrap/BUILD.bazel")
  for bootstrap_source in bootstrap.go components.go core.go reporter.go; do
    [[ "$bootstrap_build" == *\"$bootstrap_source\"* ]] || \
      die "SDK bootstrap Bazel target is missing $bootstrap_source"
  done

  cp -R "$fixture_root/." "$http_archive_consumer/"
  cp -R "$fixture_root/." "$archive_override_consumer/"
  cp "$credential_fixture/BUILD.bazel" "$credential_cache_consumer/BUILD.bazel"
  cp "$credential_fixture/credential_repository.bzl" \
    "$credential_cache_consumer/credential_repository.bzl"
  cp "$credential_fixture/credential-helper" \
    "$credential_cache_consumer/tools/credential-helper"
  cp "$script_dir/github-credential-helper.sh" \
    "$credential_cache_consumer/tools/github-credential-helper"
  cp "$fixture_root/.bazelversion" "$credential_cache_consumer/.bazelversion"
  cp "$fixture_root/.bazelrc" "$credential_cache_consumer/.bazelrc"
  chmod 0755 \
    "$credential_cache_consumer/tools/credential-helper" \
    "$credential_cache_consumer/tools/github-credential-helper"

  (umask 077; printf '%s\n' credential-cache-first >"$token_directory/github-token")
  printf '%s\n' credential-cache-first >"$credential_state/expected-token"
  suffix=${temporary##*.}
  start_archive_server "$artifacts" "$credential_state" "$suffix"
  archive_url="http://$http_container:8080/candaceos-sdk.tar.gz"
  archive_integrity=$(sha256_integrity "$first_sha")
  materialize_http_archive_module \
    "$fixture_root/MODULE.bazel.in" "$http_archive_consumer/MODULE.bazel" \
    "$first_sha" "$prefix" "$archive_url"
  materialize_archive_override_module \
    "$fixture_root/MODULE.archive-override.bazel.in" \
    "$archive_override_consumer/MODULE.bazel" \
    "$archive_integrity" "$prefix" "$archive_url"
  sed \
    "s|@CANDACEOS_CREDENTIAL_URL@|http://$http_container:8080/cgi-bin/credentials|g" \
    "$credential_fixture/MODULE.bazel.in" >"$credential_cache_consumer/MODULE.bazel"
  printf 'common --credential_helper=%s=%%workspace%%/tools/credential-helper\n' \
    "$http_container" >>"$credential_cache_consumer/.bazelrc"

  run_external_consumer \
    "$http_archive_consumer" \
    "$temporary/http-archive-bazel-home" \
    "$temporary/http-archive-bazel-output" \
    "$test_network"
  run_external_consumer \
    "$archive_override_consumer" \
    "$temporary/archive-override-bazel-home" \
    "$temporary/archive-override-bazel-output" \
    "$test_network"

  run_credential_cache_consumer \
    "$credential_cache_consumer" \
    "$temporary/credential-cache-bazel-home" \
    "$temporary/credential-cache-bazel-output" \
    "$test_network" \
    "$token_directory" \
    "$credential_state"

  helper_count=$(awk '$0 == "get" { count++ } END { print count + 0 }' \
    "$credential_state/helper.log")
  first_authorization_count=$(awk \
    '$0 == "Bearer credential-cache-first" { count++ } END { print count + 0 }' \
    "$credential_state/authorization.log")
  rotated_authorization_count=$(awk \
    '$0 == "Bearer credential-cache-rotated" { count++ } END { print count + 0 }' \
    "$credential_state/authorization.log")
  [[ "$helper_count" == 3 ]] || \
    die "Bazel invoked the credential helper $helper_count times, expected 3"
  [[ "$first_authorization_count" == 1 && "$rotated_authorization_count" == 1 ]] || \
    die 'Bazel reused a cached bearer after the token file changed or was deleted'

  printf 'CandaceOS external consumers passed: archive=%s sha256=%s modes=http_archive,archive_override components=steering-store,steering-service credential_cache=disabled\n' \
    "$prefix" "$first_sha"
}

main "$@"
