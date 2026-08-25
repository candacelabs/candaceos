#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
  printf 'bootstrap-updater: run from a Candace server Git checkout\n' >&2
  exit 1
}
deploy_root=${CANDACEOS_DEPLOY_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/candaceos-deployer}

die() {
  printf 'bootstrap-updater: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s [--repository OWNER/NAME]\n' "$(basename "$0")" >&2
}

# The deployment repository is configuration, not source. Reuse the same
# optional topology files fleet.sh reads so a monorepo operator still runs this
# as one command, and let a flag or CANDACEOS_REPOSITORY override them.
for topology_file in \
  "$script_dir/fleet/topology.local.env" \
  "$repo_root/server_admin_scripts/candaceos-fleet-topology.env"; do
  if [[ -f "$topology_file" ]]; then
    # shellcheck source=/dev/null
    . "$topology_file"
  fi
done
unset topology_file

repository=${CANDACEOS_REPOSITORY:-}
while (($#)); do
  case "$1" in
    --repository) (($# >= 2)) || die "$1 needs a value"; repository=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done
[[ -n "$repository" ]] || \
  die "set CANDACEOS_REPOSITORY or pass --repository OWNER/NAME"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  die "invalid repository: expected OWNER/NAME"
export CANDACEOS_REPOSITORY="$repository"

[[ "$deploy_root" == /* ]] || die "CANDACEOS_DEPLOY_ROOT must be absolute"
[[ ! -L "$deploy_root" ]] || die "$deploy_root must not be a symbolic link"
command -v docker >/dev/null || die "docker is required"
command -v git >/dev/null || die "git is required"
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"
[[ -S /var/run/docker.sock ]] || die "/var/run/docker.sock is not a Unix socket"

token=${COPILOT_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}
if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
  token=$(gh auth token 2>/dev/null || true)
fi
[[ -n "$token" ]] || die "authenticate host gh or set COPILOT_GITHUB_TOKEN"

umask 077
mkdir -p "$deploy_root/secrets" "$deploy_root/state" "$deploy_root/control"
token_tmp=$(mktemp "$deploy_root/secrets/.github-token.XXXXXX")
trap 'rm -f "$token_tmp"' EXIT
printf '%s' "$token" >"$token_tmp"
chmod 600 "$token_tmp"
mv -f "$token_tmp" "$deploy_root/secrets/github-token"
trap - EXIT

if [[ ! -d "$deploy_root/repo/.git" ]]; then
  [[ ! -e "$deploy_root/repo" ]] || die "$deploy_root/repo exists but is not a Git repository"
  # A local clone retains the currently running PR revision as a first-deploy
  # rollback source without putting the private-repository token in a URL.
  git clone --local --no-checkout "$repo_root" "$deploy_root/repo"
fi
git -C "$deploy_root/repo" remote set-url origin \
  "https://github.com/$repository.git"

source_state="$script_dir"
target_state="$deploy_root/state"
migrate_state=false
if [[ -f "$source_state/.env" && \
  ! -f "$deploy_root/control/state-adopted" ]]; then
  migrate_state=true
fi
if $migrate_state && [[ ! -f "$target_state/.env" ]]; then
  cp "$source_state/.env" "$target_state/.env.tmp"
  sed -i \
    "s|^CANDACEOS_HOST_WORKSPACE=.*$|CANDACEOS_HOST_WORKSPACE=$target_state/apps|" \
    "$target_state/.env.tmp"
  chmod 600 "$target_state/.env.tmp"
  mv "$target_state/.env.tmp" "$target_state/.env"
fi
if ! $migrate_state && [[ ! -e "$target_state/apps" && -d "$source_state/apps" ]]; then
  cp -a "$source_state/apps" "$target_state/apps"
fi
if $migrate_state; then
  source_compose=(docker compose --project-directory "$script_dir" \
    --env-file "$source_state/.env" -f "$script_dir/compose.yaml" \
    -f "$script_dir/compose.environment.generated.yaml")
  export CANDACEOS_STATE_ROOT="$source_state"
  # Quiesce file-backed sessions and fence state while copying them. The
  # database is already in the stable named Compose volume.
  "${source_compose[@]}" --profile dry-run --profile live --profile copilot \
    --profile opencode stop
  restore_old_stack=true
  restore_source() {
    if $restore_old_stack; then
      COPILOT_GITHUB_TOKEN="$token" CANDACEOS_STATE_ROOT="$source_state" \
        "$script_dir/install.sh" --copilot || true
    fi
  }
  trap restore_source EXIT
  if [[ -d "$source_state/apps" ]]; then
    mkdir -p "$target_state/apps"
    cp -a "$source_state/apps/." "$target_state/apps/"
  fi
  mkdir -p "$target_state/runtime"
  if [[ -d "$source_state/runtime" ]]; then
    cp -a "$source_state/runtime/." "$target_state/runtime/"
  fi
  COPILOT_GITHUB_TOKEN="$token" CANDACEOS_STATE_ROOT="$target_state" \
    "$script_dir/install.sh" --copilot
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >"$deploy_root/control/state-adopted"
  restore_old_stack=false
  trap - EXIT
fi

# The local clone is created before adoption and therefore pins the exact
# source that built the adopted stack. The invoking worktree may advance while
# a failed bootstrap is being repaired and must not rewrite that provenance.
current_revision=$(git -C "$deploy_root/repo" rev-parse HEAD)
[[ "$current_revision" =~ ^[0-9a-f]{40}$ ]] || die "the bootstrap checkout has no full Git revision"
[[ -f "$target_state/.env" ]] || die "the adopted state root has no .env"
curl --fail --silent --show-error --max-time 3 \
  http://127.0.0.1:7780/healthz >/dev/null 2>&1 || \
  die "the adopted CandaceOS stack is not healthy"
"$script_dir/record-bootstrap-revision.sh" \
  "$deploy_root/control" "$current_revision"

export CANDACEOS_DEPLOY_ROOT="$deploy_root"
export CANDACEOS_UPDATER_UID
CANDACEOS_UPDATER_UID=$(id -u)
export CANDACEOS_UPDATER_GID
CANDACEOS_UPDATER_GID=$(id -g)
export CANDACEOS_DOCKER_GID
CANDACEOS_DOCKER_GID=$(stat -c %g /var/run/docker.sock)

docker compose --project-directory "$script_dir" \
  -f "$script_dir/updater.compose.yaml" up -d --build --force-recreate \
  --wait --wait-timeout 60

printf 'CandaceOS merge-to-deploy is armed for %s main.\n' "$repository"
printf 'Deploy root: %s\n' "$deploy_root"
printf 'Status: CANDACEOS_DEPLOY_ROOT=%q ./updater-status.sh\n' "$deploy_root"
