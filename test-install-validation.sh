#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
environment_projection="$script_dir/environment.generated.sh"
# shellcheck source=environment.generated.sh
source "$environment_projection"
test_root=$(mktemp -d)
cleanup() {
  chmod -R u+w "$test_root" >/dev/null 2>&1 || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT

stub_dir="$test_root/bin"
docker_log="$test_root/docker-called"
mkdir -p "$stub_dir"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >>"$CANDACEOS_DOCKER_STUB_LOG"' \
  'if [[ "${CANDACEOS_DOCKER_STUB_MODE:-}" == preflight ]]; then' \
  '  case "$*" in' \
  '    "compose version --short") printf "2.20.0\\n"; exit 0 ;;' \
  '    info) exit 0 ;;' \
  '  esac' \
  'fi' \
  'exit 97' >"$stub_dir/docker"
chmod 0755 "$stub_dir/docker"

for quota in CANDACEOS_AGENT_REVISION_MAX_ENTRIES CANDACEOS_AGENT_REVISION_MAX_BYTES; do
  for invalid in 0 -1 many 9223372036854775808 999999999999999999999999999999999999; do
    state_root="$test_root/install-$quota-$invalid"
    if env \
      PATH="$stub_dir:$PATH" \
      CANDACEOS_DOCKER_STUB_LOG="$docker_log" \
      CANDACEOS_STATE_ROOT="$state_root" \
      CANDACEOS_AGENT_REVISION_MAX_ENTRIES=128 \
      CANDACEOS_AGENT_REVISION_MAX_BYTES=4294967296 \
      "$quota=$invalid" \
      "$script_dir/install.sh" >"$test_root/install.out" 2>"$test_root/install.err"; then
      printf 'installer accepted invalid %s=%s\n' "$quota" "$invalid" >&2
      exit 1
    fi
    grep -Fq "$quota must be a positive int64" "$test_root/install.err"
    [[ ! -e "$state_root" ]] || {
      printf 'installer created state before rejecting invalid %s=%s\n' "$quota" "$invalid" >&2
      exit 1
    }
    [[ ! -e "$docker_log" ]] || {
      printf 'installer reached Docker before rejecting invalid %s=%s\n' "$quota" "$invalid" >&2
      exit 1
    }
  done
done

for valid in 1 9223372036854775807; do
  state_root="$test_root/install-valid-$valid"
  docker_log="$test_root/docker-valid-$valid"
  if env \
    PATH="$stub_dir:$PATH" \
    CANDACEOS_DOCKER_STUB_LOG="$docker_log" \
    CANDACEOS_STATE_ROOT="$state_root" \
    CANDACEOS_AGENT_REVISION_MAX_ENTRIES="$valid" \
    CANDACEOS_AGENT_REVISION_MAX_BYTES="$valid" \
    "$script_dir/install.sh" >"$test_root/install.out" 2>"$test_root/install.err"; then
    printf 'installer unexpectedly passed the failing Docker stub for valid quotas=%s\n' "$valid" >&2
    exit 1
  fi
  grep -Fq 'Docker Compose v2.20 or newer is required' "$test_root/install.err"
  [[ "$(cat "$docker_log")" == 'compose version --short' ]] || {
    printf 'valid quotas=%s did not reach exactly the Docker stub preflight\n' "$valid" >&2
    exit 1
  }
done

state_root="$test_root/install-placeholder-secrets"
docker_log="$test_root/docker-placeholder-secrets"
mkdir -p "$state_root"
cp "$script_dir/.env.example" "$state_root/.env"
chmod 0600 "$state_root/.env"
cp "$state_root/.env" "$state_root/.env.before"
if env \
  PATH="$stub_dir:$PATH" \
  CANDACEOS_DOCKER_STUB_LOG="$docker_log" \
  CANDACEOS_DOCKER_STUB_MODE=preflight \
  CANDACEOS_STATE_ROOT="$state_root" \
  "$script_dir/install.sh" >"$test_root/install.out" 2>"$test_root/install.err"; then
  printf 'installer accepted checked-in placeholder secrets\n' >&2
  exit 1
fi
grep -Fq \
  "$candaceos_env_postgres_password is malformed in $state_root/.env; expected 64 lowercase hexadecimal characters" \
  "$test_root/install.err"
cmp -s "$state_root/.env.before" "$state_root/.env" || {
  printf 'installer changed environment state after rejecting placeholder secrets\n' >&2
  exit 1
}
[[ "$(cat "$docker_log")" == $'compose version --short\ninfo' ]] || {
  printf 'placeholder secret validation did not stop immediately after Docker preflight\n' >&2
  exit 1
}

printf 'CandaceOS installer validation tests passed without Docker.\n'
