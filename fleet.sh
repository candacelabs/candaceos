#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
node_script="$script_dir/fleet/node.sh"
copilot_installer="$script_dir/install-copilot.sh"

# Topology is configuration, not source. This repository ships documentation
# placeholders; a deployment supplies its real targets through flags, through
# CANDACEOS_* variables, or through one of these optional files. Each file
# assigns only unset variables, so an explicit variable or flag still wins.
# The second path exists only inside the canonical monorepo checkout.
for topology_file in \
  "$script_dir/fleet/topology.local.env" \
  "$repo_root/server_admin_scripts/candaceos-fleet-topology.env"; do
  if [[ -f "$topology_file" ]]; then
    # shellcheck source=/dev/null
    . "$topology_file"
  fi
done
unset topology_file

control_target=${CANDACEOS_CONTROL_TARGET:-operator@203.0.113.10}
control_ip=${CANDACEOS_CONTROL_IP:-203.0.113.10}
control_id=${CANDACEOS_CONTROL_ID:-control}
control_hostname=${CANDACEOS_CONTROL_HOSTNAME:-}
ai_target=${CANDACEOS_AI_TARGET:-auto}
ai_ip=${CANDACEOS_AI_IP:-203.0.113.11}
ai_id=${CANDACEOS_AI_ID:-worker-gpu}
ai_user=${CANDACEOS_AI_USER:-operator}
ai_hostname=${CANDACEOS_AI_HOSTNAME:-}
prod_target=${CANDACEOS_PROD_TARGET:-operator@203.0.113.12}
prod_ip=${CANDACEOS_PROD_IP:-203.0.113.12}
prod_id=${CANDACEOS_PROD_ID:-worker}
remote_root_arg=${CANDACEOS_FLEET_ROOT:-.local/share/candaceos-fleet}
apps_source_override=${CANDACEOS_APPS_SOURCE:-}
fleet_poll_interval=${CANDACEOS_FLEET_POLL_INTERVAL:-}
harness_backend=${CANDACEOS_FLEET_HARNESS:-copilot-cli}
custom_core_binary=${CANDACEOS_CUSTOM_CORE_BINARY:-}
custom_core_sdk_revision=${CANDACEOS_CUSTOM_CORE_SDK_REVISION:-}
ollama_model=${CANDACEOS_OLLAMA_MODEL:-qwen3:8b}
ollama_context_tokens=${CANDACEOS_OLLAMA_CONTEXT_TOKENS:-16384}
ollama_max_tool_calls=${CANDACEOS_OLLAMA_MAX_TOOL_CALLS:-16}
ollama_turn_timeout=${CANDACEOS_OLLAMA_TURN_TIMEOUT:-10m}
ollama_image='ollama/ollama:0.20.4@sha256:e771d18fe56724f01a6f691a5773df544f36f565fb37c93f0ddc5957007b7766'
ollama_image_digest=${ollama_image##*@}
ollama_model_digest=unverified
ollama_acceptance_run_id=
receipt_root=${CANDACEOS_FLEET_RECEIPT_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/candaceos-fleet/receipts}
ssh_options=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

release_id=
source_revision=
app_head=
work_dir=
receipt_file=
legacy_names=()
cutover_started=false
control_activated=false
ai_activated=false
prod_activated=false
ollama_prepared=false
control_copilot_bin=
control_copilot_sha=
control_previous=
ai_previous=
prod_previous=
control_root=
ai_root=
prod_root=
control_quiesced=false
database_fingerprint=
runtime_marker=absent
deployment_recovery_ran=false
deployment_succeeded=false
fleet_lock_fd=
warden_image_fingerprint=
agent_image_fingerprint=
core_image_fingerprint=
custom_core_sha256=
source_image_fingerprint=
postgres_image_fingerprint=

die() {
  printf 'candaceos fleet: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./fleet.sh COMMAND [OPTIONS]

Commands:
  plan                 Print the exact topology and actions; perform no SSH,
                       Docker, filesystem, or credential reads.
  deploy               Build once locally, rsync image deltas, activate, verify,
                       write a receipt, and print the rollback command.
  status               Verify core, source, quorum, and both live agents.
  rollback [RECEIPT]   Restore the three previous fleet releases recorded by
                       RECEIPT (defaults to the latest successful receipt).

Topology overrides:
  --control-target USER@HOST   --control-ip IP    --control-id NODE_ID
  --ai-target auto|local|USER@HOST   --ai-ip IP   --ai-id NODE_ID
  --prod-target USER@HOST      --prod-ip IP       --prod-id NODE_ID
  --state-root HOME_RELATIVE_PATH
  --harness copilot|ollama|custom    (default: copilot)
  --core-binary ABSOLUTE_PATH        custom harness Core executable
  --core-sdk-revision 40_HEX_SHA     CandaceOS SDK revision used to build it
  --apps-source ABSOLUTE_PATH  (first deployment only; default is discovered
                                from the running legacy Copilot /workspace)

The shipped defaults are documentation placeholders: one singleton
control-plane host plus a GPU worker and an ordinary worker, addressed in the
RFC 5737 documentation range. Supply the real topology with the flags above,
with the matching CANDACEOS_* variables, or in fleet/topology.local.env.
Warden still elects its own quorum leader; "control" does not pin that
election result.
EOF
}

validate_target() {
  [[ "$1" == local || "$1" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.:_-]+$ ]] || die "invalid node target: $1"
}

validate_node_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || die "invalid node id: $1"
}

validate_ip() {
  local ip=$1 part
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "only explicit IPv4 node addresses are supported: $ip"
  IFS=. read -r -a parts <<<"$ip"
  for part in "${parts[@]}"; do
    ((10#$part >= 0 && 10#$part <= 255)) || die "invalid IPv4 address: $ip"
  done
}

validate_relative_root() {
  local value=$1 component
  [[ "$value" =~ ^[A-Za-z0-9._/-]+$ && "$value" != /* && "$value" != */ && "$value" != *//* ]] || \
    die "state root must contain only ordinary nonempty relative path components"
  IFS=/ read -r -a root_components <<<"$value"
  for component in "${root_components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. ]] || \
      die "state root cannot contain empty, dot, or parent components"
  done
}

validate_absolute_path() {
  local value=$1
  [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ && "$value" != *[[:space:]]* ]] || \
    die "path contains unsupported characters: $value"
}

validate_harness() {
  local timeout_value timeout_unit timeout_seconds
  case "$harness_backend" in
    copilot|copilot-cli) harness_backend=copilot-cli ;;
    ollama) ;;
    custom) ;;
    *) die "harness must be copilot, ollama, or custom" ;;
  esac
  if [[ "$harness_backend" == custom ]]; then
    [[ -n "$custom_core_binary" ]] || die "--core-binary is required for the custom harness"
    [[ -n "$custom_core_sdk_revision" ]] || die "--core-sdk-revision is required for the custom harness"
    validate_absolute_path "$custom_core_binary"
    [[ "$custom_core_sdk_revision" =~ ^[0-9a-f]{40}$ ]] || \
      die "custom Core SDK revision must be a full lowercase Git commit ID"
    return 0
  fi
  [[ -z "$custom_core_binary" && -z "$custom_core_sdk_revision" ]] || \
    die "--core-binary and --core-sdk-revision require --harness custom"
  [[ "$harness_backend" == ollama ]] || return 0
  [[ "$ollama_model" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    die "Ollama model must be an explicit name:tag"
  [[ "$ollama_context_tokens" =~ ^[0-9]+$ ]] && \
    ((ollama_context_tokens >= 4096 && ollama_context_tokens <= 32768)) || \
    die "Ollama context tokens must be between 4096 and 32768"
  [[ "$ollama_max_tool_calls" =~ ^[0-9]+$ ]] && \
    ((ollama_max_tool_calls >= 1 && ollama_max_tool_calls <= 64)) || \
    die "Ollama max tool calls must be between 1 and 64"
  [[ "$ollama_turn_timeout" =~ ^([1-9][0-9]*)(s|m)$ ]] || \
    die "Ollama turn timeout must be an explicit positive seconds or minutes duration"
  timeout_value=${BASH_REMATCH[1]}
  timeout_unit=${BASH_REMATCH[2]}
  timeout_seconds=$timeout_value
  [[ "$timeout_unit" != m ]] || timeout_seconds=$((timeout_value * 60))
  ((timeout_seconds >= 1 && timeout_seconds <= 1800)) || \
    die "Ollama turn timeout must be between 1s and 30m"
}

resolve_ai_target() {
  if [[ "$ai_target" != auto ]]; then
    return 0
  fi
  if { [[ -n "$ai_hostname" ]] && [[ "$(hostname)" == "$ai_hostname" ]]; } || \
    [[ " $(hostname -I 2>/dev/null || true) " == *" $ai_ip "* ]]; then
    ai_target=local
  else
    ai_target="$ai_user@$ai_ip"
  fi
}

parse_options() {
  while (($#)); do
    case "$1" in
      --control-target) (($# >= 2)) || die "$1 needs a value"; control_target=$2; shift 2 ;;
      --control-ip) (($# >= 2)) || die "$1 needs a value"; control_ip=$2; shift 2 ;;
      --control-id) (($# >= 2)) || die "$1 needs a value"; control_id=$2; shift 2 ;;
      --ai-target) (($# >= 2)) || die "$1 needs a value"; ai_target=$2; shift 2 ;;
      --ai-ip) (($# >= 2)) || die "$1 needs a value"; ai_ip=$2; shift 2 ;;
      --ai-id) (($# >= 2)) || die "$1 needs a value"; ai_id=$2; shift 2 ;;
      --prod-target) (($# >= 2)) || die "$1 needs a value"; prod_target=$2; shift 2 ;;
      --prod-ip) (($# >= 2)) || die "$1 needs a value"; prod_ip=$2; shift 2 ;;
      --prod-id) (($# >= 2)) || die "$1 needs a value"; prod_id=$2; shift 2 ;;
      --state-root) (($# >= 2)) || die "$1 needs a value"; remote_root_arg=$2; shift 2 ;;
      --harness) (($# >= 2)) || die "$1 needs a value"; harness_backend=$2; shift 2 ;;
      --core-binary) (($# >= 2)) || die "$1 needs a value"; custom_core_binary=$2; shift 2 ;;
      --core-sdk-revision) (($# >= 2)) || die "$1 needs a value"; custom_core_sdk_revision=$2; shift 2 ;;
      --apps-source) (($# >= 2)) || die "$1 needs a value"; apps_source_override=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  resolve_ai_target
  validate_harness
  validate_target "$control_target"
  validate_target "$ai_target"
  validate_target "$prod_target"
  validate_ip "$control_ip"
  validate_ip "$ai_ip"
  validate_ip "$prod_ip"
  validate_node_id "$control_id"
  validate_node_id "$ai_id"
  validate_node_id "$prod_id"
  [[ "$control_id" != "$ai_id" && "$control_id" != "$prod_id" && "$ai_id" != "$prod_id" ]] || \
    die "the three fleet node ids must be distinct"
  [[ "$control_target" != local ]] || die "the control node must be a remote host; images are never built there"
  validate_relative_root "$remote_root_arg"
  if [[ -n "$apps_source_override" ]]; then
    validate_absolute_path "$apps_source_override"
  fi
}

node_run() {
  local target=$1 remote_command quoted argument
  shift
  if [[ "$target" == local ]]; then
    bash "$node_script" "$@"
  else
    remote_command='bash -s --'
    for argument in "$@"; do
      printf -v quoted '%q' "$argument"
      remote_command+=" $quoted"
    done
    ssh "${ssh_options[@]}" "$target" "$remote_command" <"$node_script"
  fi
}

install_control_copilot() {
  local target=$1 root=$2 remote_command quoted
  if [[ "$target" == local ]]; then
    bash "$copilot_installer" "$root"
  else
    printf -v quoted '%q' "$root"
    remote_command="bash -s -- $quoted"
    ssh "${ssh_options[@]}" "$target" "$remote_command" <"$copilot_installer"
  fi
}

node_copy_to() {
  local target=$1 source=$2 destination=$3
  if [[ "$target" == local ]]; then
    install -m 600 "$source" "$destination"
  else
    scp "${ssh_options[@]}" -q "$source" "$target:$destination"
  fi
}

node_copy_from() {
  local target=$1 source=$2 destination=$3
  if [[ "$target" == local ]]; then
    install -m 600 "$source" "$destination"
  else
    scp "${ssh_options[@]}" -q "$target:$source" "$destination"
    chmod 600 "$destination"
  fi
}

node_rsync_to() {
  local target=$1 source=$2 destination=$3 ssh_command
  local -a options=(
    --checksum
    --times
    --no-whole-file
    --partial
    --partial-dir=.rsync-partial
    --chmod=F600
    --protect-args
  )
  if [[ "$target" == local ]]; then
    rsync "${options[@]}" -- "$source" "$destination"
  else
    printf -v ssh_command '%q ' ssh "${ssh_options[@]}"
    ssh_command=${ssh_command% }
    rsync "${options[@]}" --rsh="$ssh_command" -- "$source" "$target:$destination"
  fi
}

metadata_value() {
  local key=$1 input=$2 count
  count=$(grep -c "^${key}=" <<<"$input" || true)
  [[ "$count" == 1 ]] || die "node preflight did not return one $key value"
  sed -n "s/^${key}=//p" <<<"$input"
}

preflight_nodes() {
  local control_meta ai_meta prod_meta
  printf 'Preflighting control and worker nodes...\n'
  control_meta=$(node_run "$control_target" preflight "$remote_root_arg")
  ai_meta=$(node_run "$ai_target" preflight "$remote_root_arg")
  prod_meta=$(node_run "$prod_target" preflight "$remote_root_arg")
  control_root=$(metadata_value root "$control_meta")
  ai_root=$(metadata_value root "$ai_meta")
  prod_root=$(metadata_value root "$prod_meta")
  control_uid=$(metadata_value uid "$control_meta")
  control_gid=$(metadata_value gid "$control_meta")
  ai_uid=$(metadata_value uid "$ai_meta")
  ai_gid=$(metadata_value gid "$ai_meta")
  ai_docker_gid=$(metadata_value docker_gid "$ai_meta")
  prod_uid=$(metadata_value uid "$prod_meta")
  prod_gid=$(metadata_value gid "$prod_meta")
  prod_docker_gid=$(metadata_value docker_gid "$prod_meta")
}

print_plan() {
  local harness_description credential_step runtime_step ai_runtime='Warden + live node agent'
  case "$harness_backend" in
    ollama)
      harness_description="Ollama $ollama_model at http://$ai_ip:11434"
      ai_runtime+=' + pinned GPU Ollama'
      credential_step='preserve the exact app Git repository and database without reading or requiring any GitHub or Copilot credential'
      runtime_step="pull the pinned Ollama 0.20.4 image only on $ai_id and pull/verify $ollama_model before Core activation"
      ;;
    custom)
      harness_description="the custom Core binary built from SDK ${custom_core_sdk_revision:0:12}"
      credential_step='preserve the exact app Git repository and database without reading or requiring any GitHub or Copilot credential'
      runtime_step="snapshot and checksum $custom_core_binary, then package it over the standard Core runtime"
      ;;
    *)
      harness_description='the host Copilot CLI'
      credential_step='inherit the active Copilot token without printing it and preserve the exact app Git repository, database, and durable Core/Copilot runtime'
      runtime_step='reuse a compatible control-host Copilot CLI or install the checksum-pinned 1.0.80 binary below user-owned fleet state'
      ;;
  esac
  cat <<EOF
CandaceOS fleet plan (read-only; no credentials inspected)

  control  $control_id    $control_target ($control_ip)
           postgres + Warden + Git source + Core/WebUI using $harness_description
  worker   $ai_id    $ai_target ($ai_ip), labels role=worker,gpu=true
           $ai_runtime
  worker   $prod_id    $prod_target ($prod_ip), label role=worker
           Warden + live node agent

  state    \$HOME/$remote_root_arg on each node
  source   git://$control_ip:9418/apps.git (read-only upload service)
  UI       http://$control_ip:7780 (tailnet bind $control_ip)

Deploy will:
  1. preflight SSH, Docker/Compose, and per-user roots on all three nodes;
  2. build four custom images once on this invoking host and pull pinned Postgres;
  3. $credential_step;
  4. $runtime_step, then rsync resumable rolling image deltas into bounded
     per-role caches while the current deployment remains live;
  5. stop, but not delete, the old single-host prototype/updater on $ai_id
     at cutover;
  6. activate control first on initial migration; roll workers first and the
     singleton control stack last on later releases;
  7. require one authoritative 3-voter Warden view, quorum, one elected leader,
     exact Git source HEAD, Core health, and two authenticated live agent IDs;
  8. write a mode-600 receipt with an exact one-command rollback.

No host checkout, firewall, Tailscale ACL, systemd unit, Docker daemon setting,
public route, or unrelated Compose project is changed.
EOF
}

make_work_dir() {
  work_dir=$(mktemp -d)
  chmod 700 "$work_dir"
}

cleanup() {
  [[ -z "$work_dir" ]] || rm -rf -- "$work_dir"
}

acquire_fleet_lock() {
  command -v flock >/dev/null || die "flock is required on the invoking operator host"
  mkdir -p "$receipt_root"
  chmod 700 "$receipt_root"
  exec {fleet_lock_fd}>"$receipt_root/operator.lock"
  chmod 600 "$receipt_root/operator.lock"
  flock -n "$fleet_lock_fd" || die "another CandaceOS deploy or rollback is already running on this operator host"
}

snapshot_source() {
  local dirty upstream
  dirty=$(git -C "$repo_root" status --porcelain --untracked-files=all -- go candaceos)
  [[ -z "$dirty" ]] || die "go/ or candaceos/ has uncommitted source; commit and push the exact deploy input first"
  source_revision=$(git -C "$repo_root" rev-parse HEAD)
  [[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve source revision"
  upstream=$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || \
    die "the current branch has no pushed upstream"
  [[ "$(git -C "$repo_root" rev-parse "$upstream")" == "$source_revision" ]] || \
    die "HEAD is not the exact pushed upstream revision"
  if [[ "$harness_backend" == custom ]]; then
    [[ "$custom_core_sdk_revision" == "$source_revision" ]] || \
      die "custom Core SDK revision must equal the exact pushed CandaceOS source revision"
    [[ -f "$custom_core_binary" && -x "$custom_core_binary" ]] || \
      die "custom Core binary must resolve to a regular executable file"
    mkdir -p "$work_dir/custom-core"
    install -m 0555 "$custom_core_binary" "$work_dir/custom-core/candaceos-core"
    custom_core_sha256=$(sha256sum "$work_dir/custom-core/candaceos-core" | awk '{print $1}')
    [[ "$custom_core_sha256" =~ ^[0-9a-f]{64}$ ]] || die "could not checksum the custom Core binary"
  fi
  release_id="$(date -u +%Y%m%dT%H%M%SZ)-${source_revision:0:12}"
  mkdir -p "$work_dir/source"
  git -C "$repo_root" archive "$source_revision" go candaceos | tar -x -C "$work_dir/source"
}

build_images() {
  local build_root="$work_dir/source" version="${source_revision:0:12}"
  warden_image="candaceos-warden:fleet-$version"
  agent_image="candaceos-agent:fleet-$version"
  core_image="candaceos-core:fleet-$version"
  source_image="candaceos-source:fleet-$version"
  postgres_upstream="postgres:18.4-alpine3.24@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15"
  postgres_image="candaceos-postgres:fleet-$version"

  [[ -z "$control_hostname" || "$(hostname)" != "$control_hostname" ]] || \
    die "refusing to build images on the control node"
  command -v docker >/dev/null || die "Docker is required on the invoking build host"
  command -v gzip >/dev/null || die "gzip is required on the invoking build host"
  command -v rsync >/dev/null || die "rsync is required on the invoking build host"
  docker info >/dev/null 2>&1 || die "the local Docker daemon is unavailable"
  printf 'Building the fleet images once on %s...\n' "$(hostname)"
  docker build --build-arg VERSION="$source_revision" -f "$build_root/go/services/warden/Dockerfile" -t "$warden_image" "$build_root/go"
  docker build --build-arg VERSION="$source_revision" -f "$build_root/go/services/candaceos-agent/Dockerfile" -t "$agent_image" "$build_root/go"
  if [[ "$harness_backend" == custom ]]; then
    core_runtime_image="candaceos-core-runtime:fleet-$version"
    docker build --target runtime -f "$build_root/candaceos/Dockerfile.core" -t "$core_runtime_image" "$build_root/go"
    docker build --build-arg BASE_IMAGE="$core_runtime_image" \
      -f "$build_root/candaceos/Dockerfile.core.external" -t "$core_image" "$work_dir/custom-core"
  else
    docker build --build-arg VERSION="$source_revision" -f "$build_root/candaceos/Dockerfile.core" -t "$core_image" "$build_root/go"
  fi
  docker build -f "$build_root/candaceos/Dockerfile.source" -t "$source_image" "$build_root/candaceos"
  docker pull "$postgres_upstream"
  postgres_id=$(docker image inspect "$postgres_upstream" --format '{{.Id}}')
  [[ "$postgres_id" == sha256:* ]] || die "could not resolve the pinned PostgreSQL image"
  docker tag "$postgres_id" "$postgres_image"

  warden_image_fingerprint=$(local_image_runtime_fingerprint "$warden_image")
  agent_image_fingerprint=$(local_image_runtime_fingerprint "$agent_image")
  core_image_fingerprint=$(local_image_runtime_fingerprint "$core_image")
  source_image_fingerprint=$(local_image_runtime_fingerprint "$source_image")
  postgres_image_fingerprint=$(local_image_runtime_fingerprint "$postgres_image")
}

local_image_runtime_fingerprint() {
  local image=$1 fingerprint
  fingerprint=$(node_run local image-fingerprint "$remote_root_arg" "$image") || \
    die "could not fingerprint local image $image"
  [[ "$fingerprint" =~ ^sha256:[0-9a-f]{64}$ ]] || \
    die "local image $image returned a malformed runtime fingerprint"
  printf '%s\n' "$fingerprint"
}

require_hex() {
  local name=$1 value=$2 length=$3
  [[ ${#value} -eq "$length" && "$value" =~ ^[0-9a-f]+$ ]] || die "$name must be exactly $length lowercase hexadecimal characters"
}

env_optional() {
  local file=$1 key=$2
  [[ -f "$file" ]] || return 0
  [[ "$(grep -c "^${key}=" "$file" || true)" -le 1 ]] || die "$key is duplicated in $file"
  sed -n "s/^${key}=//p" "$file"
}

download_current_control_env() {
  local destination=$1 current=$2
  [[ -n "$current" ]] || die "cannot download an empty control release"
  node_copy_from "$control_target" "$control_root/releases/$current/.env" "$destination"
}

discover_legacy() {
  if [[ -n "$apps_source_override" ]]; then
    [[ "$ai_target" == local ]] || die "--apps-source is local-only when the GPU worker is remote"
    legacy_workspace=$apps_source_override
  else
    legacy_workspace=$(node_run "$ai_target" legacy-workspace "$remote_root_arg")
  fi
  [[ "$legacy_workspace" == /* ]] || die "legacy app workspace discovery returned a non-absolute path"
  validate_absolute_path "$legacy_workspace"
  legacy_env="$(dirname "$legacy_workspace")/.env"
}

select_secrets() {
  local existing_env="$work_dir/existing-control.env" legacy_copy="$work_dir/legacy.env"
  local env_token=
  if [[ "$harness_backend" == copilot-cli ]]; then
    env_token=${COPILOT_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}
  fi
  : >"$existing_env"
  chmod 600 "$existing_env"
  if [[ -n "$control_previous" ]]; then
    # current_releases is the authoritative existence check. Once a fleet
    # exists, a transport/copy error must abort instead of being mistaken for
    # a first migration and falling through to legacy credential discovery.
    download_current_control_env "$existing_env" "$control_previous"
    printf 'Reusing the existing fleet credentials.\n'
  else
    discover_legacy
    if [[ "$ai_target" == local && -f "$legacy_env" ]]; then
      install -m 600 "$legacy_env" "$legacy_copy"
    elif [[ "$ai_target" != local ]]; then
      node_copy_from "$ai_target" "$legacy_env" "$legacy_copy" 2>/dev/null || true
    fi
    [[ -f "$legacy_copy" ]] || { : >"$legacy_copy"; chmod 600 "$legacy_copy"; }
    if [[ "$harness_backend" == copilot-cli && -z "$env_token" ]]; then
      env_token=$(env_optional "$legacy_copy" COPILOT_GITHUB_TOKEN)
    fi
    if [[ "$harness_backend" == copilot-cli && -z "$env_token" ]]; then
      env_token=$(node_run "$ai_target" legacy-token "$remote_root_arg")
    fi
  fi

  postgres_password=$(env_optional "$existing_env" POSTGRES_PASSWORD)
  agent_token=$(env_optional "$existing_env" CANDACEOS_AGENT_TOKEN)
  [[ -n "$fleet_poll_interval" ]] || fleet_poll_interval=$(env_optional "$existing_env" CANDACEOS_FLEET_POLL_INTERVAL)
  local legacy_seed=${legacy_copy:-$work_dir/legacy.env}
  [[ -n "$postgres_password" ]] || postgres_password=$(env_optional "$legacy_seed" POSTGRES_PASSWORD)
  [[ -n "$agent_token" ]] || agent_token=$(env_optional "$legacy_seed" CANDACEOS_AGENT_TOKEN)
  [[ -n "$fleet_poll_interval" ]] || fleet_poll_interval=$(env_optional "$legacy_seed" CANDACEOS_FLEET_POLL_INTERVAL)
  [[ -n "$fleet_poll_interval" ]] || fleet_poll_interval=2s
  [[ "$fleet_poll_interval" != *$'\n'* && "$fleet_poll_interval" != *$'\r'* ]] || \
    die "CANDACEOS_FLEET_POLL_INTERVAL must be one line"
  command -v openssl >/dev/null || die "OpenSSL is required to generate fleet credentials"
  [[ -n "$postgres_password" ]] || postgres_password=$(openssl rand -hex 32)
  [[ -n "$agent_token" ]] || agent_token=$(openssl rand -hex 32)
  require_hex POSTGRES_PASSWORD "$postgres_password" 64
  require_hex CANDACEOS_AGENT_TOKEN "$agent_token" 64

  if [[ "$harness_backend" == copilot-cli ]]; then
    copilot_token=$(env_optional "$existing_env" COPILOT_GITHUB_TOKEN)
    [[ -n "$copilot_token" ]] || copilot_token=$env_token
    [[ -n "$copilot_token" && "$copilot_token" != *$'\n'* && "$copilot_token" != *$'\r'* ]] || \
      die "no non-empty Copilot credential is available from env or the running legacy container"
    connection_token=$(env_optional "$existing_env" CANDACEOS_COPILOT_CONNECTION_TOKEN)
    [[ -n "$connection_token" ]] || connection_token=$(env_optional "$legacy_seed" CANDACEOS_COPILOT_CONNECTION_TOKEN)
    [[ -n "$connection_token" ]] || connection_token=$(openssl rand -hex 32)
    require_hex CANDACEOS_COPILOT_CONNECTION_TOKEN "$connection_token" 64
  fi
}

write_common_env() {
  local file=$1 root=$2 uid=$3 gid=$4 node_id=$5 node_ip=$6 docker_gid=${7:-}
  umask 077
  {
    printf 'CANDACEOS_WARDEN_IMAGE=%s\n' "$warden_image"
    printf 'CANDACEOS_AGENT_IMAGE=%s\n' "$agent_image"
    printf 'CANDACEOS_CORE_IMAGE=%s\n' "$core_image"
    printf 'CANDACEOS_SOURCE_IMAGE=%s\n' "$source_image"
    printf 'CANDACEOS_POSTGRES_IMAGE=%s\n' "$postgres_image"
    printf 'CANDACEOS_POSTGRES_UPSTREAM=%s\n' "$postgres_upstream"
    printf 'CANDACEOS_CONTROL_IP=%s\nCANDACEOS_AI_IP=%s\nCANDACEOS_PROD_IP=%s\n' "$control_ip" "$ai_ip" "$prod_ip"
    printf 'CANDACEOS_WARDEN_PEERS=%s=%s:7717,%s=%s:7717,%s=%s:7717\n' \
      "$control_id" "$control_ip" "$ai_id" "$ai_ip" "$prod_id" "$prod_ip"
    printf 'CANDACEOS_NODE_ID=%s\nCANDACEOS_NODE_IP=%s\n' "$node_id" "$node_ip"
    printf 'CANDACEOS_HARNESS_BACKEND=%s\n' "$harness_backend"
    printf 'CANDACEOS_UID=%s\nCANDACEOS_GID=%s\n' "$uid" "$gid"
    [[ -z "$docker_gid" ]] || printf 'CANDACEOS_DOCKER_GID=%s\n' "$docker_gid"
    printf 'CANDACEOS_STATE_ROOT=%s\n' "$root"
    printf 'CANDACEOS_HOST_WORKSPACE=%s/apps\n' "$root"
    printf 'CANDACEOS_AGENT_TOKEN=%s\n' "$agent_token"
    printf 'CANDACEOS_AGENT_REVISION_MAX_ENTRIES=128\n'
    printf 'CANDACEOS_AGENT_REVISION_MAX_BYTES=4294967296\n'
    printf 'CANDACEOS_AGENT_SOURCE_REMOTE=git://%s:9418/apps.git\n' "$control_ip"
    printf 'CANDACEOS_AGENT_SOURCE_FETCH_TIMEOUT=30s\n'
  } >"$file"
  chmod 600 "$file"
}

write_envs() {
  write_common_env "$work_dir/control.env" "$control_root" "$control_uid" "$control_gid" "$control_id" "$control_ip"
  {
    printf 'POSTGRES_PASSWORD=%s\n' "$postgres_password"
    case "$harness_backend" in
      copilot-cli)
        printf 'CANDACEOS_COPILOT_CONNECTION_TOKEN=%s\n' "$connection_token"
        printf 'CANDACEOS_COPILOT_BIN=%s\n' "$control_copilot_bin"
        printf 'CANDACEOS_COPILOT_SHA256=%s\n' "$control_copilot_sha"
        printf 'COPILOT_GITHUB_TOKEN=%s\n' "$copilot_token"
        printf 'CANDACEOS_COPILOT_MODEL=gpt-5.4\n'
        ;;
      ollama)
        printf 'CANDACEOS_OLLAMA_URL=http://%s:11434\n' "$ai_ip"
        printf 'CANDACEOS_OLLAMA_MODEL=%s\n' "$ollama_model"
        printf 'CANDACEOS_OLLAMA_CONTEXT_TOKENS=%s\n' "$ollama_context_tokens"
        printf 'CANDACEOS_OLLAMA_MAX_TOOL_CALLS=%s\n' "$ollama_max_tool_calls"
        printf 'CANDACEOS_OLLAMA_TURN_TIMEOUT=%s\n' "$ollama_turn_timeout"
        printf 'CANDACEOS_OLLAMA_IMAGE_DIGEST=%s\n' "$ollama_image_digest"
        ;;
    esac
    printf 'CANDACEOS_FLEET_POLL_INTERVAL=%s\n' "$fleet_poll_interval"
    printf 'CANDACEOS_WEB_BIND_IP=%s\n' "$control_ip"
    printf 'CANDACEOS_NODE_LABELS={"%s":{"role":"control"},"%s":{"role":"worker","gpu":"true"},"%s":{"role":"worker"}}\n' \
      "$control_id" "$ai_id" "$prod_id"
  } >>"$work_dir/control.env"
  write_common_env "$work_dir/ai.env" "$ai_root" "$ai_uid" "$ai_gid" "$ai_id" "$ai_ip" "$ai_docker_gid"
  if [[ "$harness_backend" == ollama ]]; then
    {
      printf 'CANDACEOS_OLLAMA_URL=http://%s:11434\n' "$ai_ip"
      printf 'CANDACEOS_OLLAMA_MODEL=%s\n' "$ollama_model"
      printf 'CANDACEOS_OLLAMA_CONTEXT_TOKENS=%s\n' "$ollama_context_tokens"
      printf 'CANDACEOS_OLLAMA_IMAGE=%s\n' "$ollama_image"
      printf 'CANDACEOS_OLLAMA_IMAGE_DIGEST=%s\n' "$ollama_image_digest"
    } >>"$work_dir/ai.env"
  fi
  write_common_env "$work_dir/prod.env" "$prod_root" "$prod_uid" "$prod_gid" "$prod_id" "$prod_ip" "$prod_docker_gid"
}

bind_ollama_control_model() {
  local control_env="$work_dir/control.env"
  [[ "$harness_backend" == ollama ]] || die "cannot bind an Ollama model to the $harness_backend harness"
  [[ "$ollama_model_digest" =~ ^[0-9a-f]{64}$ ]] || die "Ollama model digest is not verified"
  if grep -q '^CANDACEOS_OLLAMA_MODEL_DIGEST=' "$control_env"; then
    die "control environment already contains an Ollama model digest"
  fi
  printf 'CANDACEOS_OLLAMA_MODEL_DIGEST=%s\n' "$ollama_model_digest" >>"$control_env"
}

current_releases() {
  control_previous=$(node_run "$control_target" current "$remote_root_arg")
  ai_previous=$(node_run "$ai_target" current "$remote_root_arg")
  prod_previous=$(node_run "$prod_target" current "$remote_root_arg")
}

check_role_ports() {
  node_run "$control_target" check-ports "$remote_root_arg" control "$control_ip"
  node_run "$ai_target" check-ports "$remote_root_arg" worker "$ai_ip"
  [[ "$harness_backend" != ollama ]] || node_run "$ai_target" check-ollama-port "$remote_root_arg" "$ai_ip"
  node_run "$prod_target" check-ports "$remote_root_arg" worker "$prod_ip"
}

prepare_uploads() {
  node_run "$control_target" prepare-upload "$remote_root_arg" "$release_id" >/dev/null
  node_run "$ai_target" prepare-upload "$remote_root_arg" "$release_id" >/dev/null
  node_run "$prod_target" prepare-upload "$remote_root_arg" "$release_id" >/dev/null
}

capture_apps() {
  local bundle_source_target bundle_source_root legacy_output
  if [[ -n "$control_previous" ]]; then
    bundle_source_target=$control_target
    bundle_source_root=$control_root
    source_workspace="$control_root/apps"
    write_receipt cutover
    control_quiesced=true
    node_run "$control_target" quiesce-control-writers "$remote_root_arg"
    database_fingerprint=$(node_run "$control_target" backup-control-db "$remote_root_arg" "$release_id")
  else
    bundle_source_target=$ai_target
    bundle_source_root=$ai_root
    [[ -n "${legacy_workspace:-}" ]] || discover_legacy
    source_workspace=$legacy_workspace
    legacy_output=$(node_run "$ai_target" legacy-running "$remote_root_arg")
    legacy_names=()
    [[ -z "$legacy_output" ]] || mapfile -t legacy_names <<<"$legacy_output"
    ((${#legacy_names[@]} > 0)) || die "no running legacy CandaceOS containers were found for cutover"
    write_receipt cutover
    cutover_started=true
    node_run "$ai_target" quiesce-legacy-writers "$remote_root_arg"
    database_fingerprint=$(node_run "$ai_target" legacy-db-fingerprint "$remote_root_arg")
    node_run "$ai_target" legacy-db-dump "$remote_root_arg" >"$work_dir/database.dump"
    chmod 600 "$work_dir/database.dump"
    [[ -s "$work_dir/database.dump" ]] || die "legacy PostgreSQL dump is empty"
    runtime_marker=$(node_run "$ai_target" bundle-legacy-runtime "$remote_root_arg" "$release_id" "$source_workspace" "$harness_backend")
  fi
  app_head=$(node_run "$bundle_source_target" bundle-apps "$remote_root_arg" "$release_id" "$source_workspace")
  [[ "$app_head" =~ ^[0-9a-f]{40}$ ]] || die "app bundle returned an invalid HEAD"
  node_copy_from "$bundle_source_target" "$bundle_source_root/incoming/$release_id/apps.bundle" "$work_dir/apps.bundle"
  git -C "$repo_root" bundle verify "$work_dir/apps.bundle" >/dev/null 2>&1
  if [[ -z "$control_previous" ]]; then
    if [[ "$runtime_marker" != absent ]]; then
      [[ "$runtime_marker" =~ ^[0-9a-f]{64}$ ]] || die "legacy runtime archive marker is malformed"
      node_copy_from "$ai_target" "$ai_root/incoming/$release_id/runtime.tgz" "$work_dir/runtime.tgz"
      [[ -s "$work_dir/runtime.tgz" ]] || die "legacy runtime archive is empty"
      [[ "$(sha256sum "$work_dir/runtime.tgz" | awk '{print $1}')" == "$runtime_marker" ]] || \
        die "legacy runtime archive checksum mismatch"
    fi
    node_run "$ai_target" quiesce-legacy "$remote_root_arg"
  fi
  [[ "$database_fingerprint" =~ ^tables=candaceos_[a-z0-9_]+=[0-9]+(\;candaceos_[a-z0-9_]+=[0-9]+)*\|receipt_max=[0-9]+$ ]] || \
    die "database fingerprint is malformed"
}

package_role() {
  local role=$1 env_file=$2 compose_source=$3 overlay_source=${4:-} stage
  stage="$work_dir/package-$role"
  mkdir -p "$stage"
  install -m 600 "$env_file" "$stage/.env"
  install -m 644 "$work_dir/source/candaceos/fleet/$compose_source" "$stage/compose.yaml"
  [[ -z "$overlay_source" ]] || \
    install -m 644 "$work_dir/source/candaceos/fleet/$overlay_source" "$stage/backend.compose.yaml"
  install -m 644 "$work_dir/source/candaceos/fleet/warden.yaml" "$stage/warden.yaml"
  if [[ "$role" == control ]]; then
    install -m 600 "$work_dir/apps.bundle" "$stage/apps.bundle"
    [[ ! -f "$work_dir/database.dump" ]] || install -m 600 "$work_dir/database.dump" "$stage/database.dump"
    [[ ! -f "$work_dir/runtime.tgz" ]] || install -m 600 "$work_dir/runtime.tgz" "$stage/runtime.tgz"
  fi
  tar -czf "$work_dir/$role.tgz" -C "$stage" .
  chmod 600 "$work_dir/$role.tgz"
}

transfer_release() {
  local target=$1 root=$2 role=$3 archive incoming checksum install_role=worker
  archive="$work_dir/$role.tgz"
  [[ "$role" == control ]] && install_role=control
  incoming="$root/incoming/$release_id"
  checksum=$(sha256sum "$archive" | awk '{print $1}')
  node_copy_to "$target" "$archive" "$incoming/release.tgz"
  node_run "$target" install "$remote_root_arg" "$release_id" "$install_role" "$checksum"
}

sync_images() {
  local target=$1 role=$2 i archive archive_tmp remote_archive checksum
  local -a images fingerprints verify_args=()
  case "$role" in
    control)
      images=("$warden_image" "$core_image" "$source_image" "$postgres_image")
      fingerprints=(
        "$warden_image_fingerprint"
        "$core_image_fingerprint"
        "$source_image_fingerprint"
        "$postgres_image_fingerprint"
      )
      ;;
    worker)
      images=("$warden_image" "$agent_image")
      fingerprints=("$warden_image_fingerprint" "$agent_image_fingerprint")
      ;;
    *) die "image sync role must be control or worker" ;;
  esac

  for i in "${!images[@]}"; do
    verify_args+=("${images[$i]}" "${fingerprints[$i]}")
  done

  if node_run "$target" verify-images "$remote_root_arg" "${verify_args[@]}" >/dev/null 2>&1; then
    printf 'Reusing exact fleet images already loaded on %s.\n' "$target"
    return
  fi
  if [[ "$target" != local ]]; then
    mkdir -p "$work_dir/image-archives"
    archive="$work_dir/image-archives/$role.tar"
    if [[ ! -f "$archive" ]]; then
      archive_tmp="$archive.tmp"
      docker save --output "$archive_tmp" "${images[@]}"
      chmod 600 "$archive_tmp"
      mv "$archive_tmp" "$archive"
    fi
    checksum=$(sha256sum "$archive" | awk '{print $1}')
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || die "could not checksum the $role image archive"
    remote_archive=$(node_run "$target" prepare-image-upload "$remote_root_arg" "$role")
    [[ "$remote_archive" == /* && "$remote_archive" != *$'\n'* && "$remote_archive" != *$'\r'* ]] || \
      die "$target returned an invalid image cache path"
    printf 'Rsyncing resumable %s image deltas to %s...\n' "$role" "$target"
    node_rsync_to "$target" "$archive" "$remote_archive"
    node_run "$target" load-image-archive "$remote_root_arg" "$role" "$checksum"
  fi
  node_run "$target" verify-images "$remote_root_arg" "${verify_args[@]}"
}

prepare_ollama_image() {
  [[ "$harness_backend" != ollama ]] || \
    node_run "$ai_target" pull-pinned-image "$remote_root_arg" "$ollama_image" "$ollama_image_digest"
}

write_receipt() {
  local status=$1
  mkdir -p "$receipt_root"
  chmod 700 "$receipt_root"
  [[ -n "$receipt_file" ]] || receipt_file="$receipt_root/$release_id.receipt"
  local temporary="$receipt_file.tmp"
  umask 077
  {
    printf 'format=1\nstatus=%s\nrelease_id=%s\nsource_revision=%s\napp_head=%s\ndatabase_fingerprint=%s\npostgres_upstream=%s\n' "$status" "$release_id" "$source_revision" "$app_head" "$database_fingerprint" "${postgres_upstream:-unknown}"
    printf 'control_target=%s\ncontrol_previous=%s\n' "$control_target" "$control_previous"
    printf 'ai_target=%s\nai_previous=%s\n' "$ai_target" "$ai_previous"
    printf 'prod_target=%s\nprod_previous=%s\n' "$prod_target" "$prod_previous"
    printf 'control_ip=%s\nai_ip=%s\nprod_ip=%s\n' "$control_ip" "$ai_ip" "$prod_ip"
    printf 'control_id=%s\nai_id=%s\nprod_id=%s\n' "$control_id" "$ai_id" "$prod_id"
    printf 'state_root=%s\nharness_backend=%s\n' "$remote_root_arg" "$harness_backend"
    if [[ "$harness_backend" == ollama ]]; then
      printf 'ollama_model=%s\nollama_context_tokens=%s\nollama_max_tool_calls=%s\nollama_turn_timeout=%s\nollama_model_digest=%s\nollama_acceptance_run_id=%s\nollama_image=%s\nollama_image_digest=%s\n' \
        "$ollama_model" "$ollama_context_tokens" "$ollama_max_tool_calls" "$ollama_turn_timeout" \
        "$ollama_model_digest" "$ollama_acceptance_run_id" "$ollama_image" "$ollama_image_digest"
    elif [[ "$harness_backend" == copilot-cli ]]; then
      printf 'copilot_binary=%s\ncopilot_sha256=%s\n' "$control_copilot_bin" "$control_copilot_sha"
    else
      printf 'core_sdk_revision=%s\ncore_binary_sha256=%s\n' "$custom_core_sdk_revision" "$custom_core_sha256"
    fi
    printf 'legacy_target=%s\nlegacy_names=%s\n' "$ai_target" "$(IFS=,; printf '%s' "${legacy_names[*]}")"
  } >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$receipt_file"
  sync -f "$receipt_file"
  sync -f "$receipt_root"
}

latest_recovery_receipt() {
  local entry path listing
  [[ -d "$receipt_root" ]] || return 0
  listing=$(find "$receipt_root" -maxdepth 1 -type f -name '*.receipt' -printf '%T@ %p\n' | sort -nr)
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    path=${entry#* }
    if grep -Eq '^status=(staging|cutover|pending|failed)$' "$path"; then
      printf '%s\n' "$path"
    fi
    # Only the newest journal can describe the current cutover. An older
    # failed receipt superseded by a later deployed/recovered release must
    # never roll that later release back.
    return 0
  done <<<"$listing"
}

update_receipt_status() {
  local file=$1 status=$2 temporary count
  count=$(grep -c '^status=' "$file" || true)
  [[ "$count" == 1 ]] || die "recovery receipt must contain exactly one status"
  temporary="$file.status.tmp"
  awk -v status="$status" 'BEGIN { changed=0 }
    /^status=/ && !changed { print "status=" status; changed=1; next }
    { print }
  ' "$file" >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$file"
  sync -f "$file"
  sync -f "$(dirname "$file")"
}

recover_receipt_node() {
  local target=$1 candidate=$2 previous=$3 role=$4 fingerprint=$5 current installed
  if ! installed=$(node_run "$target" release-installed "$remote_root_arg" "$candidate"); then
    printf 'Could not inspect interrupted release %s on %s.\n' "$candidate" "$target" >&2
    return 1
  fi
  case "$installed" in
    true)
      # Automatic mode handles activation that happened before the current
      # symlink commit, including initial current==previous==empty.
      node_run "$target" rollback "$remote_root_arg" "$candidate" "$previous" automatic "$fingerprint"
      return
      ;;
    false) ;;
    *)
      printf 'Interrupted release inspection returned %q on %s.\n' "$installed" "$target" >&2
      return 1
      ;;
  esac
  if ! current=$(node_run "$target" current "$remote_root_arg"); then
    printf 'Could not inspect the current release on %s.\n' "$target" >&2
    return 1
  fi
  [[ "$current" == "$previous" ]] || {
    printf 'Interrupted cutover found unexpected current release %s on %s.\n' "${current:-<none>}" "$target" >&2
    return 1
  }
  if [[ "$role" == control && -n "$previous" ]]; then
    node_run "$target" resume-control "$remote_root_arg"
  fi
}

recover_interrupted_cutover() {
  local journal candidate fingerprint legacy_csv
  local journal_control_target journal_ai_target journal_prod_target
  local journal_control_previous journal_ai_previous journal_prod_previous journal_root
  local failed=0 ai_recovered=true
  local journal_legacy_names=()
  journal=$(latest_recovery_receipt)
  [[ -n "$journal" ]] || return 0
  [[ "$(stat -c '%a' "$journal")" == 600 ]] || die "recovery receipt must have mode 600: $journal"
  candidate=$(receipt_value "$journal" release_id)
  fingerprint=$(receipt_value "$journal" database_fingerprint)
  journal_control_target=$(receipt_value "$journal" control_target)
  journal_ai_target=$(receipt_value "$journal" ai_target)
  journal_prod_target=$(receipt_value "$journal" prod_target)
  journal_control_previous=$(receipt_value "$journal" control_previous)
  journal_ai_previous=$(receipt_value "$journal" ai_previous)
  journal_prod_previous=$(receipt_value "$journal" prod_previous)
  journal_root=$(receipt_value "$journal" state_root)
  legacy_csv=$(receipt_value "$journal" legacy_names)
  [[ -z "$legacy_csv" ]] || IFS=, read -r -a journal_legacy_names <<<"$legacy_csv"
  validate_target "$journal_control_target"
  validate_target "$journal_ai_target"
  validate_target "$journal_prod_target"
  validate_relative_root "$journal_root"

  printf 'Recovering interrupted fleet cutover %s before starting a new release...\n' "$candidate"
  local requested_root=$remote_root_arg
  remote_root_arg=$journal_root
  set +e
  recover_receipt_node "$journal_prod_target" "$candidate" "$journal_prod_previous" worker "$fingerprint" || failed=1
  if ! recover_receipt_node "$journal_ai_target" "$candidate" "$journal_ai_previous" worker "$fingerprint"; then
    ai_recovered=false
    failed=1
  fi
  recover_receipt_node "$journal_control_target" "$candidate" "$journal_control_previous" control "$fingerprint" || failed=1
  if [[ -z "$journal_ai_previous" && ${#journal_legacy_names[@]} -gt 0 ]]; then
    if $ai_recovered; then
      node_run "$journal_ai_target" restore-legacy "$remote_root_arg" "${journal_legacy_names[@]}" || failed=1
      node_run "$journal_ai_target" verify-legacy "$remote_root_arg" "${journal_legacy_names[@]}" || failed=1
    else
      printf 'Skipping legacy restart because interrupted AI recovery did not complete.\n' >&2
    fi
  fi
  set -e
  remote_root_arg=$requested_root
  ((failed == 0)) || die "interrupted cutover recovery is incomplete; correct the failed node and rerun deploy"
  update_receipt_status "$journal" recovered
  printf 'Interrupted cutover recovered; continuing with a fresh release.\n'
}

rollback_candidate() {
  local failed=0 ai_rollback_ok=true
  set +e
  if $prod_activated; then
    node_run "$prod_target" rollback "$remote_root_arg" "$release_id" "$prod_previous" automatic "$database_fingerprint" || failed=1
  fi
  if $ai_activated || $ollama_prepared; then
    if ! node_run "$ai_target" rollback "$remote_root_arg" "$release_id" "$ai_previous" automatic "$database_fingerprint"; then
      ai_rollback_ok=false
      failed=1
    fi
  fi
  if $control_activated; then
    node_run "$control_target" rollback "$remote_root_arg" "$release_id" "$control_previous" automatic "$database_fingerprint" || failed=1
  fi
  if $control_quiesced && ! $control_activated; then
    node_run "$control_target" resume-control "$remote_root_arg" || failed=1
  fi
  if $cutover_started && ((${#legacy_names[@]})); then
    if $ai_activated && ! $ai_rollback_ok; then
      printf 'Skipping legacy restart because the candidate AI worker may still own its ports.\n' >&2
      failed=1
    else
      node_run "$ai_target" restore-legacy "$remote_root_arg" "${legacy_names[@]}" || failed=1
      node_run "$ai_target" verify-legacy "$remote_root_arg" "${legacy_names[@]}" || failed=1
    fi
  fi
  set -e
  return "$failed"
}

deployment_changed() {
  $cutover_started || $control_quiesced || $control_activated || $ai_activated || $prod_activated || $ollama_prepared
}

deployment_exit() {
  local code=$?
  # EXIT can be inherited by command-substitution subshells. Only the root
  # shell owns recovery and cleanup.
  if ((BASH_SUBSHELL > 0)); then
    return "$code"
  fi
  trap - ERR EXIT HUP INT TERM
  if ((code != 0)) && ! $deployment_succeeded && deployment_changed && ! $deployment_recovery_ran; then
    deployment_recovery_ran=true
    printf 'Fleet activation failed; restoring the previous release.\n' >&2
    if ! (rollback_candidate); then
      printf 'Fleet rollback encountered an error; inspect the previous deployment immediately.\n' >&2
    fi
    if [[ -n "$release_id" ]] && ! (write_receipt failed); then
      printf 'Could not write the failed-deployment receipt.\n' >&2
    fi
  fi
  cleanup || true
  exit "$code"
}

install_deployment_traps() {
  trap deployment_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

verify_warden_views() {
  local control_json=$1 ai_json=$2 prod_json=$3
  python3 - "$control_json" "$ai_json" "$prod_json" "$control_ip" "$ai_ip" "$prod_ip" \
    "$control_id" "$ai_id" "$prod_id" <<'PY'
import json, sys

addresses = {
    sys.argv[7]: f"{sys.argv[4]}:7717",
    sys.argv[8]: f"{sys.argv[5]}:7717",
    sys.argv[9]: f"{sys.argv[6]}:7717",
}
expected = set(addresses)
if len(expected) != 3:
    raise SystemExit("the three fleet node ids must be distinct")
views = [json.load(open(path, encoding="utf-8"))["view"] for path in sys.argv[1:4]]
leaders = {view.get("leader_id") for view in views}
if len(leaders) != 1 or not next(iter(leaders)):
    raise SystemExit("Warden nodes do not agree on one elected leader")
leader = next(iter(leaders))
if leader not in expected:
    raise SystemExit(f"Warden leader {leader!r} is not a configured voter")
terms = {view.get("term") for view in views}
if len(terms) != 1 or not next(iter(terms)):
    raise SystemExit("Warden nodes do not agree on one nonzero term")
if {view.get("self") for view in views} != expected:
    raise SystemExit("Warden endpoints do not report the three expected self identities")
for view in views:
    if not view.get("authoritative"):
        raise SystemExit(f'{view.get("self")}: Warden view is not authoritative')
    if view.get("source") != leader:
        raise SystemExit(f'{view.get("self")}: authoritative Warden source is not the elected leader')
    peers = view.get("peers", [])
    if {p.get("node", {}).get("id") for p in peers} != expected:
        raise SystemExit(f'{view.get("self")}: Warden peer set is not the fixed three-node fleet')
    if {p.get("node", {}).get("id"): p.get("node", {}).get("addr") for p in peers} != addresses:
        raise SystemExit(f'{view.get("self")}: Warden peer addresses do not match the declared topology')
    if any(p.get("status") != "alive" for p in peers):
        raise SystemExit(f'{view.get("self")}: Warden does not report all three voters alive')
    voters = view.get("membership", {}).get("voters", [])
    if {v.get("id") for v in voters} != expected:
        raise SystemExit(f'{view.get("self")}: Warden voting membership is not the fixed three-node fleet')
print(leader)
PY
}

verify_fleet() {
  local leader control_status="$work_dir/warden-control.json" ai_status="$work_dir/warden-ai.json" prod_status="$work_dir/warden-prod.json"
  for _ in {1..30}; do
    if node_run "$control_target" verify-control "$remote_root_arg" "$app_head" >/dev/null 2>&1 && \
      node_run "$ai_target" verify-worker "$remote_root_arg" "$ai_id" "$app_head" >/dev/null 2>&1 && \
      node_run "$prod_target" verify-worker "$remote_root_arg" "$prod_id" "$app_head" >/dev/null 2>&1 && \
      node_run "$control_target" warden-status "$remote_root_arg" >"$control_status" 2>/dev/null && \
      node_run "$ai_target" warden-status "$remote_root_arg" >"$ai_status" 2>/dev/null && \
      node_run "$prod_target" warden-status "$remote_root_arg" >"$prod_status" 2>/dev/null; then
      if leader=$(verify_warden_views "$control_status" "$ai_status" "$prod_status" 2>/dev/null); then
        printf 'Verified Core, source HEAD %s, both live agent identities, and Warden leader %s with quorum 2/3.\n' "${app_head:0:12}" "$leader"
        return
      fi
    fi
    sleep 2
  done
  die "fleet did not reach verified Core/source/agent/quorum readiness within 60 seconds"
}

verify_ollama_tool_loop() {
  local base_url="http://$control_ip:7780" origin payload response run_id snapshot state timeout_value timeout_unit timeout_seconds deadline
  payload=$(python3 -c 'import json
print(json.dumps({"prompt": "You MUST call candace_fleet_status exactly once now; do not answer from memory and do not call another tool. Only after that tool completes, give a short nonempty summary of its fleet result."}))')
  response=$(curl --fail --silent --show-error --max-time 10 \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -H "Origin: $base_url" --data-binary "$payload" "$base_url/api/prompts")
  run_id=$(python3 -c 'import json, sys
run_id = json.load(sys.stdin).get("run_id", "")
if not isinstance(run_id, str) or not run_id:
    raise SystemExit("Core did not return an Ollama acceptance run ID")
print(run_id)' <<<"$response")
  ollama_acceptance_run_id=$run_id

  [[ "$ollama_turn_timeout" =~ ^([1-9][0-9]*)(s|m)$ ]] || die "Ollama turn timeout is malformed"
  timeout_value=${BASH_REMATCH[1]}
  timeout_unit=${BASH_REMATCH[2]}
  timeout_seconds=$timeout_value
  [[ "$timeout_unit" != m ]] || timeout_seconds=$((timeout_value * 60))
  deadline=$((SECONDS + timeout_seconds + 30))
  while ((SECONDS < deadline)); do
    snapshot=$(curl --fail --silent --show-error --max-time 10 -H 'Accept: application/json' "$base_url/api/snapshot")
    state=$(python3 -c 'import json, sys
expected = sys.argv[1]
snapshot = json.load(sys.stdin)
run = snapshot.get("run") or {}
if run.get("id") != expected:
    print("waiting")
    raise SystemExit
status = run.get("status", "")
if status == "succeeded":
    entries = run.get("entries") or []
    tools = [entry for entry in entries if entry.get("kind") == "tool" and entry.get("name") == "candace_fleet_status" and entry.get("status") == "complete"]
    answers = [entry for entry in entries if entry.get("kind") == "message" and entry.get("role") == "assistant" and str(entry.get("text", "")).strip()]
    if not tools:
        raise SystemExit("Ollama acceptance run did not complete candace_fleet_status")
    if not answers:
        raise SystemExit("Ollama acceptance run returned no assistant text")
    print("succeeded")
elif status in {"failed", "aborted", "canceled"}:
    raise SystemExit(f"Ollama acceptance run ended {status}")
else:
    print("waiting")' "$run_id" <<<"$snapshot") || die "Ollama tool-loop acceptance failed"
    [[ "$state" != succeeded ]] || {
      printf 'Verified Ollama run %s completed candace_fleet_status and returned assistant text.\n' "$run_id"
      return 0
    }
    sleep 2
  done
  die "Ollama tool-loop acceptance did not finish before its bounded turn deadline"
}

deploy() {
  local copilot_metadata control_overlay= ai_overlay=
  acquire_fleet_lock
  recover_interrupted_cutover
  make_work_dir
  deployment_recovery_ran=false
  deployment_succeeded=false
  install_deployment_traps
  snapshot_source
  preflight_nodes
  current_releases
  check_role_ports
  case "$harness_backend" in
    copilot-cli)
      control_overlay=control.copilot.compose.yaml
      copilot_metadata=$(install_control_copilot "$control_target" "$control_root")
      control_copilot_bin=$(metadata_value CANDACEOS_COPILOT_BIN "$copilot_metadata")
      control_copilot_sha=$(metadata_value CANDACEOS_COPILOT_SHA256 "$copilot_metadata")
      [[ "$control_copilot_bin" == /* ]] || die "control Copilot installer returned a non-absolute path"
      [[ "$control_copilot_sha" =~ ^[0-9a-f]{64}$ ]] || die "control Copilot installer returned an invalid checksum"
      ;;
    ollama)
      control_overlay=control.ollama.compose.yaml
      ai_overlay=worker.ollama.compose.yaml
      node_run "$ai_target" preflight-ollama "$remote_root_arg"
      ;;
  esac
  select_secrets
  build_images
  prepare_ollama_image
  # Move immutable image bytes before quiescing any live writer. Transfer
  # failures leave the legacy/current fleet untouched and keep the actual
  # maintenance window limited to snapshots and activation.
  sync_images "$control_target" control
  sync_images "$ai_target" worker
  sync_images "$prod_target" worker
  prepare_uploads
  write_envs

  if [[ "$harness_backend" == ollama ]]; then
    # Stage the GPU runtime while the current control plane is still live. A
    # model download or capability/GPU failure must not extend fleet downtime.
    package_role ai "$work_dir/ai.env" worker.compose.yaml "$ai_overlay"
    write_receipt staging
    transfer_release "$ai_target" "$ai_root" ai
    ollama_prepared=true
    ollama_metadata=$(node_run "$ai_target" activate-ollama "$remote_root_arg" "$release_id")
    ollama_model_digest=$(metadata_value model_digest "$ollama_metadata")
    [[ "$ollama_model_digest" =~ ^[0-9a-f]{64}$ ]] || die "Ollama returned an invalid model digest"
    bind_ollama_control_model
  fi

  capture_apps
  # capture_apps writes the pre-quiesce journal. Refresh it with the completed
  # source and database evidence before installing the remaining roles.
  write_receipt cutover
  package_role control "$work_dir/control.env" control.compose.yaml "$control_overlay"
  if [[ "$harness_backend" != ollama ]]; then
    package_role ai "$work_dir/ai.env" worker.compose.yaml "$ai_overlay"
  fi
  package_role prod "$work_dir/prod.env" worker.compose.yaml

  transfer_release "$control_target" "$control_root" control
  if [[ "$harness_backend" != ollama ]]; then
    transfer_release "$ai_target" "$ai_root" ai
  fi
  transfer_release "$prod_target" "$prod_root" prod

  if [[ -z "$control_previous" ]]; then
    control_activated=true
    node_run "$control_target" activate-control-db "$remote_root_arg" "$release_id"
    node_run "$control_target" restore-initial-db "$remote_root_arg" "$release_id"
    node_run "$control_target" verify-control-db "$remote_root_arg" "$release_id" "$database_fingerprint"
    node_run "$control_target" activate "$remote_root_arg" "$release_id"
    node_run "$control_target" commit "$remote_root_arg" "$release_id"
    ai_activated=true
    node_run "$ai_target" activate "$remote_root_arg" "$release_id"
    node_run "$ai_target" commit "$remote_root_arg" "$release_id"
    prod_activated=true
    node_run "$prod_target" activate "$remote_root_arg" "$release_id"
    node_run "$prod_target" commit "$remote_root_arg" "$release_id"
  else
    # Preserve the current control/source service and Warden quorum while each
    # worker advances, then cut the singleton control stack over last.
    ai_activated=true
    node_run "$ai_target" activate "$remote_root_arg" "$release_id"
    node_run "$ai_target" commit "$remote_root_arg" "$release_id"
    prod_activated=true
    node_run "$prod_target" activate "$remote_root_arg" "$release_id"
    node_run "$prod_target" commit "$remote_root_arg" "$release_id"
    control_activated=true
    node_run "$control_target" activate "$remote_root_arg" "$release_id"
    node_run "$control_target" commit "$remote_root_arg" "$release_id"
  fi
  verify_fleet
  if [[ "$harness_backend" == ollama ]]; then
    [[ "$(node_run "$ai_target" ollama-model-digest "$remote_root_arg")" == "$ollama_model_digest" ]] || \
      die "verified AI release model digest does not match activation evidence"
    verify_ollama_tool_loop
  fi
  write_receipt deployed
  deployment_succeeded=true

  printf '\nCandaceOS fleet is live: http://%s:7780\n' "$control_ip"
  printf 'Receipt: %s\n' "$receipt_file"
  printf 'Rollback: %q rollback %q\n' "$script_dir/fleet.sh" "$receipt_file"
}

receipt_value() {
  local file=$1 key=$2 count
  count=$(grep -c "^${key}=" "$file" || true)
  [[ "$count" == 1 ]] || die "$key must occur exactly once in receipt"
  sed -n "s/^${key}=//p" "$file"
}

receipt_optional() {
  local file=$1 key=$2 fallback=$3 count value
  count=$(grep -c "^${key}=" "$file" || true)
  [[ "$count" -le 1 ]] || die "$key must occur at most once in receipt"
  value=$(sed -n "s/^${key}=//p" "$file")
  [[ -n "$value" ]] || value=$fallback
  printf '%s\n' "$value"
}

latest_receipt() {
  local entry path
  while IFS= read -r entry; do
    path=${entry#* }
    if grep -qx 'status=deployed' "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(find "$receipt_root" -maxdepth 1 -type f -name '*.receipt' -printf '%T@ %p\n' 2>/dev/null | sort -nr)
  return 0
}

rollback_from_receipt() {
  local selected=${1:-} legacy_csv expected_fingerprint failed=0 ai_rollback_ok=true
  acquire_fleet_lock
  [[ -n "$selected" ]] || selected=$(latest_receipt)
  [[ -f "$selected" ]] || die "receipt not found: ${selected:-<latest>}"
  [[ "$(stat -c '%a' "$selected")" == 600 ]] || die "receipt must have mode 600"
  release_id=$(receipt_value "$selected" release_id)
  control_target=$(receipt_value "$selected" control_target)
  ai_target=$(receipt_value "$selected" ai_target)
  prod_target=$(receipt_value "$selected" prod_target)
  control_ip=$(receipt_value "$selected" control_ip)
  ai_ip=$(receipt_value "$selected" ai_ip)
  prod_ip=$(receipt_value "$selected" prod_ip)
  remote_root_arg=$(receipt_value "$selected" state_root)
  validate_relative_root "$remote_root_arg"
  control_previous=$(receipt_value "$selected" control_previous)
  ai_previous=$(receipt_value "$selected" ai_previous)
  prod_previous=$(receipt_value "$selected" prod_previous)
  expected_fingerprint=$(receipt_value "$selected" database_fingerprint)
  legacy_csv=$(receipt_value "$selected" legacy_names)
  # Older receipts predate the recorded node ids; fall back to the configured
  # topology so a rollback still verifies against the same identities.
  control_id=$(receipt_optional "$selected" control_id "$control_id")
  ai_id=$(receipt_optional "$selected" ai_id "$ai_id")
  prod_id=$(receipt_optional "$selected" prod_id "$prod_id")
  validate_target "$control_target"; validate_target "$ai_target"; validate_target "$prod_target"
  validate_ip "$control_ip"; validate_ip "$ai_ip"; validate_ip "$prod_ip"
  validate_node_id "$control_id"; validate_node_id "$ai_id"; validate_node_id "$prod_id"
  [[ -z "$legacy_csv" ]] || IFS=, read -r -a legacy_names <<<"$legacy_csv"
  printf 'Rolling back fleet release %s...\n' "$release_id"
  set +e
  node_run "$prod_target" rollback "$remote_root_arg" "$release_id" "$prod_previous" manual "$expected_fingerprint" || failed=1
  if ! node_run "$ai_target" rollback "$remote_root_arg" "$release_id" "$ai_previous" manual "$expected_fingerprint"; then
    ai_rollback_ok=false
    failed=1
  fi
  node_run "$control_target" rollback "$remote_root_arg" "$release_id" "$control_previous" manual "$expected_fingerprint" || failed=1
  if [[ -z "$ai_previous" ]] && ((${#legacy_names[@]})); then
    if $ai_rollback_ok; then
      node_run "$ai_target" restore-legacy "$remote_root_arg" "${legacy_names[@]}" || failed=1
      node_run "$ai_target" verify-legacy "$remote_root_arg" "${legacy_names[@]}" || failed=1
    else
      printf 'Skipping legacy restart because the candidate AI worker may still own its ports.\n' >&2
    fi
  fi
  set -e
  if ((failed != 0)); then
    printf 'Rollback incomplete; safe recovery was attempted on every node. Re-run this receipt after correcting the failed node.\n' >&2
    return 1
  fi
  if [[ -n "$control_previous" && -n "$ai_previous" && -n "$prod_previous" ]]; then
    make_work_dir
    trap cleanup EXIT
    preflight_nodes
    app_head=$(node_run "$control_target" app-head "$remote_root_arg")
    verify_fleet
  fi
  printf 'Rollback complete. Preserved candidate state and Docker volumes for inspection.\n'
}

status() {
  make_work_dir
  trap cleanup EXIT
  preflight_nodes
  app_head=$(node_run "$control_target" app-head "$remote_root_arg")
  verify_fleet
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  command=${1:-}
  [[ -n "$command" ]] || { usage >&2; exit 2; }
  shift || true
  case "$command" in
    plan) parse_options "$@"; print_plan ;;
    deploy) parse_options "$@"; deploy ;;
    status) parse_options "$@"; status ;;
    rollback)
      receipt=${1:-}
      (($# <= 1)) || die "rollback accepts only one receipt path"
      rollback_from_receipt "$receipt"
      ;;
    _test-node-argv)
      [[ "${CANDACEOS_FLEET_TESTING:-}" == 1 ]] || die "internal test command is disabled"
      test_target=${CANDACEOS_FLEET_TEST_TARGET:-test@host}
      node_run "$test_target" echo-args-for-test .local/share/candaceos-fleet-test "$@"
      ;;
    -h|--help|help) usage ;;
    *) usage >&2; die "unknown command: $command" ;;
  esac
fi
