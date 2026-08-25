#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
environment_projection="$script_dir/environment.generated.sh"
[[ -r "$environment_projection" ]] || {
  printf 'candaceos install: generated environment projection is missing: %s\n' "$environment_projection" >&2
  exit 1
}
# shellcheck source=environment.generated.sh
source "$environment_projection"

die() {
  printf 'candaceos install: %s\n' "$*" >&2
  exit 1
}

is_positive_int64() {
  local value=$1
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  ((${#value} < 19)) && return 0
  [[ ${#value} -eq 19 && "$value" < 9223372036854775808 ]]
}

for quota in "$candaceos_env_agent_revision_max_entries" "$candaceos_env_agent_revision_max_bytes"; do
  value=${!quota-}
  [[ -z "$value" ]] || is_positive_int64 "$value" || \
    die "$quota must be a positive int64"
done

state_root=${!candaceos_env_state_root-}
state_root=${state_root:-$script_dir}
[[ "$state_root" == /* ]] || die "$candaceos_env_state_root must be absolute"
mkdir -p "$state_root"
state_root=$(CDPATH= cd -- "$state_root" && pwd -P)
env_file="$state_root/.env"
apps_dir="$state_root/apps"
runtime_dir="$state_root/runtime"

copilot=false
opencode=false
live=false

usage() {
  cat <<'EOF'
Usage: ./install.sh [--copilot | --opencode] [--live-executor]

  no flags          safe visual demo + dry-run node executor
  --copilot         host-installed official Copilot CLI + dry-run node executor
  --opencode        pinned private OpenCode sidecar + dry-run node executor
  --live-executor   additionally mount the host Docker socket (requires an agent backend)
EOF
}

metadata_value() {
  local input=$1 key=$2 count
  count=$(grep -c "^${key}=" <<<"$input" || true)
  [[ "$count" == 1 ]] || die "Copilot installer must return exactly one $key"
  sed -n "s/^${key}=//p" <<<"$input"
}

for arg in "$@"; do
  case "$arg" in
    --copilot) copilot=true ;;
    --opencode) opencode=true ;;
    --live-executor) live=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $arg" ;;
  esac
done

if $copilot && $opencode; then
  die "--copilot and --opencode select different agent backends"
fi
if $live && ! $copilot && ! $opencode; then
  die "--live-executor requires --copilot or --opencode (two explicit opt-ins)"
fi

[[ "$(uname -s)" == Linux ]] || die "CandaceOS prototype requires Linux"
command -v docker >/dev/null || die "docker is required"
command -v git >/dev/null || die "git is required"
compose_version=$(docker compose version --short 2>/dev/null) || die "Docker Compose v2.20 or newer is required"
compose_version=${compose_version#v}
IFS=. read -r compose_major compose_minor _ <<<"${compose_version%%-*}"
[[ "$compose_major" =~ ^[0-9]+$ && "$compose_minor" =~ ^[0-9]+$ ]] || \
  die "cannot parse Docker Compose version $compose_version"
((compose_major > 2 || (compose_major == 2 && compose_minor >= 20))) || \
  die "Docker Compose v2.20 or newer is required"
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"

mkdir -p "$apps_dir" "$state_root/revisions" "$runtime_dir/core" "$runtime_dir/copilot" \
  "$runtime_dir/opencode" "$runtime_dir/warden" "$runtime_dir/agent-dry-run" "$runtime_dir/agent-live"

# A managed deployment keeps mutable state outside its exact-revision source
# checkout. Seed the external app workspace once, then leave its Git history
# entirely under the selected agent and the operator's control.
if [[ "$apps_dir" != "$script_dir/apps" && ! -e "$apps_dir/.git" ]]; then
  [[ -f "$script_dir/apps/hello/compose.yaml" && -f "$script_dir/apps/hello/index.html" ]] || \
    die "the initial hello app is missing; refusing to invent workspace content"
  mkdir -p "$apps_dir/hello"
  cp "$script_dir/apps/hello/compose.yaml" "$apps_dir/hello/compose.yaml"
  cp "$script_dir/apps/hello/index.html" "$apps_dir/hello/index.html"
fi

[[ ! -L "$apps_dir/.git" ]] || die "$apps_dir/.git must not be a symbolic link"
if [[ ! -e "$apps_dir/.git" ]]; then
  git -C "$apps_dir" init -q -b main
fi
git -C "$apps_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  die "$apps_dir is not a Git worktree"
git_root=$(git -C "$apps_dir" rev-parse --show-toplevel 2>/dev/null) || \
  die "cannot resolve the Git root for $apps_dir"
[[ "$git_root" == "$apps_dir" ]] || die "$apps_dir belongs to another Git worktree at $git_root"
git -C "$apps_dir" config --local --get user.name >/dev/null 2>&1 || \
  git -C "$apps_dir" config --local user.name 'CandaceOS Bot'
git -C "$apps_dir" config --local --get user.email >/dev/null 2>&1 || \
  git -C "$apps_dir" config --local user.email 'candaceos@localhost'
if ! git -C "$apps_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
  [[ -f "$apps_dir/hello/compose.yaml" && -f "$apps_dir/hello/index.html" ]] || \
    die "the initial hello app is missing; refusing to invent workspace content"
  git -C "$apps_dir" add -- hello/compose.yaml hello/index.html
  git -C "$apps_dir" -c core.hooksPath=/dev/null -c commit.gpgSign=false \
    commit -q -m 'chore: initialize CandaceOS app workspace'
fi

# Candacefile owns names, defaults, profiles, and service projections. This
# atomically materializes only secret, host, and explicit operator state.
candaceos_environment_reconcile "$env_file" "$state_root" "$apps_dir" || \
  die "could not materialize $env_file from Candacefile"
candaceos_environment_apply_defaults
candaceos_environment_apply_profile "$candaceos_profile_local"

if $copilot; then
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "the pinned Copilot CLI prototype currently supports Linux x86_64 only" ;;
  esac
  copilot_metadata=$(bash "$script_dir/install-copilot.sh" "$state_root")
  copilot_bin=$(metadata_value "$copilot_metadata" "$candaceos_env_copilot_bin")
  copilot_sha=$(metadata_value "$copilot_metadata" "$candaceos_env_copilot_sha256")
  [[ "$copilot_bin" == /* ]] || die "Copilot installer returned a non-absolute binary path"
  [[ "$copilot_sha" =~ ^[0-9a-f]{64}$ ]] || die "Copilot installer returned an invalid checksum"
  printf -v "$candaceos_env_copilot_bin" '%s' "$copilot_bin"
  printf -v "$candaceos_env_copilot_sha256" '%s' "$copilot_sha"
  export "$candaceos_env_copilot_bin" "$candaceos_env_copilot_sha256"

  state_token=${!candaceos_env_copilot_github_token-}
  gh_token=${!candaceos_env_gh_token-}
  github_token=${!candaceos_env_github_token-}
  inherited_github_token=${state_token:-${gh_token:-$github_token}}
  if [[ -z "$inherited_github_token" ]] && command -v gh >/dev/null 2>&1; then
    inherited_github_token=$(gh auth token 2>/dev/null || true)
  fi
  if [[ -z "$inherited_github_token" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p 'GitHub token for Copilot, gh, and Git (input hidden): ' inherited_github_token
      printf '\n' >&2
      [[ -n "$inherited_github_token" ]] || die "a GitHub token is required with --copilot"
    else
      die "authenticate host gh or set one of $candaceos_env_copilot_github_token, $candaceos_env_gh_token, or $candaceos_env_github_token"
    fi
  fi
  printf -v "$candaceos_env_copilot_github_token" '%s' "$inherited_github_token"
  export "$candaceos_env_copilot_github_token"
fi

if $opencode; then
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "the pinned OpenCode prototype currently supports Linux x86_64 only" ;;
  esac
fi

if $live; then
  [[ -S /var/run/docker.sock ]] || die "/var/run/docker.sock is not a Unix socket"
  required_phrase=$candaceos_default_live_confirm_phrase
  confirmation=${!candaceos_env_live_confirm-}
  if [[ "$confirmation" != "$required_phrase" ]]; then
    [[ -t 0 ]] || \
      die "set $candaceos_env_live_confirm=$required_phrase for non-interactive live install"
    printf '\nWARNING: live mode gives candaceos-agent host-root-equivalent Docker access.\n' >&2
    printf 'It may start and stop Compose apps below %s.\n' "$apps_dir" >&2
    read -r -p "Type $required_phrase to continue: " confirmation
    [[ "$confirmation" == "$required_phrase" ]] || die "live executor confirmation did not match"
  fi
fi

profiles=(--profile dry-run)
environment_profile=$candaceos_profile_demo
if $live; then
  profiles=(--profile live)
fi
if $copilot; then
  profiles+=(--profile copilot)
  environment_profile=$candaceos_profile_copilot
fi
if $opencode; then
  profiles+=(--profile opencode)
  environment_profile=$candaceos_profile_opencode
fi
candaceos_environment_apply_profile "$environment_profile"

compose=(
  docker compose
  --project-directory "$script_dir"
  --env-file "$env_file"
  -f "$script_dir/compose.yaml"
  -f "$script_dir/compose.environment.generated.yaml"
)

# Switching back to the default installer always demotes a prior live agent.
if $live; then
  "${compose[@]}" --profile dry-run stop agent-dry-run >/dev/null 2>&1 || true
else
  "${compose[@]}" --profile live stop agent-live >/dev/null 2>&1 || true
fi

# A previous provider sidecar is not part of the newly selected backend.
if ! $copilot; then
  "${compose[@]}" --profile copilot stop copilot >/dev/null 2>&1 || true
fi
if ! $opencode; then
  "${compose[@]}" --profile opencode stop opencode >/dev/null 2>&1 || true
fi

if ! "${compose[@]}" "${profiles[@]}" up -d --build --remove-orphans --wait --wait-timeout 120; then
  "${compose[@]}" "${profiles[@]}" ps >&2 || true
  die "services did not become healthy; inspect with ./status.sh and Docker Compose logs"
fi

printf '\nCandaceOS listens on http://0.0.0.0:7780\n'
printf 'Open http://<host-ip>:7780 from a network that can reach this host.\n'
