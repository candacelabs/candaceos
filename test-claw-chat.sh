#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
environment_projection="$script_dir/environment.generated.sh"

die() {
  printf 'candaceos Claw acceptance: %s\n' "$*" >&2
  exit 1
}

for command in curl docker grep mktemp openssl sed; do
  command -v "$command" >/dev/null || die "$command is required"
done
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"
[[ -r "$environment_projection" ]] || die "generated environment projection is missing"
# shellcheck source=environment.generated.sh
source "$environment_projection"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/candaceos-claw-acceptance.XXXXXX")
state_root="$temporary/state"
workspace="$temporary/apps"
env_file="$temporary/.env"
project_name="candaceos-claw-acceptance-$(id -u)-$(openssl rand -hex 6)"
export CANDACEOS_ACCEPTANCE_IMAGE_PREFIX="$project_name"
acceptance_images=(
  "$project_name-core:test"
  "$project_name-opencode:test"
  "$project_name-warden:test"
)
sse_pid=

compose=(
  docker compose
  --project-name "$project_name"
  --project-directory "$script_dir"
  --env-file "$env_file"
  -f "$script_dir/compose.yaml"
  -f "$script_dir/compose.environment.generated.yaml"
  -f "$script_dir/compose.acceptance.yaml"
)

stop_sse() {
  [[ -n "$sse_pid" ]] || return 0
  kill "$sse_pid" >/dev/null 2>&1 || true
  wait "$sse_pid" >/dev/null 2>&1 || true
  sse_pid=
}

cleanup() {
  local status=$?
  stop_sse
  "${compose[@]}" --profile opencode down --volumes --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  docker image rm "${acceptance_images[@]}" >/dev/null 2>&1 || true
  rm -rf -- "$temporary"
  return "$status"
}
trap cleanup EXIT

mkdir -p \
  "$workspace" \
  "$state_root/revisions" \
  "$state_root/runtime/core" \
  "$state_root/runtime/opencode" \
  "$state_root/runtime/warden"

candaceos_environment_reconcile "$env_file" "$state_root" "$workspace" || \
  die "could not materialize the disposable environment"
candaceos_environment_apply_defaults
candaceos_environment_apply_profile "$candaceos_profile_local"
candaceos_environment_apply_profile "$candaceos_profile_demo"

# This deterministic gate never sends a provider request. Do not accidentally
# pass a developer's live credential into the health-only OpenCode sidecar.
unset "$candaceos_env_openai_api_key" "$candaceos_env_anthropic_api_key" "$candaceos_env_openrouter_api_key"

printf 'candaceos Claw acceptance: disposable demo-backed stack setup\n'
"${compose[@]}" --profile opencode config --quiet
"${compose[@]}" --profile opencode up \
  --detach --build --wait --wait-timeout 180 \
  postgres warden opencode core

core_address=$("${compose[@]}" port core 7780)
[[ "$core_address" == 127.0.0.1:* ]] || die "Core was not published on a disposable loopback port"
base_url="http://$core_address"

opencode_container=$("${compose[@]}" ps --quiet opencode)
[[ -n "$opencode_container" ]] || die "OpenCode container is missing"
opencode_address=$(docker port "$opencode_container" 2>/dev/null || true)
[[ -z "$opencode_address" ]] || die "OpenCode unexpectedly published a host port"

# A different container reaches Core through the shared private network. This
# fails if Core regresses to a loopback-only process listener.
"${compose[@]}" exec -T opencode \
  curl --fail --silent --show-error --max-time 3 http://core:7780/healthz >/dev/null
# Core reaches the separate OpenCode service through Basic auth without any
# host-published provider port. The credential travels through curl's stdin
# config rather than its argument vector, so it stays out of both process
# tables.
printf 'user = "%s:%s"\n' \
  "${!candaceos_env_opencode_username}" "${!candaceos_env_opencode_password}" | \
  "${compose[@]}" exec -T core \
    curl --config - --fail --silent --show-error --max-time 3 \
      http://opencode:4096/global/health >/dev/null

printf 'candaceos Claw acceptance: dashboard and live stream\n'
dashboard="$temporary/dashboard.html"
curl --fail --silent --show-error --max-time 5 "$base_url/" >"$dashboard"
grep -Fq 'What do you want?' "$dashboard" || die "dashboard did not render"

sse="$temporary/events.sse"
curl --no-buffer --silent --show-error --max-time 30 "$base_url/api/events" >"$sse" 2>/dev/null &
sse_pid=$!

for _ in {1..50}; do
  grep -Fq 'event: snapshot' "$sse" && break
  sleep 0.1
done
grep -Fq 'event: snapshot' "$sse" || die "event stream did not publish its initial snapshot"

prompt_response="$temporary/prompt.json"
prompt_status=$(curl --silent --show-error --max-time 5 \
  --output "$prompt_response" --write-out '%{http_code}' \
  --header 'Content-Type: application/json' \
  --header "Origin: $base_url" \
  --data '{"prompt":"prove the live Claw chat path"}' \
  "$base_url/api/prompts")
[[ "$prompt_status" == 202 ]] || die "initial prompt returned HTTP $prompt_status"
run_id=$(sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p' "$prompt_response")
[[ -n "$run_id" ]] || die "initial prompt returned no run ID"

snapshot="$temporary/snapshot.json"
session_id=
for _ in {1..50}; do
  curl --fail --silent --show-error --max-time 5 "$base_url/api/snapshot" >"$snapshot"
  session_id=$(sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p' "$snapshot")
  [[ -n "$session_id" ]] && break
  sleep 0.1
done
[[ -n "$session_id" ]] || die "snapshot did not expose the Claw session"
grep -Fq "\"id\":\"$run_id\"" "$snapshot" || die "snapshot did not expose the accepted run"

curl --fail --silent --show-error --max-time 5 "$base_url/" >"$dashboard"
grep -Fq "href=\"/claws/$session_id/chat\"" "$dashboard" || die "dashboard run did not link to its chat"

chat="$temporary/chat.html"
curl --fail --silent --show-error --max-time 5 "$base_url/claws/$session_id/chat" >"$chat"
grep -Fq "data-chat-session=\"$session_id\"" "$chat" || die "chat page lost its session fence"
grep -Fq "data-expected-run-id=\"$run_id\"" "$chat" || die "chat page lost its run fence"
grep -Fq 'Send after current' "$chat" || die "chat page omitted enqueue control"
grep -Fq 'Steer now' "$chat" || die "chat page omitted immediate control"
grep -Fq 'Depending on the provider, it may interject or restart its work' "$chat" || die "chat page misstated immediate steering semantics"
enqueue_delivery=$(sed -n 's/.*data-chat-enqueue[^>]*data-delivery="\([^"]*\)".*/\1/p' "$chat" | sed -n '1p')
immediate_delivery=$(sed -n 's/.*data-chat-immediate[^>]*data-delivery="\([^"]*\)".*/\1/p' "$chat" | sed -n '1p')
[[ -n "$enqueue_delivery" ]] || die "chat page omitted its generated enqueue delivery value"
[[ -n "$immediate_delivery" ]] || die "chat page omitted its generated immediate delivery value"
[[ "$enqueue_delivery" != "$immediate_delivery" ]] || die "chat controls rendered the same delivery value"

for _ in {1..50}; do
  grep -Fq 'prove the live Claw chat path' "$sse" && \
    grep -Fq 'Demo plan complete' "$sse" && break
  sleep 0.1
done
grep -Fq 'prove the live Claw chat path' "$sse" || die "event stream omitted the user transcript"
grep -Fq 'Demo plan complete' "$sse" || die "event stream omitted the assistant transcript"
stop_sse

printf 'candaceos Claw acceptance: idle follow-up, exact-run abort, and fencing\n'
for _ in {1..50}; do
  curl --fail --silent --show-error --max-time 5 "$base_url/api/snapshot" >"$snapshot"
  grep -Fq '"status":"succeeded"' "$snapshot" && break
  sleep 0.1
done
grep -Fq '"status":"succeeded"' "$snapshot" || die "initial demo turn did not complete"

steer_response="$temporary/steer.json"
steer_status=
for _ in {1..50}; do
  steer_status=$(curl --silent --show-error --max-time 5 \
    --output "$steer_response" --write-out '%{http_code}' \
    --header 'Content-Type: application/json' \
    --header "Origin: $base_url" \
    --data "{\"prompt\":\"follow after current\",\"delivery\":\"$enqueue_delivery\",\"expectedRunId\":\"$run_id\"}" \
    "$base_url/api/claws/$session_id/messages")
  [[ "$steer_status" == 202 ]] && break
  [[ "$steer_status" == 409 ]] || break
  sleep 0.1
done
[[ "$steer_status" == 202 ]] || die "enqueued follow-up returned HTTP $steer_status"
follow_run_id=$(sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p' "$steer_response")
[[ -n "$follow_run_id" ]] || die "enqueued follow-up returned no run ID"

abort_response="$temporary/abort.json"
abort_status=$(curl --silent --show-error --max-time 5 \
  --output "$abort_response" --write-out '%{http_code}' \
  --header 'Content-Type: application/json' \
  --header "Origin: $base_url" \
  --data '{}' \
  "$base_url/api/claws/$session_id/runs/$follow_run_id/abort")
[[ "$abort_status" == 200 ]] || die "exact-run abort returned HTTP $abort_status"
grep -Fq '"status":"aborted"' "$abort_response" || die "exact-run abort was not acknowledged"

for _ in {1..50}; do
  curl --fail --silent --show-error --max-time 5 "$base_url/api/snapshot" >"$snapshot"
  grep -Fq '"status":"aborted"' "$snapshot" && break
  sleep 0.1
done
grep -Fq '"status":"aborted"' "$snapshot" || die "aborted state did not reach the browser snapshot"

stale_response="$temporary/stale.json"
stale_status=$(curl --silent --show-error --max-time 5 \
  --output "$stale_response" --write-out '%{http_code}' \
  --header 'Content-Type: application/json' \
  --header "Origin: $base_url" \
  --data "{\"prompt\":\"stale browser guidance\",\"delivery\":\"$enqueue_delivery\",\"expectedRunId\":\"stale-run\"}" \
  "$base_url/api/claws/$session_id/messages")
[[ "$stale_status" == 409 ]] || die "stale run fence returned HTTP $stale_status"
grep -Fq 'agent run changed' "$stale_response" || die "stale run fence returned the wrong conflict"

reconnected="$temporary/reconnected.sse"
curl --no-buffer --silent --show-error --max-time 2 "$base_url/api/events" >"$reconnected" 2>/dev/null || true
grep -Fq 'event: snapshot' "$reconnected" || die "reconnected event stream omitted its snapshot"
grep -Fq "\"id\":\"$follow_run_id\"" "$reconnected" || die "reconnected event stream lost the current run"

printf 'candaceos Claw acceptance: pinned SDK contract and deterministic harness semantics\n'
core_image=$("${compose[@]}" images --quiet core)
[[ -n "$core_image" ]] || die "cannot resolve the Core image used by the disposable stack"
# Bare --env names inherit these from this process, keeping the contract
# credential off the docker command line.
export CANDACEOS_OPENCODE_CONTRACT_USERNAME="${!candaceos_env_opencode_username}"
export CANDACEOS_OPENCODE_CONTRACT_PASSWORD="${!candaceos_env_opencode_password}"
docker run --rm \
  --read-only \
  --user "${!candaceos_env_uid}:${!candaceos_env_gid}" \
  --network "${project_name}_opencode" \
  --tmpfs /tmp:rw,exec,nosuid,size=1g \
  --env CGO_ENABLED=0 \
  --env GOCACHE=/tmp/go-build \
  --env GOMODCACHE=/tmp/go-mod \
  --env GOFLAGS=-mod=readonly \
  --env CANDACEOS_OPENCODE_CONTRACT_URL=http://opencode:4096 \
  --env CANDACEOS_OPENCODE_CONTRACT_USERNAME \
  --env CANDACEOS_OPENCODE_CONTRACT_PASSWORD \
  --volume "$repository_root/go:/src:ro" \
  --workdir /src \
  --entrypoint /usr/local/go/bin/go \
  "$core_image" \
  test \
    ./pkg/candaceos/harness/opencode \
    ./services/candaceos-core/internal/httpapi \
    ./services/candaceos-core/internal/webui \
    ./services/candaceos-core/internal/operator

printf 'candaceos Claw acceptance: PASS\n'
