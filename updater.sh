#!/usr/bin/env bash
set -Eeuo pipefail

deploy_root=${CANDACEOS_DEPLOY_ROOT:?CANDACEOS_DEPLOY_ROOT is required}
token_file=${CANDACEOS_GITHUB_TOKEN_FILE:?CANDACEOS_GITHUB_TOKEN_FILE is required}
repository=${CANDACEOS_REPOSITORY:?CANDACEOS_REPOSITORY is required as owner/name}
poll_interval=${CANDACEOS_POLL_INTERVAL:-30}

[[ "$deploy_root" == /* ]] || { printf 'CANDACEOS_DEPLOY_ROOT must be absolute\n' >&2; exit 2; }
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { printf 'invalid CANDACEOS_REPOSITORY\n' >&2; exit 2; }
[[ "$poll_interval" =~ ^[0-9]+$ && "$poll_interval" -ge 5 ]] || { printf 'CANDACEOS_POLL_INTERVAL must be an integer of at least 5\n' >&2; exit 2; }

repo_dir="$deploy_root/repo"
state_root="$deploy_root/state"
control_dir="$deploy_root/control"
receipt_file="$control_dir/deployments.jsonl"
heartbeat_file="$control_dir/heartbeat"
retry_state_file="$control_dir/retry-state"
success_pending_file="$control_dir/success-pending"
status_outbox_dir="$control_dir/status-outbox"
remote_url="https://github.com/$repository.git"
retry_initial_seconds=60
retry_max_seconds=3600
retry_count_cap=63

log() {
  printf '%s candaceos-updater: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

valid_revision() {
  [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]
}

read_state() {
  local path=$1
  [[ -f "$path" ]] && tr -d '\r\n' <"$path" || true
}

write_state() {
  local path=$1 value=$2 tmp
  tmp=$(mktemp "$control_dir/.state.XXXXXX")
  printf '%s\n' "$value" >"$tmp"
  mv -f "$tmp" "$path"
}

now_epoch() {
  date +%s
}

clear_retry_state() {
  rm -f -- "$retry_state_file"
}

read_retry_state() {
  local candidate count next_at extra
  [[ -f "$retry_state_file" ]] || return 1
  IFS=' ' read -r candidate count next_at extra <"$retry_state_file" || return 1
  valid_revision "$candidate" || return 1
  [[ "$count" =~ ^([1-9]|[1-5][0-9]|6[0-3])$ ]] || return 1
  [[ "$next_at" =~ ^[1-9][0-9]{0,17}$ ]] || return 1
  [[ -z "$extra" ]] || return 1
  printf '%s %s %s\n' "$candidate" "$count" "$next_at"
}

# Returns 0 while this candidate must wait, 1 when it may run, and 2 when
# durable retry state could not be reconciled.
retry_is_deferred() {
  local candidate=$1 state stored_candidate stored_count stored_next_at now
  if ! state=$(read_retry_state); then
    if [[ -e "$retry_state_file" ]] && ! clear_retry_state; then
      log "could not clear invalid retry state"
      return 2
    fi
    return 1
  fi
  read -r stored_candidate stored_count stored_next_at <<<"$state"
  if [[ "$stored_candidate" != "$candidate" ]]; then
    clear_retry_state || {
      log "could not clear superseded retry state"
      return 2
    }
    return 1
  fi
  now=$(now_epoch)
  [[ "$now" =~ ^[1-9][0-9]{0,17}$ ]] || {
    log "current epoch is invalid; refusing retry scheduling"
    return 2
  }
  ((now < stored_next_at))
}

schedule_retry() {
  local candidate=$1 state stored_candidate stored_count stored_next_at
  local count=1 delay=$retry_initial_seconds step now next_at
  if state=$(read_retry_state); then
    read -r stored_candidate stored_count stored_next_at <<<"$state"
    if [[ "$stored_candidate" == "$candidate" ]]; then
      count=$((stored_count + 1))
      ((count <= retry_count_cap)) || count=$retry_count_cap
    fi
  fi
  for ((step = 1; step < count && delay < retry_max_seconds; step++)); do
    delay=$((delay * 2))
    ((delay <= retry_max_seconds)) || delay=$retry_max_seconds
  done
  now=$(now_epoch)
  [[ "$now" =~ ^[1-9][0-9]{0,17}$ ]] || {
    log "current epoch is invalid; refusing retry scheduling"
    return 1
  }
  next_at=$((now + delay))
  write_state "$retry_state_file" "$candidate $count $next_at" || return 1
  log "scheduled retry for main@$candidate in ${delay}s after failure $count"
}

read_success_pending() {
  local candidate previous extra
  [[ -f "$success_pending_file" ]] || return 1
  IFS=' ' read -r candidate previous extra <"$success_pending_file" || return 1
  valid_revision "$candidate" || return 1
  [[ "$previous" == none ]] || valid_revision "$previous" || return 1
  [[ -z "$extra" ]] || return 1
  printf '%s %s\n' "$candidate" "$previous"
}

record_receipt_once() {
  local candidate=$1 previous=$2 outcome=$3 rollback=$4 pattern
  pattern=$(printf '"candidate":"%s","previous":"%s","outcome":"%s"' \
    "$candidate" "$previous" "$outcome")
  if [[ -f "$receipt_file" ]] && grep -Fq -- "$pattern" "$receipt_file"; then
    return 0
  fi
  record_receipt "$candidate" "$previous" "$outcome" "$rollback"
}

finalize_success() {
  local state candidate stored_previous previous
  state=$(read_success_pending) || {
    log "success finalization state is invalid; operator repair is required"
    return 1
  }
  read -r candidate stored_previous <<<"$state"
  previous=$stored_previous
  [[ "$previous" != none ]] || previous=

  record_receipt_once "$candidate" "$previous" success not-needed || {
    log "warning: could not persist success receipt for main@$candidate"
    return 1
  }
  write_state "$control_dir/current-origin" main || return 1
  write_state "$control_dir/current" "$candidate" || return 1
  clear_retry_state || return 1
  queue_final_status "$candidate" success "CandaceOS bootstrap deployment is healthy" || return 1
  write_state "$control_dir/last-observed" "$candidate" || return 1
  rm -f -- "$success_pending_file" || return 1
  flush_status_outbox
  log "deployed and verified $candidate"
}

record_receipt() {
  local candidate=$1 previous=$2 outcome=$3 rollback=$4
  printf '{"at":"%s","candidate":"%s","previous":"%s","outcome":"%s","rollback":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$candidate" "$previous" "$outcome" "$rollback" >>"$receipt_file"
}

post_status() {
  local revision=$1 state=$2 description=$3 payload
  payload=$(printf '{"state":"%s","context":"candaceos/bootstrap-deploy","description":"%s"}' "$state" "$description")
  # The credential travels through curl's stdin config, not its argument
  # vector, so it never appears in the host process table.
  if ! printf 'header = "Authorization: Bearer %s"\n' "$(cat "$token_file")" | \
    curl --config - --fail --silent --show-error --max-time 10 \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$repository/statuses/$revision" \
    --data "$payload" >/dev/null; then
    log "warning: could not publish GitHub deployment status"
    return 1
  fi
}

queue_final_status() {
  local revision=$1 state=$2 description=$3 value
  valid_revision "$revision" || return 1
  [[ "$state" == success || "$state" == failure ]] || return 1
  [[ -n "$description" && "$description" != *$'\n'* ]] || return 1
  mkdir -p "$status_outbox_dir" || return 1
  printf -v value '%s\n%s' "$state" "$description"
  write_state "$status_outbox_dir/$revision" "$value"
}

flush_status_outbox() {
  local path revision state description
  local -a lines
  [[ -d "$status_outbox_dir" ]] || return 0
  for path in "$status_outbox_dir"/*; do
    [[ -f "$path" ]] || continue
    revision=$(basename -- "$path")
    lines=()
    mapfile -t lines <"$path" || {
      log "warning: could not read status outbox entry $path"
      continue
    }
    if ! valid_revision "$revision" || [[ "${#lines[@]}" -ne 2 ]]; then
      log "warning: invalid status outbox entry $path"
      continue
    fi
    state=${lines[0]}
    description=${lines[1]}
    if [[ "$state" != success && "$state" != failure ]] || [[ -z "$description" ]]; then
      log "warning: invalid status outbox entry $path"
      continue
    fi
    if post_status "$revision" "$state" "$description"; then
      rm -f -- "$path" || log "warning: could not clear status outbox entry $path"
    fi
  done
  return 0
}

ensure_repo() {
  if [[ ! -d "$repo_dir/.git" ]]; then
    [[ ! -e "$repo_dir" ]] || { log "$repo_dir exists but is not a Git repository"; return 1; }
    git clone --filter=blob:none --no-checkout "$remote_url" "$repo_dir"
  fi
  git -C "$repo_dir" remote set-url origin "$remote_url"
}

fetch_main() {
  git -C "$repo_dir" fetch --no-tags origin \
    +refs/heads/main:refs/remotes/origin/main >/dev/null || return 1
  git -C "$repo_dir" rev-parse --verify refs/remotes/origin/main
}

checkout_revision() {
  local revision=$1
  if ! git -C "$repo_dir" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$repo_dir" fetch --no-tags origin "$revision" >/dev/null || return 1
  fi
  git -C "$repo_dir" checkout --detach --force "$revision" >/dev/null || return 1
  git -C "$repo_dir" clean -ffdx >/dev/null || return 1
  [[ "$(git -C "$repo_dir" rev-parse HEAD)" == "$revision" ]] &&
    [[ -z "$(git -C "$repo_dir" status --porcelain --untracked-files=all)" ]]
}

has_deploy_contract() {
  git -C "$repo_dir" cat-file -e "$1:candaceos/install.sh" 2>/dev/null &&
    git -C "$repo_dir" cat-file -e "$1:candaceos/compose.yaml" 2>/dev/null &&
    git -C "$repo_dir" cat-file -e "$1:candaceos/compose.environment.generated.yaml" 2>/dev/null &&
    git -C "$repo_dir" cat-file -e "$1:candaceos/environment.generated.sh" 2>/dev/null
}

affects_candaceos() {
  local previous=$1 candidate=$2 origin=$3
  [[ "$origin" != main ]] && return 0
  valid_revision "$previous" || return 0
  ! git -C "$repo_dir" diff --quiet "$previous" "$candidate" -- \
    candaceos \
    go/go.mod go/go.sum \
    go/candacelib \
    go/pkg/candaceos go/pkg/core go/pkg/telemetry \
    go/proto/candace/candaceos \
    go/proto/candace/telemetry \
    go/services/candaceos-agent \
    go/services/candaceos-core \
    go/services/warden
}

verify_deployment() {
  local source_dir=$1 service running agent_id agent_health
  curl --fail --silent --show-error --max-time 5 \
    http://127.0.0.1:7780/healthz >/dev/null || return 1
  running=$(CANDACEOS_STATE_ROOT="$state_root" \
    docker compose --project-directory "$source_dir/candaceos" \
      --env-file "$state_root/.env" -f "$source_dir/candaceos/compose.yaml" \
      -f "$source_dir/candaceos/compose.environment.generated.yaml" \
      --profile dry-run --profile copilot ps --services --filter status=running) || return 1
  for service in postgres warden agent-dry-run copilot core; do
    grep -qx "$service" <<<"$running" || {
      log "required service is not running: $service"
      return 1
    }
  done
  agent_id=$(CANDACEOS_STATE_ROOT="$state_root" \
    docker compose --project-directory "$source_dir/candaceos" \
      --env-file "$state_root/.env" -f "$source_dir/candaceos/compose.yaml" \
      -f "$source_dir/candaceos/compose.environment.generated.yaml" \
      --profile dry-run --profile copilot ps -q agent-dry-run) || return 1
  [[ -n "$agent_id" ]] || return 1
  agent_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}absent{{end}}' "$agent_id") || return 1
  if [[ "$agent_health" != absent ]]; then
    [[ "$agent_health" == healthy ]] || {
      log "required service is not healthy: agent-dry-run ($agent_health)"
      return 1
    }
    return 0
  fi

  # Revisions predating the Compose healthcheck still expose the authenticated
  # agent endpoint. Expand the token only inside that container so it never
  # crosses the Docker API or updater logs. Legacy Compose can report running
  # before the listener is ready, so bound the compatibility probe to 30s.
  local attempt
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if docker exec "$agent_id" sh -ec '
      test -n "${CANDACEOS_AGENT_TOKEN:-}"
      exec wget --quiet --spider \
        --header="Authorization: Bearer $CANDACEOS_AGENT_TOKEN" \
        http://127.0.0.1:8094/healthz
    ' >/dev/null 2>&1; then
      return 0
    fi
    ((attempt == 30)) || sleep 1
  done
  log "required service is not healthy: agent-dry-run ($agent_health)"
  return 1
}

deploy_revision() {
  local revision=$1
  checkout_revision "$revision" || return 1
  log "deploying exact revision $revision with real Copilot and dry-run execution"
  if ! COPILOT_GITHUB_TOKEN="$(cat "$token_file")" \
    GH_TOKEN= GITHUB_TOKEN= \
    CANDACEOS_STATE_ROOT="$state_root" \
    CANDACEOS_QUIET_SECRETS=1 \
    "$repo_dir/candaceos/install.sh" --copilot; then
    return 1
  fi
  verify_deployment "$repo_dir"
}

handle_deployment_failure() {
  local candidate=$1 previous=$2 rollback=not-attempted description
  log "deployment of $candidate failed"
  if valid_revision "$previous" && checkout_revision "$previous"; then
    if deploy_revision "$previous"; then
      rollback=success
      log "rolled back and verified exact revision $previous"
    else
      rollback=failed
      log "automatic rollback to $previous also failed"
    fi
  else
    rollback=unavailable
    log "no valid previous revision is available for automatic rollback"
  fi
  schedule_retry "$candidate" ||
    log "warning: could not persist retry state for main@$candidate; the next poll will try again"
  record_receipt "$candidate" "$previous" failure "$rollback" ||
    log "warning: could not persist failure receipt for main@$candidate"
  description="CandaceOS deploy failed; rollback: $rollback"
  queue_final_status "$candidate" failure "$description" ||
    log "warning: could not queue failure status for main@$candidate"
  flush_status_outbox
  log "recovery: inspect $receipt_file and run ./updater-status.sh"
  return 1
}

reconcile_once() {
  local candidate previous pending_previous origin last_observed retry_status
  if [[ -e "$success_pending_file" ]]; then
    finalize_success
    return $?
  fi
  flush_status_outbox
  candidate=$(fetch_main)
  valid_revision "$candidate" || { log "origin/main did not resolve to a full revision"; return 1; }
  last_observed=$(read_state "$control_dir/last-observed")
  if [[ "$candidate" == "$last_observed" ]]; then
    clear_retry_state || return 1
    return 0
  fi
  if retry_is_deferred "$candidate"; then
    return 0
  else
    retry_status=$?
    [[ "$retry_status" -eq 1 ]] || return 1
  fi

  if ! has_deploy_contract "$candidate"; then
    log "main@$candidate has no CandaceOS deployment contract; updater remains armed"
    clear_retry_state || return 1
    record_receipt_once "$candidate" "" skipped contract-absent || {
      log "warning: could not persist contract-absent receipt for main@$candidate"
      return 1
    }
    write_state "$control_dir/last-observed" "$candidate" || return 1
    return 0
  fi

  previous=$(read_state "$control_dir/current")
  origin=$(read_state "$control_dir/current-origin")
  if ! affects_candaceos "$previous" "$candidate" "$origin"; then
    log "main@$candidate does not change CandaceOS; leaving $previous active"
    clear_retry_state || return 1
    record_receipt_once "$candidate" "$previous" skipped irrelevant || {
      log "warning: could not persist irrelevant-change receipt for main@$candidate"
      return 1
    }
    write_state "$control_dir/last-observed" "$candidate" || return 1
    return 0
  fi

  post_status "$candidate" pending "Deploying to the CandaceOS bootstrap node" || true
  if deploy_revision "$candidate"; then
    pending_previous=none
    if valid_revision "$previous"; then
      pending_previous=$previous
    fi
    write_state "$success_pending_file" "$candidate $pending_previous" || {
      log "warning: could not persist success finalization for main@$candidate"
      return 1
    }
    finalize_success
    return $?
  fi
  handle_deployment_failure "$candidate" "$previous"
}

main() {
  [[ -f "$token_file" && -s "$token_file" ]] || { log "GitHub/Copilot credential file is missing or empty"; exit 1; }
  export CANDACEOS_GITHUB_TOKEN_FILE="$token_file"
  export GIT_ASKPASS=/usr/local/bin/candaceos-git-askpass
  export GIT_TERMINAL_PROMPT=0

  if [[ "${1:-}" == --health ]]; then
    [[ -f "$heartbeat_file" ]] || exit 1
    # A source build plus Compose's bounded readiness wait can legitimately take
    # several minutes. Do not restart the updater in the middle of that
    # transaction; the deployment verification remains the actual readiness
    # gate.
    [[ $(($(date +%s) - $(stat -c %Y "$heartbeat_file"))) -le 1800 ]]
    exit
  fi
  [[ "$#" -eq 0 ]] || { printf 'Usage: candaceos-updater [--health]\n' >&2; exit 2; }

  mkdir -p "$state_root" "$control_dir" "$status_outbox_dir"
  exec 9>"$control_dir/updater.lock"
  flock --nonblock 9 || { log "another updater owns the deployment lock"; exit 1; }
  ensure_repo

  while true; do
    touch "$heartbeat_file"
    reconcile_once || true
    touch "$heartbeat_file"
    sleep "$poll_interval"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
