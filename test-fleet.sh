#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

fail() {
  printf 'candaceos fleet test: %s\n' "$*" >&2
  exit 1
}

# Pin the topology explicitly. fleet.sh ships these same documentation-range
# defaults, but it also sources an optional deployment topology file, so the
# suite must assert against values it controls rather than whatever the
# invoking checkout happens to configure.
export CANDACEOS_CONTROL_TARGET=operator@203.0.113.10
export CANDACEOS_CONTROL_IP=203.0.113.10
export CANDACEOS_CONTROL_ID=control
export CANDACEOS_CONTROL_HOSTNAME=control.example.invalid
export CANDACEOS_AI_IP=203.0.113.11
export CANDACEOS_AI_ID=worker-gpu
export CANDACEOS_AI_USER=operator
export CANDACEOS_AI_HOSTNAME=worker-gpu.example.invalid
export CANDACEOS_PROD_TARGET=operator@203.0.113.12
export CANDACEOS_PROD_IP=203.0.113.12
export CANDACEOS_PROD_ID=worker

bash -n "$script_dir/fleet.sh" "$script_dir/fleet/node.sh"
sh -n "$script_dir/fleet/source.sh"

# Plan must be useful in a credential-free environment and must not call the
# mutation transports. A fake binary turns an accidental call into a test
# failure.
mkdir -p "$temporary/bin"
for binary in docker ssh scp rsync; do
  printf '#!/bin/sh\nexit 97\n' >"$temporary/bin/$binary"
  chmod 755 "$temporary/bin/$binary"
done
PATH="$temporary/bin:$PATH" CANDACEOS_AI_TARGET=local \
  "$script_dir/fleet.sh" plan >"$temporary/plan"
grep -q 'read-only; no credentials inspected' "$temporary/plan" || fail "plan does not declare its read-only contract"
grep -q 'operator@203.0.113.10' "$temporary/plan" || fail "plan lost the control default"
grep -q 'worker-gpu    local' "$temporary/plan" || fail "plan lost the local AI override"
grep -q 'git://203.0.113.10:9418/apps.git' "$temporary/plan" || fail "plan lost the source endpoint"
if grep -Eqi 'passcode|fleet\.sh credentials' "$temporary/plan"; then
  fail "plan still advertises the removed UI passcode"
fi
PATH="$temporary/bin:$PATH" CANDACEOS_AI_TARGET=local \
  CANDACEOS_OLLAMA_MODEL=not-a-tag CANDACEOS_OLLAMA_CONTEXT_TOKENS=many \
  CANDACEOS_OLLAMA_MAX_TOOL_CALLS=many CANDACEOS_OLLAMA_TURN_TIMEOUT=later \
  "$script_dir/fleet.sh" plan --harness copilot >"$temporary/copilot-plan"
grep -q 'using the host Copilot CLI' "$temporary/copilot-plan" || \
  fail "Copilot plan was invalidated by unused Ollama settings"
PATH="$temporary/bin:$PATH" CANDACEOS_AI_TARGET=local \
  "$script_dir/fleet.sh" plan --harness ollama >"$temporary/ollama-plan"
grep -q 'Ollama qwen3:8b at http://203.0.113.11:11434' "$temporary/ollama-plan" || \
  fail "Ollama plan does not expose the selected backend, model, and endpoint"
grep -q 'without reading or requiring any GitHub or Copilot credential' "$temporary/ollama-plan" || \
  fail "Ollama plan still claims a Copilot credential dependency"
grep -q 'only on worker-gpu' "$temporary/ollama-plan" || fail "Ollama plan does not constrain the large image to the AI node"
if CANDACEOS_AI_TARGET=local "$script_dir/fleet.sh" plan --harness unknown >/dev/null 2>&1; then
  fail "plan accepted an unknown harness backend"
fi
custom_sdk_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PATH="$temporary/bin:$PATH" CANDACEOS_AI_TARGET=local \
  "$script_dir/fleet.sh" plan --harness custom \
    --core-binary /does/not/need/to/exist/while/planning \
    --core-sdk-revision "$custom_sdk_revision" >"$temporary/custom-plan"
grep -q 'custom Core binary built from SDK aaaaaaaaaaaa' "$temporary/custom-plan" || \
  fail "custom plan does not identify the compiled SDK revision"
grep -q 'without reading or requiring any GitHub or Copilot credential' "$temporary/custom-plan" || \
  fail "custom plan still claims a provider credential dependency"
if CANDACEOS_AI_TARGET=local "$script_dir/fleet.sh" plan --harness custom \
  --core-sdk-revision "$custom_sdk_revision" >/dev/null 2>&1; then
  fail "custom plan accepted a missing Core binary path"
fi
if CANDACEOS_AI_TARGET=local "$script_dir/fleet.sh" plan --harness custom \
  --core-binary /tmp/core --core-sdk-revision short >/dev/null 2>&1; then
  fail "custom plan accepted an abbreviated SDK revision"
fi
if CANDACEOS_AI_TARGET=local "$script_dir/fleet.sh" plan --harness ollama \
  --core-binary /tmp/core --core-sdk-revision "$custom_sdk_revision" >/dev/null 2>&1; then
  fail "built-in harness accepted custom Core inputs"
fi
if CANDACEOS_AI_TARGET=local "$script_dir/fleet.sh" plan --state-root 'state;touch-injected' >/dev/null 2>&1; then
  fail "state-root accepted remote-shell metacharacters"
fi
if CANDACEOS_AI_TARGET=local "$script_dir/fleet.sh" plan --state-root 'state/../escape' >/dev/null 2>&1; then
  fail "state-root accepted parent traversal"
fi

# OpenSSH reparses one joined remote command through a shell. Prove node_run's
# %q encoding preserves metacharacters as data instead of executing them.
cat >"$temporary/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while [[ "${1:-}" == -o ]]; do
  shift 2
done
shift # target
remote_command=$1
exec bash -c "$remote_command"
EOF
chmod 755 "$temporary/bin/ssh"
special_args=('plain' 'with space' 'semi;colon' 'pipe|value' 'single'\''quote' '$dollar`tick`')
{
  for argument in "${special_args[@]}"; do
    printf '<%s>\n' "$argument"
  done
} >"$temporary/argv.expected"
PATH="$temporary/bin:$PATH" HOME="$temporary/home-argv" \
  CANDACEOS_FLEET_TESTING=1 CANDACEOS_FLEET_TEST_TARGET=test@host \
  "$script_dir/fleet.sh" _test-node-argv "${special_args[@]}" >"$temporary/argv.actual"
cmp "$temporary/argv.expected" "$temporary/argv.actual" || fail "SSH argument quoting did not round-trip"

# Ollama selection reuses only database/agent state. It must not inspect,
# generate, validate, or write either Copilot credential.
ollama_secret_work="$temporary/ollama-secret-work"
ollama_legacy_root="$temporary/ollama-legacy"
mkdir -p "$ollama_secret_work" "$ollama_legacy_root/workspace"
{
  printf 'POSTGRES_PASSWORD=%064d\n' 1
  printf 'CANDACEOS_AGENT_TOKEN=%064d\n' 2
  printf 'CANDACEOS_FLEET_POLL_INTERVAL=2s\n'
} >"$ollama_legacy_root/.env"
chmod 600 "$ollama_legacy_root/.env"
env -u COPILOT_GITHUB_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
  FLEET_SCRIPT="$script_dir/fleet.sh" OLLAMA_SECRET_WORK="$ollama_secret_work" \
  OLLAMA_LEGACY_ROOT="$ollama_legacy_root" bash -c '
    source "$FLEET_SCRIPT"
    harness_backend=ollama
    ai_target=local
    control_previous=
    work_dir="$OLLAMA_SECRET_WORK"
    discover_legacy() {
      legacy_workspace="$OLLAMA_LEGACY_ROOT/workspace"
      legacy_env="$OLLAMA_LEGACY_ROOT/.env"
    }
    node_run() { [[ "${2:-}" != legacy-token ]] || return 97; }
    select_secrets
    [[ "$postgres_password" == 0000000000000000000000000000000000000000000000000000000000000001 ]]
    [[ "$agent_token" == 0000000000000000000000000000000000000000000000000000000000000002 ]]
    [[ -z "${copilot_token:-}" && -z "${connection_token:-}" ]]
  ' || fail "Ollama secret selection retained a Copilot credential dependency"

ollama_receipt_root="$temporary/ollama-receipts"
FLEET_SCRIPT="$script_dir/fleet.sh" OLLAMA_RECEIPT_ROOT="$ollama_receipt_root" bash -c '
  source "$FLEET_SCRIPT"
  receipt_root="$OLLAMA_RECEIPT_ROOT"
  release_id=20260820T010101Z-aaaaaaaaaaaa
  source_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  app_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  database_fingerprint="tables=candaceos_runs=0|receipt_max=0"
  harness_backend=ollama
  ollama_model=qwen3:8b
  ollama_context_tokens=16384
  ollama_max_tool_calls=16
  ollama_turn_timeout=10m
  ollama_model_digest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  ollama_acceptance_run_id=acceptance-run-1
  control_previous=old-control
  ai_previous=old-ai
  prod_previous=old-prod
  legacy_names=()
  write_receipt deployed
'
ollama_receipt="$ollama_receipt_root/20260820T010101Z-aaaaaaaaaaaa.receipt"
[[ "$(stat -c %a "$ollama_receipt")" == 600 ]] || fail "Ollama receipt is not mode 600"
grep -qx 'harness_backend=ollama' "$ollama_receipt" || fail "receipt lost the selected harness"
grep -qx 'ollama_model=qwen3:8b' "$ollama_receipt" || fail "receipt lost the selected model"
grep -qx 'ollama_context_tokens=16384' "$ollama_receipt" || fail "receipt lost the warm context"
grep -qx 'ollama_max_tool_calls=16' "$ollama_receipt" || fail "receipt lost the tool-call bound"
grep -qx 'ollama_turn_timeout=10m' "$ollama_receipt" || fail "receipt lost the turn timeout"
grep -qx 'ollama_model_digest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  "$ollama_receipt" || fail "receipt lost the observed model digest"
grep -qx 'ollama_acceptance_run_id=acceptance-run-1' "$ollama_receipt" || \
  fail "receipt lost the Ollama tool-loop acceptance run"
grep -qx 'ollama_image_digest=sha256:e771d18fe56724f01a6f691a5773df544f36f565fb37c93f0ddc5957007b7766' \
  "$ollama_receipt" || fail "receipt lost the pinned Ollama image digest"
if grep -Eq '^copilot_(binary|sha256)=' "$ollama_receipt"; then
  fail "Ollama receipt contains inapplicable Copilot evidence"
fi

custom_receipt_root="$temporary/custom-receipts"
FLEET_SCRIPT="$script_dir/fleet.sh" CUSTOM_RECEIPT_ROOT="$custom_receipt_root" bash -c '
  source "$FLEET_SCRIPT"
  receipt_root="$CUSTOM_RECEIPT_ROOT"
  release_id=20260820T020202Z-aaaaaaaaaaaa
  source_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  custom_core_sdk_revision="$source_revision"
  custom_core_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  app_head=cccccccccccccccccccccccccccccccccccccccc
  database_fingerprint="tables=candaceos_runs=0|receipt_max=0"
  harness_backend=custom
  control_previous=old-control
  ai_previous=old-ai
  prod_previous=old-prod
  legacy_names=()
  write_receipt deployed
'
custom_receipt="$custom_receipt_root/20260820T020202Z-aaaaaaaaaaaa.receipt"
grep -qx 'harness_backend=custom' "$custom_receipt" || fail "receipt lost the custom harness"
grep -qx 'core_sdk_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$custom_receipt" || \
  fail "receipt lost the custom Core SDK revision"
grep -qx 'core_binary_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  "$custom_receipt" || fail "receipt lost the custom Core binary digest"
if grep -Eq '^(copilot_|ollama_)' "$custom_receipt"; then
  fail "custom receipt contains inapplicable built-in provider evidence"
fi

custom_build_marker="$temporary/custom-build-marker"
custom_build_work="$temporary/custom-build-work"
mkdir -p "$custom_build_work/source/candaceos" "$custom_build_work/source/go" "$custom_build_work/custom-core"
install -m 644 "$script_dir/Dockerfile.core" "$custom_build_work/source/candaceos/Dockerfile.core"
install -m 644 "$script_dir/Dockerfile.core.external" "$custom_build_work/source/candaceos/Dockerfile.core.external"
printf 'binary\n' >"$custom_build_work/custom-core/candaceos-core"
FLEET_SCRIPT="$script_dir/fleet.sh" CUSTOM_BUILD_WORK="$custom_build_work" \
  CUSTOM_BUILD_MARKER="$custom_build_marker" bash -c '
    source "$FLEET_SCRIPT"
    work_dir="$CUSTOM_BUILD_WORK"
    source_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    harness_backend=custom
    docker() {
      case "${1:-}" in
        info|pull|tag) return 0 ;;
        image)
          [[ "${2:-}" == inspect ]]
          printf "sha256:%064d\n" 1
          ;;
        build) printf "<%s>\n" "$@" >>"$CUSTOM_BUILD_MARKER" ;;
        *) return 0 ;;
      esac
    }
    node_run() { printf "sha256:%064d\n" 1; }
    build_images
  '
grep -qx '<--target>' "$custom_build_marker" || fail "custom Core build did not select the shared runtime stage"
grep -qx '<runtime>' "$custom_build_marker" || fail "custom Core build selected the wrong runtime stage"
grep -qx '<--build-arg>' "$custom_build_marker" || fail "custom Core build did not bind its runtime base"
grep -qx '<BASE_IMAGE=candaceos-core-runtime:fleet-aaaaaaaaaaaa>' "$custom_build_marker" || \
  fail "custom Core build did not bind the exact release runtime image"
grep -qx "<$custom_build_work/source/candaceos/Dockerfile.core.external>" "$custom_build_marker" || \
  fail "custom Core build did not use the external-binary overlay"

acceptance_payload="$temporary/ollama-acceptance-payload.json"
FLEET_SCRIPT="$script_dir/fleet.sh" ACCEPTANCE_PAYLOAD="$acceptance_payload" bash -c '
  source "$FLEET_SCRIPT"
  control_ip=203.0.113.10
  ollama_turn_timeout=10m
  curl() {
    local argument next_is_payload=false url=${!#}
    for argument in "$@"; do
      if $next_is_payload; then
        printf "%s" "$argument" >"$ACCEPTANCE_PAYLOAD"
        next_is_payload=false
      elif [[ "$argument" == --data-binary ]]; then
        next_is_payload=true
      fi
    done
    case "$url" in
      */api/prompts) printf "{\"run_id\":\"ollama-acceptance-1\"}\n" ;;
      */api/snapshot)
        printf "%s\n" "{\"run\":{\"id\":\"ollama-acceptance-1\",\"status\":\"succeeded\",\"entries\":[{\"kind\":\"tool\",\"name\":\"candace_fleet_status\",\"status\":\"complete\"},{\"kind\":\"message\",\"role\":\"assistant\",\"text\":\"The fleet has quorum.\"}]}}"
        ;;
      *) return 91 ;;
    esac
  }
  verify_ollama_tool_loop >/dev/null
  [[ "$ollama_acceptance_run_id" == ollama-acceptance-1 ]]
' || fail "Ollama Core acceptance did not bind a successful tool-loop run"
python3 - "$acceptance_payload" <<'PY'
import json
import sys

prompt = json.load(open(sys.argv[1], encoding="utf-8"))["prompt"]
assert "candace_fleet_status" in prompt
PY

if FLEET_SCRIPT="$script_dir/fleet.sh" bash -c '
    source "$FLEET_SCRIPT"
    control_ip=203.0.113.10
    ollama_turn_timeout=10m
    curl() {
      case "${!#}" in
        */api/prompts) printf "{\"run_id\":\"missing-tool\"}\n" ;;
        */api/snapshot) printf "{\"run\":{\"id\":\"missing-tool\",\"status\":\"succeeded\",\"entries\":[{\"kind\":\"message\",\"role\":\"assistant\",\"text\":\"No tool.\"}]}}\n" ;;
      esac
    }
    verify_ollama_tool_loop
  ' >/dev/null 2>&1; then
  fail "Ollama Core acceptance passed without a completed fleet-status tool"
fi

# Image archives travel through rsync's rolling delta algorithm into a stable
# destination. Preserve the old archive until the replacement completes and
# retain partials so an interrupted multi-gigabyte transfer can resume.
rsync_marker="$temporary/rsync-marker"
FLEET_SCRIPT="$script_dir/fleet.sh" RSYNC_MARKER="$rsync_marker" bash -c '
  source "$FLEET_SCRIPT"
  rsync() { printf "<%s>\n" "$@" >"$RSYNC_MARKER"; }
  node_rsync_to example@node /tmp/worker.tar /remote/image-cache/worker.tar
'
grep -qx '<--checksum>' "$rsync_marker" || fail "image rsync does not verify its basis by content"
grep -qx '<--no-whole-file>' "$rsync_marker" || fail "image rsync disabled rolling deltas"
grep -qx '<--partial>' "$rsync_marker" || fail "image rsync does not preserve interrupted work"
grep -qx '<--partial-dir=.rsync-partial>' "$rsync_marker" || fail "image rsync partials are not resumable"
if grep -qx '<--inplace>' "$rsync_marker"; then
  fail "image rsync can corrupt its prior delta basis on interruption"
fi
grep -qx '</tmp/worker.tar>' "$rsync_marker" || fail "image rsync lost its source archive"
grep -qx '<example@node:/remote/image-cache/worker.tar>' "$rsync_marker" || \
  fail "image rsync lost its stable remote cache path"

# Deploy and manual rollback share one nonblocking operator-host lock. A held
# descriptor must reject a contender; releasing it permits the next command.
lock_root="$temporary/operator-lock"
mkdir -p "$lock_root"
chmod 700 "$lock_root"
exec {held_lock_fd}>"$lock_root/operator.lock"
flock -n "$held_lock_fd"
if FLEET_SCRIPT="$script_dir/fleet.sh" LOCK_ROOT="$lock_root" bash -c '
  source "$FLEET_SCRIPT"
  receipt_root="$LOCK_ROOT"
  acquire_fleet_lock
' >/dev/null 2>&1; then
  fail "operator lock admitted a concurrent mutation"
fi
flock -u "$held_lock_fd"
exec {held_lock_fd}>&-
FLEET_SCRIPT="$script_dir/fleet.sh" LOCK_ROOT="$lock_root" bash -c '
  source "$FLEET_SCRIPT"
  receipt_root="$LOCK_ROOT"
  acquire_fleet_lock
'
[[ "$(stat -c '%a' "$lock_root")" == 700 ]] || fail "operator lock root is not mode 700"

# Nounset exits without running an ERR trap. Simulate the real cutover
# boundary, package and transfer one role, then trigger nounset. The root EXIT
# handler must perform exactly one rollback/receipt pair and still clean up.
trap_marker="$temporary/trap-marker"
cutover_work="$temporary/cutover-work"
if FLEET_SCRIPT="$script_dir/fleet.sh" TRAP_MARKER="$trap_marker" CUTOVER_WORK="$cutover_work" bash -c '
  source "$FLEET_SCRIPT"
  work_dir="$CUTOVER_WORK"
  mkdir -p "$work_dir/source/candaceos/fleet"
  printf "services: {}\n" >"$work_dir/source/candaceos/fleet/control.compose.yaml"
  printf "node_id: control\n" >"$work_dir/source/candaceos/fleet/warden.yaml"
  printf "TEST=value\n" >"$work_dir/control.env"
  printf "bundle\n" >"$work_dir/apps.bundle"
  release_id=20260819T010101Z-111111111111
  cutover_started=true
  rollback_candidate() { printf "rollback\n" >>"$TRAP_MARKER"; }
  write_receipt() { printf "receipt\n" >>"$TRAP_MARKER"; }
  node_copy_to() {
    [[ "$2" == "$work_dir/control.tgz" ]]
    printf "transfer\n" >>"$TRAP_MARKER"
  }
  node_run() { return 0; }
  trap deployment_exit EXIT
  package_role control "$work_dir/control.env" control.compose.yaml
  transfer_release example@node /remote/root control
  : "$nounset_after_cutover"
' >/dev/null 2>&1; then
  fail "nounset-after-cutover test unexpectedly succeeded"
fi
[[ "$(grep -c '^transfer$' "$trap_marker")" == 1 ]] || fail "role archive did not reach transfer"
[[ "$(grep -c '^rollback$' "$trap_marker")" == 1 ]] || fail "EXIT handler did not roll back exactly once"
[[ "$(grep -c '^receipt$' "$trap_marker")" == 1 ]] || fail "EXIT handler did not write exactly one receipt"
[[ ! -e "$cutover_work" ]] || fail "EXIT handler did not clean the cutover work directory"

# HUP/INT/TERM can otherwise enter EXIT with status zero. Verify every signal
# maps to a failing status and reaches the same exactly-once recovery path.
for signal_case in HUP:129 INT:130 TERM:143; do
  signal=${signal_case%%:*}
  expected_status=${signal_case#*:}
  signal_marker="$temporary/signal-$signal.marker"
  signal_work="$temporary/signal-$signal.work"
  set +e
  FLEET_SCRIPT="$script_dir/fleet.sh" SIGNAL_NAME="$signal" SIGNAL_MARKER="$signal_marker" \
    SIGNAL_WORK="$signal_work" bash -c '
      source "$FLEET_SCRIPT"
      work_dir="$SIGNAL_WORK"
      mkdir -p "$work_dir"
      release_id=20260819T010101Z-111111111111
      cutover_started=true
      rollback_candidate() { printf "rollback\n" >>"$SIGNAL_MARKER"; }
      write_receipt() { printf "receipt\n" >>"$SIGNAL_MARKER"; }
      install_deployment_traps
      kill -s "$SIGNAL_NAME" "$$"
    ' >/dev/null 2>&1
  signal_status=$?
  set -e
  [[ "$signal_status" == "$expected_status" ]] || fail "$signal exited $signal_status, expected $expected_status"
  [[ "$(grep -c '^rollback$' "$signal_marker")" == 1 ]] || fail "$signal did not roll back exactly once"
  [[ "$(grep -c '^receipt$' "$signal_marker")" == 1 ]] || fail "$signal did not write exactly one receipt"
  [[ ! -e "$signal_work" ]] || fail "$signal did not clean the work directory"
done

# Automatic failure recovery must still attempt every activated node. If the
# AI candidate cannot be rolled back, legacy services must stay stopped to
# avoid binding the same agent port.
partial_marker="$temporary/partial-automatic.marker"
if FLEET_SCRIPT="$script_dir/fleet.sh" PARTIAL_MARKER="$partial_marker" bash -c '
  source "$FLEET_SCRIPT"
  release_id=20260819T010101Z-111111111111
  prod_target=prod@node
  ai_target=ai@node
  control_target=control@node
  prod_activated=true
  ai_activated=true
  control_activated=true
  cutover_started=true
  legacy_names=(legacy-core legacy-database)
  node_run() {
    printf "%s:%s\n" "$1" "$2" >>"$PARTIAL_MARKER"
    [[ "$1:$2" != ai@node:rollback ]]
  }
  rollback_candidate
' >/dev/null 2>&1; then
  fail "partial automatic rollback unexpectedly succeeded"
fi
grep -qx 'prod@node:rollback' "$partial_marker" || fail "partial rollback skipped prod"
grep -qx 'ai@node:rollback' "$partial_marker" || fail "partial rollback skipped AI"
grep -qx 'control@node:rollback' "$partial_marker" || fail "partial rollback skipped control"
if grep -q ':restore-legacy$' "$partial_marker"; then
  fail "legacy restarted after the AI candidate rollback failed"
fi

# An already-existing fleet is authoritative. A failed exact-release env copy
# must abort, never fall through into first-migration legacy discovery.
credential_marker="$temporary/credential-marker"
if FLEET_SCRIPT="$script_dir/fleet.sh" TEST_DIR="$temporary" CREDENTIAL_MARKER="$credential_marker" bash -c '
  source "$FLEET_SCRIPT"
  work_dir="$TEST_DIR/credential-test"
  mkdir -p "$work_dir"
  control_previous=20260819T010101Z-111111111111
  download_current_control_env() { return 42; }
  discover_legacy() { printf "legacy\n" >>"$CREDENTIAL_MARKER"; }
  select_secrets
' >/dev/null 2>&1; then
  fail "failed current credential copy did not abort"
fi
[[ ! -e "$credential_marker" ]] || fail "current credential failure fell through to legacy discovery"

# Manual receipt rollback is resumable: one failed node must not prevent the
# other two attempts, and a failed AI rollback must gate legacy restart.
manual_receipt="$temporary/manual-partial.receipt"
{
  printf 'format=1\nstatus=deployed\nrelease_id=20260819T010101Z-111111111111\n'
  printf 'source_revision=\napp_head=\ndatabase_fingerprint=\npostgres_upstream=unknown\n'
  printf 'control_target=control@node\ncontrol_previous=\n'
  printf 'ai_target=ai@node\nai_previous=\n'
  printf 'prod_target=prod@node\nprod_previous=\n'
  printf 'control_ip=10.0.0.1\nai_ip=10.0.0.2\nprod_ip=10.0.0.3\n'
  printf 'state_root=.local/share/candaceos-fleet\n'
  printf 'legacy_target=ai@node\nlegacy_names=legacy-core,legacy-database\n'
} >"$manual_receipt"
chmod 600 "$manual_receipt"
manual_marker="$temporary/manual-partial.marker"
set +e
FLEET_SCRIPT="$script_dir/fleet.sh" MANUAL_MARKER="$manual_marker" \
  CANDACEOS_FLEET_RECEIPT_ROOT="$temporary/manual-lock" \
  bash -c '
    source "$FLEET_SCRIPT"
    node_run() {
      printf "%s:%s\n" "$1" "$2" >>"$MANUAL_MARKER"
      [[ "$1:$2" != ai@node:rollback ]]
    }
    rollback_from_receipt "$1"
  ' bash "$manual_receipt" >/dev/null 2>&1
manual_status=$?
set -e
[[ "$manual_status" != 0 ]] || fail "partial manual rollback unexpectedly succeeded"
grep -qx 'prod@node:rollback' "$manual_marker" || fail "manual rollback skipped prod"
grep -qx 'ai@node:rollback' "$manual_marker" || fail "manual rollback skipped AI"
grep -qx 'control@node:rollback' "$manual_marker" || fail "manual rollback skipped control"
if grep -q ':restore-legacy$' "$manual_marker"; then
  fail "manual rollback restarted legacy after AI rollback failure"
fi

# A journal fsynced before the first stop must make SIGKILL/reboot recovery
# independent of a running legacy Copilot container. Model an installed,
# activated-but-uncommitted AI candidate and require automatic rollback before
# the recorded legacy names restart. A second recovery pass is a no-op.
crash_receipt_root="$temporary/crash-receipts"
mkdir -p "$crash_receipt_root"
crash_receipt="$crash_receipt_root/20260819T010101Z-111111111111.receipt"
{
  printf 'format=1\nstatus=cutover\nrelease_id=20260819T010101Z-111111111111\n'
  printf 'source_revision=\napp_head=\ndatabase_fingerprint=\npostgres_upstream=unknown\n'
  printf 'control_target=control@node\ncontrol_previous=\n'
  printf 'ai_target=ai@node\nai_previous=\n'
  printf 'prod_target=prod@node\nprod_previous=\n'
  printf 'control_ip=10.0.0.1\nai_ip=10.0.0.2\nprod_ip=10.0.0.3\n'
  printf 'state_root=.local/share/candaceos-fleet\n'
  printf 'legacy_target=ai@node\nlegacy_names=legacy-core,legacy-database\n'
} >"$crash_receipt"
chmod 600 "$crash_receipt"
crash_marker="$temporary/crash-recovery.marker"
FLEET_SCRIPT="$script_dir/fleet.sh" CRASH_RECEIPTS="$crash_receipt_root" \
  CRASH_MARKER="$crash_marker" bash -c '
    source "$FLEET_SCRIPT"
    receipt_root="$CRASH_RECEIPTS"
    node_run() {
      printf "%s:%s\n" "$1" "$2" >>"$CRASH_MARKER"
      case "$2" in
        release-installed) printf "true\n" ;;
        rollback) [[ "$6" == automatic ]] ;;
        restore-legacy|verify-legacy) [[ "$1" == ai@node ]] ;;
        legacy-workspace) return 88 ;;
        *) return 89 ;;
      esac
    }
    recover_interrupted_cutover
    first_count=$(wc -l <"$CRASH_MARKER")
    recover_interrupted_cutover
    [[ "$(wc -l <"$CRASH_MARKER")" == "$first_count" ]]
  ' >/dev/null
grep -qx 'status=recovered' "$crash_receipt" || fail "crash journal was not marked recovered"
grep -qx 'prod@node:rollback' "$crash_marker" || fail "installed prod candidate was not automatically rolled back"
grep -qx 'ai@node:rollback' "$crash_marker" || fail "installed uncommitted AI candidate was not rolled back"
grep -qx 'control@node:rollback' "$crash_marker" || fail "installed control candidate was not automatically rolled back"
grep -qx 'ai@node:restore-legacy' "$crash_marker" || fail "journaled legacy names were not restored"
grep -qx 'ai@node:verify-legacy' "$crash_marker" || fail "restored legacy services were not verified"
if grep -q ':legacy-workspace$' "$crash_marker"; then
  fail "crash recovery tried to rediscover stopped legacy Copilot"
fi

# A pre-cutover Ollama staging journal has only an installed AI candidate. It
# must remove that candidate without assuming control or legacy was stopped.
staging_receipt_root="$temporary/staging-receipts"
mkdir -p "$staging_receipt_root"
staging_receipt="$staging_receipt_root/20260819T015151Z-151515151515.receipt"
{
  printf 'format=1\nstatus=staging\nrelease_id=20260819T015151Z-151515151515\n'
  printf 'source_revision=\napp_head=\ndatabase_fingerprint=\npostgres_upstream=unknown\n'
  printf 'control_target=control@node\ncontrol_previous=old-control\n'
  printf 'ai_target=ai@node\nai_previous=old-ai\n'
  printf 'prod_target=prod@node\nprod_previous=old-prod\n'
  printf 'control_ip=10.0.0.1\nai_ip=10.0.0.2\nprod_ip=10.0.0.3\n'
  printf 'state_root=.local/share/candaceos-fleet\nlegacy_target=ai@node\nlegacy_names=\n'
} >"$staging_receipt"
chmod 600 "$staging_receipt"
staging_marker="$temporary/staging-recovery.marker"
FLEET_SCRIPT="$script_dir/fleet.sh" STAGING_RECEIPTS="$staging_receipt_root" \
  STAGING_MARKER="$staging_marker" bash -c '
    source "$FLEET_SCRIPT"
    receipt_root="$STAGING_RECEIPTS"
    node_run() {
      printf "%s:%s\n" "$1" "$2" >>"$STAGING_MARKER"
      case "$2" in
        release-installed) [[ "$1" == ai@node ]] && printf "true\n" || printf "false\n" ;;
        rollback) [[ "$1" == ai@node && "$6" == automatic ]] ;;
        current)
          case "$1" in
            control@node) printf "old-control\n" ;;
            prod@node) printf "old-prod\n" ;;
          esac
          ;;
        resume-control) [[ "$1" == control@node ]] ;;
        *) return 89 ;;
      esac
    }
    recover_interrupted_cutover
  ' >/dev/null
grep -qx 'status=recovered' "$staging_receipt" || fail "Ollama staging journal was not recovered"
grep -qx 'ai@node:rollback' "$staging_marker" || fail "staged Ollama candidate was not rolled back"
if grep -Eq '(control|prod)@node:rollback|:restore-legacy$' "$staging_marker"; then
  fail "Ollama staging recovery treated an untouched node as cut over"
fi

# When no candidate payload reached a node, an exact expected current release
# is sufficient. The quiesced control release still has to be resumed.
absent_receipt_root="$temporary/absent-receipts"
mkdir -p "$absent_receipt_root"
absent_receipt="$absent_receipt_root/20260819T020202Z-222222222222.receipt"
{
  printf 'format=1\nstatus=cutover\nrelease_id=20260819T020202Z-222222222222\n'
  printf 'source_revision=\napp_head=\ndatabase_fingerprint=\npostgres_upstream=unknown\n'
  printf 'control_target=control@node\ncontrol_previous=20260818T010101Z-aaaaaaaaaaaa\n'
  printf 'ai_target=ai@node\nai_previous=20260818T010101Z-bbbbbbbbbbbb\n'
  printf 'prod_target=prod@node\nprod_previous=20260818T010101Z-cccccccccccc\n'
  printf 'control_ip=10.0.0.1\nai_ip=10.0.0.2\nprod_ip=10.0.0.3\n'
  printf 'state_root=.local/share/candaceos-fleet\nlegacy_target=ai@node\nlegacy_names=\n'
} >"$absent_receipt"
chmod 600 "$absent_receipt"
absent_marker="$temporary/absent-recovery.marker"
FLEET_SCRIPT="$script_dir/fleet.sh" ABSENT_RECEIPTS="$absent_receipt_root" \
  ABSENT_MARKER="$absent_marker" bash -c '
    source "$FLEET_SCRIPT"
    receipt_root="$ABSENT_RECEIPTS"
    node_run() {
      printf "%s:%s\n" "$1" "$2" >>"$ABSENT_MARKER"
      case "$2" in
        release-installed) printf "false\n" ;;
        current)
          case "$1" in
            control@node) printf "20260818T010101Z-aaaaaaaaaaaa\n" ;;
            ai@node) printf "20260818T010101Z-bbbbbbbbbbbb\n" ;;
            prod@node) printf "20260818T010101Z-cccccccccccc\n" ;;
          esac
          ;;
        resume-control) [[ "$1" == control@node ]] ;;
        *) return 89 ;;
      esac
    }
    recover_interrupted_cutover
  ' >/dev/null
grep -qx 'status=recovered' "$absent_receipt" || fail "absent-candidate journal was not recovered"
grep -qx 'control@node:resume-control' "$absent_marker" || fail "quiesced previous control was not resumed"

# A transport failure while asking whether the candidate exists is not
# candidate absence. Recovery must remain unresolved and must not restart
# legacy services after losing contact with AI.
transport_receipt_root="$temporary/transport-receipts"
mkdir -p "$transport_receipt_root"
transport_receipt="$transport_receipt_root/20260819T030303Z-333333333333.receipt"
{
  printf 'format=1\nstatus=cutover\nrelease_id=20260819T030303Z-333333333333\n'
  printf 'source_revision=\napp_head=\ndatabase_fingerprint=\npostgres_upstream=unknown\n'
  printf 'control_target=control@node\ncontrol_previous=\nai_target=ai@node\nai_previous=\n'
  printf 'prod_target=prod@node\nprod_previous=\n'
  printf 'control_ip=10.0.0.1\nai_ip=10.0.0.2\nprod_ip=10.0.0.3\n'
  printf 'state_root=.local/share/candaceos-fleet\n'
  printf 'legacy_target=ai@node\nlegacy_names=legacy-core,legacy-database\n'
} >"$transport_receipt"
chmod 600 "$transport_receipt"
transport_marker="$temporary/transport-recovery.marker"
set +e
FLEET_SCRIPT="$script_dir/fleet.sh" TRANSPORT_RECEIPTS="$transport_receipt_root" \
  TRANSPORT_MARKER="$transport_marker" bash -c '
    source "$FLEET_SCRIPT"
    receipt_root="$TRANSPORT_RECEIPTS"
    node_run() {
      printf "%s:%s\n" "$1" "$2" >>"$TRANSPORT_MARKER"
      if [[ "$1:$2" == ai@node:release-installed ]]; then
        return 55
      fi
      case "$2" in
        release-installed) printf "false\n" ;;
        current) printf "\n" ;;
        *) return 89 ;;
      esac
    }
    recover_interrupted_cutover
  ' >/dev/null 2>&1
transport_status=$?
set -e
[[ "$transport_status" != 0 ]] || fail "transport-failed recovery unexpectedly succeeded"
grep -qx 'status=cutover' "$transport_receipt" || fail "transport-failed journal was incorrectly marked recovered"
if grep -Eq 'ai@node:(current|restore-legacy|verify-legacy)' "$transport_marker"; then
  fail "AI transport failure was mistaken for candidate absence"
fi

# The newest journal is authoritative. A newer completed deployment must
# suppress an older failed receipt instead of rolling current state backward.
superseded_root="$temporary/superseded-receipts"
mkdir -p "$superseded_root"
cp "$transport_receipt" "$superseded_root/older.receipt"
printf 'status=deployed\n' >"$superseded_root/newer.receipt"
chmod 600 "$superseded_root/older.receipt" "$superseded_root/newer.receipt"
touch -d '2026-08-19 01:00:00 UTC' "$superseded_root/older.receipt"
touch -d '2026-08-19 02:00:00 UTC' "$superseded_root/newer.receipt"
superseded_marker="$temporary/superseded.marker"
FLEET_SCRIPT="$script_dir/fleet.sh" SUPERSEDED_ROOT="$superseded_root" \
  SUPERSEDED_MARKER="$superseded_marker" bash -c '
    source "$FLEET_SCRIPT"
    receipt_root="$SUPERSEDED_ROOT"
    node_run() { printf "called\n" >>"$SUPERSEDED_MARKER"; return 90; }
    recover_interrupted_cutover
  '
[[ ! -e "$superseded_marker" ]] || fail "older failed receipt overrode newer deployed receipt"

# Runtime fingerprints deliberately ignore Docker metadata that does not affect
# execution, but reject changes to the image config or root filesystem.
fingerprint_bin="$temporary/fingerprint-bin"
mkdir -p "$fingerprint_bin"
cat >"$fingerprint_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == image && "$2" == inspect ]]
case "${3:-}" in
  metadata-a)
    printf '%s\n' '[{"Id":"sha256:111","RepoTags":["old:tag"],"Created":"2026-01-01T00:00:00Z","GraphDriver":{"Name":"overlay2"},"Architecture":"amd64","Os":"linux","RootFS":{"Type":"layers","Layers":["sha256:layer-1","sha256:layer-2"]},"Config":{"Cmd":["run"],"Env":["A=1"],"Labels":{"one":"1","two":"2"}}}]'
    ;;
  metadata-b)
    printf '%s\n' '[{"Config":{"OnBuild":null,"Healthcheck":null,"User":"","WorkingDir":"","Shell":[],"Labels":{"two":"2","one":"1"},"Env":["A=1"],"Cmd":["run"]},"RootFS":{"Layers":["sha256:layer-1","sha256:layer-2"],"Type":"layers"},"Os":"linux","Architecture":"amd64","Size":987654,"RepoDigests":["new@sha256:222"],"Id":"sha256:222"}]'
    ;;
  config-drift)
    printf '%s\n' '[{"Architecture":"amd64","Os":"linux","RootFS":{"Type":"layers","Layers":["sha256:layer-1","sha256:layer-2"]},"Config":{"Cmd":["run"],"Env":["A=2"],"Labels":{"one":"1","two":"2"}}}]'
    ;;
  layer-drift)
    printf '%s\n' '[{"Architecture":"amd64","Os":"linux","RootFS":{"Type":"layers","Layers":["sha256:layer-1","sha256:layer-3"]},"Config":{"Cmd":["run"],"Env":["A=1"],"Labels":{"one":"1","two":"2"}}}]'
    ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$fingerprint_bin/docker"
fingerprint_a=$(PATH="$fingerprint_bin:$PATH" HOME="$temporary/fingerprint-home-a" \
  bash "$script_dir/fleet/node.sh" image-fingerprint state metadata-a)
fingerprint_b=$(PATH="$fingerprint_bin:$PATH" HOME="$temporary/fingerprint-home-b" \
  bash "$script_dir/fleet/node.sh" image-fingerprint state metadata-b)
[[ "$fingerprint_a" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "runtime fingerprint is malformed"
[[ "$fingerprint_a" == "$fingerprint_b" ]] || fail "non-runtime Docker metadata changed the fingerprint"
PATH="$fingerprint_bin:$PATH" HOME="$temporary/fingerprint-home-verify" \
  bash "$script_dir/fleet/node.sh" verify-images state metadata-b "$fingerprint_a"
if PATH="$fingerprint_bin:$PATH" HOME="$temporary/fingerprint-home-config" \
    bash "$script_dir/fleet/node.sh" verify-images state config-drift "$fingerprint_a" >/dev/null 2>&1; then
  fail "runtime Config drift passed image verification"
fi
if PATH="$fingerprint_bin:$PATH" HOME="$temporary/fingerprint-home-layer" \
    bash "$script_dir/fleet/node.sh" verify-images state layer-drift "$fingerprint_a" >/dev/null 2>&1; then
  fail "RootFS layer drift passed image verification"
fi

# Exact release image fingerprints already present on a node must bypass
# docker save and rsync entirely. A mismatch must instead save one uncompressed
# role archive, rsync it to the stable cache, checksum it before load, and
# verify the same ref/fingerprint pairs afterward.
warden_fingerprint="sha256:$(printf 'a%.0s' {1..64})"
agent_fingerprint="sha256:$(printf 'b%.0s' {1..64})"
reuse_marker="$temporary/reuse-marker"
FLEET_SCRIPT="$script_dir/fleet.sh" REUSE_MARKER="$reuse_marker" bash -c '
  source "$FLEET_SCRIPT"
  warden_image=warden:exact
  agent_image=agent:exact
  warden_image_fingerprint="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  agent_image_fingerprint="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  node_run() { printf "<%s>\n" "$@" >>"$REUSE_MARKER"; return 0; }
  docker() { printf "docker\n" >>"$REUSE_MARKER"; return 90; }
  node_rsync_to() { printf "rsync\n" >>"$REUSE_MARKER"; return 91; }
  sync_images example@node worker
' >/dev/null
printf '<%s>\n' example@node verify-images .local/share/candaceos-fleet \
  warden:exact "$warden_fingerprint" agent:exact "$agent_fingerprint" >"$temporary/reuse.expected"
cmp "$temporary/reuse.expected" "$reuse_marker" || fail "existing image fingerprints were not checked exactly once"
[[ "$(grep -c '^docker$' "$reuse_marker" || true)" == 0 ]] || fail "existing exact images were retransmitted"
[[ "$(grep -c '^rsync$' "$reuse_marker" || true)" == 0 ]] || fail "existing exact images opened rsync"

sync_marker="$temporary/sync-marker"
sync_payload="$temporary/sync-payload"
sync_work="$temporary/sync-work"
FLEET_SCRIPT="$script_dir/fleet.sh" SYNC_MARKER="$sync_marker" SYNC_PAYLOAD="$sync_payload" \
  SYNC_WORK="$sync_work" bash -c '
  source "$FLEET_SCRIPT"
  work_dir="$SYNC_WORK"
  mkdir -p "$work_dir"
  warden_image=warden:exact
  agent_image=agent:exact
  warden_image_fingerprint="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  agent_image_fingerprint="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  verify_count=0
  node_run() {
    printf "<%s>\n" "$@" >>"$SYNC_MARKER"
    case "$2" in
      verify-images)
        verify_count=$((verify_count + 1))
        ((verify_count > 1))
        ;;
      prepare-image-upload) printf "/remote/image-cache/worker.tar\n" ;;
      load-image-archive)
        [[ "$4" == worker ]]
        [[ "$5" == "$(sha256sum "$SYNC_PAYLOAD" | awk "{print \$1}")" ]]
        ;;
    esac
  }
  docker() {
    [[ "$1" == save && "$2" == --output && "$4" == warden:exact && "$5" == agent:exact ]]
    printf "fleet-image-archive" >"$3"
  }
  node_rsync_to() {
    [[ "$1" == example@node && "$3" == /remote/image-cache/worker.tar ]]
    install -m 600 "$2" "$SYNC_PAYLOAD"
  }
  sync_images example@node worker
' >/dev/null
[[ "$(<"$sync_payload")" == fleet-image-archive ]] || fail "image archive was not rsynced verbatim"
printf '<%s>\n' example@node verify-images .local/share/candaceos-fleet \
  warden:exact "$warden_fingerprint" agent:exact "$agent_fingerprint" \
  example@node prepare-image-upload .local/share/candaceos-fleet worker \
  example@node load-image-archive .local/share/candaceos-fleet worker \
  "$(sha256sum "$sync_payload" | awk '{print $1}')" \
  example@node verify-images .local/share/candaceos-fleet \
  warden:exact "$warden_fingerprint" agent:exact "$agent_fingerprint" >"$temporary/sync.expected"
cmp "$temporary/sync.expected" "$sync_marker" || fail "rsynced image fingerprints were not re-verified unchanged"

if FLEET_SCRIPT="$script_dir/fleet.sh" SYNC_WORK="$temporary/sync-failure" bash -c '
  source "$FLEET_SCRIPT"
  work_dir="$SYNC_WORK"
  mkdir -p "$work_dir"
  warden_image=warden:exact
  agent_image=agent:exact
  warden_image_fingerprint="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  agent_image_fingerprint="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  node_run() {
    case "$2" in
      verify-images) return 1 ;;
      prepare-image-upload) printf "/remote/image-cache/worker.tar\n" ;;
      load-image-archive) return 0 ;;
    esac
  }
  docker() { printf "fleet-image-archive" >"$3"; }
  node_rsync_to() { return 0; }
  sync_images example@node worker
' >/dev/null 2>&1; then
  fail "post-load runtime fingerprint mismatch was accepted"
fi

# The node-side cache path is stable across releases and Docker only loads an
# archive after matching the sender's SHA-256.
image_load_home="$temporary/image-load-home"
image_load_bin="$temporary/image-load-bin"
image_load_marker="$temporary/image-load-marker"
mkdir -p "$image_load_home" "$image_load_bin"
cat >"$image_load_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '<%s>\n' "$@" >"${IMAGE_LOAD_MARKER:?}"
EOF
chmod 755 "$image_load_bin/docker"
image_cache_path=$(HOME="$image_load_home" bash "$script_dir/fleet/node.sh" prepare-image-upload state worker)
[[ "$image_cache_path" == "$image_load_home/state/image-cache/worker.tar" ]] || fail "worker image cache path is not stable"
printf 'node-image-archive' >"$image_cache_path"
chmod 600 "$image_cache_path"
image_cache_checksum=$(sha256sum "$image_cache_path" | awk '{print $1}')
PATH="$image_load_bin:$PATH" HOME="$image_load_home" IMAGE_LOAD_MARKER="$image_load_marker" \
  bash "$script_dir/fleet/node.sh" load-image-archive state worker "$image_cache_checksum"
printf '<%s>\n' load --input "$image_cache_path" >"$temporary/image-load.expected"
cmp "$temporary/image-load.expected" "$image_load_marker" || fail "verified image archive was not loaded exactly"
rm -f "$image_load_marker"
if PATH="$image_load_bin:$PATH" HOME="$image_load_home" IMAGE_LOAD_MARKER="$image_load_marker" \
    bash "$script_dir/fleet/node.sh" load-image-archive state worker \
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1; then
  fail "image cache checksum mismatch was accepted"
fi
[[ ! -e "$image_load_marker" ]] || fail "checksum-mismatched image archive reached Docker"

# The official Ollama image is pulled directly on the AI node by immutable
# manifest digest. It never enters the worker archive shared with the
# non-GPU worker.
ollama_image='ollama/ollama:0.20.4@sha256:e771d18fe56724f01a6f691a5773df544f36f565fb37c93f0ddc5957007b7766'
ollama_digest='sha256:e771d18fe56724f01a6f691a5773df544f36f565fb37c93f0ddc5957007b7766'
ollama_pull_bin="$temporary/ollama-pull-bin"
ollama_pull_log="$temporary/ollama-pull.log"
mkdir -p "$ollama_pull_bin"
cat >"$ollama_pull_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '<%s>\n' "$@" >>"$OLLAMA_PULL_LOG"
EOF
chmod 755 "$ollama_pull_bin/docker"
PATH="$ollama_pull_bin:$PATH" HOME="$temporary/ollama-pull-home" OLLAMA_PULL_LOG="$ollama_pull_log" \
  bash "$script_dir/fleet/node.sh" pull-pinned-image state "$ollama_image" "$ollama_digest" >/dev/null
printf '<%s>\n' pull "$ollama_image" image inspect "$ollama_image" >"$temporary/ollama-pull.expected"
cmp "$temporary/ollama-pull.expected" "$ollama_pull_log" || fail "AI node did not pull and inspect the exact pinned Ollama image"
if PATH="$ollama_pull_bin:$PATH" HOME="$temporary/ollama-pull-home-bad" OLLAMA_PULL_LOG="$ollama_pull_log" \
    bash "$script_dir/fleet/node.sh" pull-pinned-image state \
      'ollama/ollama:0.20.4@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
      'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1; then
  fail "node accepted an Ollama image outside the pinned manifest digest"
fi

ollama_target_log="$temporary/ollama-target.log"
FLEET_SCRIPT="$script_dir/fleet.sh" OLLAMA_TARGET_LOG="$ollama_target_log" bash -c '
  source "$FLEET_SCRIPT"
  harness_backend=ollama
  ai_target=operator@203.0.113.11
  node_run() { printf "<%s>\n" "$@" >"$OLLAMA_TARGET_LOG"; }
  node_rsync_to() { return 99; }
  prepare_ollama_image
'
printf '<%s>\n' operator@203.0.113.11 pull-pinned-image .local/share/candaceos-fleet \
  "$ollama_image" "$ollama_digest" >"$temporary/ollama-target.expected"
cmp "$temporary/ollama-target.expected" "$ollama_target_log" || fail "Ollama image was not constrained to the AI target"

# Model evidence comes from the Ollama API: the tags digest is normalized,
# declared tool capability is mandatory when present, and a loaded model must
# report GPU-resident bytes.
ollama_api_bin="$temporary/ollama-api-bin"
mkdir -p "$ollama_api_bin"
cat >"$ollama_api_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url=${!#}
case "$url" in
  */api/tags)
    printf '{"models":[{"name":"qwen3:8b","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}\n'
    ;;
  */api/show)
    if [[ "${OLLAMA_MISSING_TOOLS:-}" == 1 ]]; then
      printf '{"capabilities":["completion"]}\n'
    else
      printf '{"capabilities":["completion","tools","thinking"]}\n'
    fi
    ;;
  */api/ps)
    if [[ "${OLLAMA_NO_PROCESS:-}" == 1 ]]; then
      printf '{"models":[]}\n'
    else
      printf '{"models":[{"name":"qwen3:8b","size":4294967296,"size_vram":4294967296,"context_length":16384}]}\n'
    fi
    ;;
  *) exit 91 ;;
esac
EOF
chmod 755 "$ollama_api_bin/curl"
model_digest=$(PATH="$ollama_api_bin:$PATH" HOME="$temporary/ollama-api-home" \
  bash "$script_dir/fleet/node.sh" verify-ollama-model state http://203.0.113.11:11434 qwen3:8b 16384)
[[ "$model_digest" == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]] || \
  fail "Ollama model digest was not normalized from the tags endpoint"
if PATH="$ollama_api_bin:$PATH" HOME="$temporary/ollama-api-home-bad" OLLAMA_MISSING_TOOLS=1 \
    bash "$script_dir/fleet/node.sh" verify-ollama-model state \
      http://203.0.113.11:11434 qwen3:8b 16384 >/dev/null 2>&1; then
  fail "Ollama model without declared tool capability was accepted"
fi
if PATH="$ollama_api_bin:$PATH" HOME="$temporary/ollama-api-home-unloaded" OLLAMA_NO_PROCESS=1 \
    bash "$script_dir/fleet/node.sh" verify-ollama-model state \
      http://203.0.113.11:11434 qwen3:8b 16384 >/dev/null 2>&1; then
  fail "Ollama model without a loaded GPU process was accepted"
fi

# Legacy restoration must preserve every captured name and identify Postgres
# by its Compose service label, not a generated container-name suffix.
restore_bin="$temporary/restore-bin"
mkdir -p "$restore_bin"
cat >"$restore_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
  inspect)
    template=$3
    name=$4
    if [[ "$template" == *com.docker.compose.service* ]]; then
      [[ "$name" == legacy-database ]] && printf 'postgres\n' || printf 'core\n'
    else
      printf 'healthy\n'
    fi
    ;;
  start)
    shift
    printf 'start:%s\n' "$*" >>"$DOCKER_LOG"
    ;;
  *) exit 91 ;;
esac
EOF
chmod 755 "$restore_bin/docker"
restore_log="$temporary/restore.log"
HOME="$temporary/restore-home" PATH="$restore_bin:$PATH" DOCKER_LOG="$restore_log" \
  bash "$script_dir/fleet/node.sh" restore-legacy state \
    first-legacy-writer legacy-database candaceos-updater
grep -qx 'start:legacy-database' "$restore_log" || fail "legacy Postgres name was not restored first"
grep -qx 'start:first-legacy-writer' "$restore_log" || fail "first captured legacy name was lost"
grep -qx 'start:candaceos-updater' "$restore_log" || fail "legacy updater name was not restored last"

# Interrupted first activation can start candidate containers before current is
# committed. Automatic rollback must down that installed candidate even while
# current and previous are both empty.
uncommitted_home="$temporary/uncommitted-home"
uncommitted_root="$uncommitted_home/state"
uncommitted_release=20260819T040404Z-444444444444
uncommitted_dir="$uncommitted_root/releases/$uncommitted_release"
mkdir -p "$uncommitted_dir" "$temporary/uncommitted-bin"
printf 'archive_sha256=test\nrole=worker\n' >"$uncommitted_dir/.installed"
printf 'services: {}\n' >"$uncommitted_dir/compose.yaml"
printf 'TEST=value\n' >"$uncommitted_dir/.env"
chmod 600 "$uncommitted_dir/.installed" "$uncommitted_dir/.env"
cat >"$temporary/uncommitted-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$DOCKER_LOG"
EOF
chmod 755 "$temporary/uncommitted-bin/docker"
uncommitted_log="$temporary/uncommitted.log"
HOME="$uncommitted_home" PATH="$temporary/uncommitted-bin:$PATH" DOCKER_LOG="$uncommitted_log" \
  bash "$script_dir/fleet/node.sh" rollback state "$uncommitted_release" '' automatic '' >/dev/null
grep -q ' down --remove-orphans$' "$uncommitted_log" || fail "uncommitted initial candidate was not stopped"
[[ "$(HOME="$uncommitted_home" bash "$script_dir/fleet/node.sh" release-installed state "$uncommitted_release")" == true ]] || \
  fail "installed release query did not return structured true"
[[ "$(HOME="$uncommitted_home" bash "$script_dir/fleet/node.sh" release-installed state 20260819T050505Z-555555555555)" == false ]] || \
  fail "absent release query did not return structured false"

# Remote node commands start in the SSH user's home rather than a checkout.
# Bundle verification must therefore use the app repository explicitly.
bundle_home="$temporary/bundle-home"
bundle_workspace="$bundle_home/apps"
bundle_cwd="$bundle_home/non-repository"
bundle_release=20260819T060606Z-666666666666
mkdir -p "$bundle_workspace" "$bundle_cwd"
git -C "$bundle_workspace" init -q -b main
git -C "$bundle_workspace" config user.name 'Bundle Test'
git -C "$bundle_workspace" config user.email 'bundle-test@localhost'
printf 'bundle\n' >"$bundle_workspace/app.txt"
git -C "$bundle_workspace" add app.txt
git -C "$bundle_workspace" -c commit.gpgSign=false commit -q -m bundle
HOME="$bundle_home" bash "$script_dir/fleet/node.sh" prepare-upload state "$bundle_release" >/dev/null
bundle_head=$(cd "$bundle_cwd" && HOME="$bundle_home" \
  bash "$script_dir/fleet/node.sh" bundle-apps state "$bundle_release" "$bundle_workspace")
[[ "$bundle_head" == "$(git -C "$bundle_workspace" rev-parse HEAD)" ]] || \
  fail "bundle command returned the wrong HEAD outside a repository CWD"
[[ -s "$bundle_home/state/incoming/$bundle_release/apps.bundle" ]] || \
  fail "bundle command did not publish a verified bundle"
# The bundle lives outside any checkout, so operator-side verification needs an
# explicit repository context. Use the repository that actually contains this
# script: the monorepo root when this directory is candaceos/, and the
# snapshot's own root when it is the repository root.
operator_repository=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n "$operator_repository" ]]; then
  git -C "$operator_repository" bundle verify \
    "$bundle_home/state/incoming/$bundle_release/apps.bundle" >/dev/null 2>&1 || \
    fail "operator-side bundle verification lacks an explicit repository context"
else
  printf 'candaceos fleet test: skipping operator-side bundle verification; %s is not inside a Git worktree\n' \
    "$script_dir" >&2
fi

state="$temporary/state"
copilot_sha=2ebb491db8bbbad58fb111a34b3f92798da44341976e5a6021bc13c7e57ae9e6
mkdir -p "$state/apps" "$state/runtime/warden" "$state/runtime/core" \
  "$state/runtime/copilot" "$state/runtime/agent" "$state/revisions" \
  "$state/tools/copilot/1.0.80/$copilot_sha"
mkdir -p "$state/apps/.git"
printf '#!/bin/sh\nexit 0\n' >"$state/tools/copilot/1.0.80/$copilot_sha/copilot"
chmod 555 "$state/tools/copilot/1.0.80/$copilot_sha/copilot"

common_env() {
  local file=$1 node_id=$2 node_ip=$3 backend=${4:-copilot-cli}
  {
    printf 'CANDACEOS_WARDEN_IMAGE=candaceos-warden:test\n'
    printf 'CANDACEOS_AGENT_IMAGE=candaceos-agent:test\n'
    printf 'CANDACEOS_CORE_IMAGE=candaceos-core:test\n'
    printf 'CANDACEOS_SOURCE_IMAGE=candaceos-source:test\n'
    printf 'CANDACEOS_POSTGRES_IMAGE=postgres:test\n'
    printf 'CANDACEOS_CONTROL_IP=203.0.113.10\n'
    printf 'CANDACEOS_AI_IP=203.0.113.11\n'
    printf 'CANDACEOS_PROD_IP=203.0.113.12\n'
    printf 'CANDACEOS_WARDEN_PEERS=control=203.0.113.10:7717,worker-gpu=203.0.113.11:7717,worker=203.0.113.12:7717\n'
    printf 'CANDACEOS_NODE_ID=%s\nCANDACEOS_NODE_IP=%s\n' "$node_id" "$node_ip"
    printf 'CANDACEOS_HARNESS_BACKEND=%s\n' "$backend"
    printf 'CANDACEOS_UID=%s\nCANDACEOS_GID=%s\nCANDACEOS_DOCKER_GID=%s\n' "$(id -u)" "$(id -g)" "$(stat -c %g /var/run/docker.sock)"
    printf 'CANDACEOS_STATE_ROOT=%s\nCANDACEOS_HOST_WORKSPACE=%s/apps\n' "$state" "$state"
    printf 'CANDACEOS_AGENT_TOKEN=%064d\n' 0
    printf 'CANDACEOS_AGENT_SOURCE_REMOTE=git://203.0.113.10:9418/apps.git\n'
  } >"$file"
  chmod 600 "$file"
}

common_env "$temporary/control.env" control 203.0.113.10
{
  printf 'POSTGRES_PASSWORD=%064d\n' 0
  printf 'CANDACEOS_WEB_BIND_IP=203.0.113.10\n'
  printf 'CANDACEOS_COPILOT_CONNECTION_TOKEN=%064d\n' 0
  printf 'CANDACEOS_COPILOT_BIN=%s/tools/copilot/1.0.80/%s/copilot\n' "$state" "$copilot_sha"
  printf 'CANDACEOS_COPILOT_SHA256=%s\n' "$copilot_sha"
  printf 'COPILOT_GITHUB_TOKEN=test-token\n'
  printf 'CANDACEOS_NODE_LABELS={"control":{"role":"control"},"worker-gpu":{"role":"worker","gpu":"true"},"worker":{"role":"worker"}}\n'
} >>"$temporary/control.env"
common_env "$temporary/worker.env" worker-gpu 203.0.113.11

docker compose --project-directory "$script_dir/fleet" --env-file "$temporary/control.env" \
  -f "$script_dir/fleet/control.compose.yaml" -f "$script_dir/fleet/control.copilot.compose.yaml" \
  config --format json >"$temporary/control.json"
docker compose --project-directory "$script_dir/fleet" --env-file "$temporary/worker.env" \
  -f "$script_dir/fleet/worker.compose.yaml" config --format json >"$temporary/worker.json"

common_env "$temporary/ollama-control.env" control 203.0.113.10 ollama
{
  printf 'POSTGRES_PASSWORD=%064d\n' 0
  printf 'CANDACEOS_WEB_BIND_IP=203.0.113.10\n'
  printf 'CANDACEOS_OLLAMA_URL=http://203.0.113.11:11434\n'
  printf 'CANDACEOS_OLLAMA_MODEL=qwen3:8b\n'
  printf 'CANDACEOS_OLLAMA_MODEL_DIGEST=%064d\n' 1
  printf 'CANDACEOS_OLLAMA_CONTEXT_TOKENS=16384\n'
  printf 'CANDACEOS_OLLAMA_MAX_TOOL_CALLS=16\n'
  printf 'CANDACEOS_OLLAMA_TURN_TIMEOUT=10m\n'
  printf 'CANDACEOS_OLLAMA_IMAGE_DIGEST=sha256:e771d18fe56724f01a6f691a5773df544f36f565fb37c93f0ddc5957007b7766\n'
  printf 'CANDACEOS_NODE_LABELS={"control":{"role":"control"},"worker-gpu":{"role":"worker","gpu":"true"},"worker":{"role":"worker"}}\n'
} >>"$temporary/ollama-control.env"
common_env "$temporary/ollama-worker.env" worker-gpu 203.0.113.11 ollama
{
  printf 'CANDACEOS_OLLAMA_URL=http://203.0.113.11:11434\n'
  printf 'CANDACEOS_OLLAMA_MODEL=qwen3:8b\n'
  printf 'CANDACEOS_OLLAMA_CONTEXT_TOKENS=16384\n'
  printf 'CANDACEOS_OLLAMA_IMAGE=ollama/ollama:0.20.4@sha256:e771d18fe56724f01a6f691a5773df544f36f565fb37c93f0ddc5957007b7766\n'
  printf 'CANDACEOS_OLLAMA_IMAGE_DIGEST=sha256:e771d18fe56724f01a6f691a5773df544f36f565fb37c93f0ddc5957007b7766\n'
} >>"$temporary/ollama-worker.env"
docker compose --project-directory "$script_dir/fleet" --env-file "$temporary/ollama-control.env" \
  -f "$script_dir/fleet/control.compose.yaml" -f "$script_dir/fleet/control.ollama.compose.yaml" \
  config --format json >"$temporary/ollama-control.json"
docker compose --project-directory "$script_dir/fleet" --env-file "$temporary/ollama-worker.env" \
  -f "$script_dir/fleet/worker.compose.yaml" -f "$script_dir/fleet/worker.ollama.compose.yaml" \
  config --format json >"$temporary/ollama-worker.json"

python3 - "$temporary/control.json" "$temporary/worker.json" \
  "$temporary/ollama-control.json" "$temporary/ollama-worker.json" "$state" <<'PY'
import json
import sys

control = json.load(open(sys.argv[1], encoding="utf-8"))
worker = json.load(open(sys.argv[2], encoding="utf-8"))
ollama_control = json.load(open(sys.argv[3], encoding="utf-8"))
ollama_worker = json.load(open(sys.argv[4], encoding="utf-8"))
state = sys.argv[5]

assert set(control["services"]) == {"postgres", "warden", "git-source", "copilot", "core"}
assert set(worker["services"]) == {"warden", "agent"}
assert set(ollama_control["services"]) == {"postgres", "warden", "git-source", "core"}
assert set(ollama_worker["services"]) == {"warden", "agent", "ollama"}
assert all("build" not in service for service in control["services"].values())
assert all("build" not in service for service in worker["services"].values())
assert all("build" not in service for service in ollama_control["services"].values())
assert all("build" not in service for service in ollama_worker["services"].values())

core = control["services"]["core"]
copilot = control["services"]["copilot"]
assert core["environment"]["CANDACEOS_HARNESS_BACKEND"] == "copilot-cli"
assert "CANDACEOS_MODE" not in core["environment"]
assert core["environment"]["CANDACEOS_AGENT_URL"] == ""
assert core["environment"]["CANDACEOS_AGENT_PORT"] == "8094"
assert "CANDACEOS_WEB_TOKEN" not in core["environment"]
labels = json.loads(core["environment"]["CANDACEOS_NODE_LABELS"])
assert labels == {
    "control": {"role": "control"},
    "worker-gpu": {"role": "worker", "gpu": "true"},
    "worker": {"role": "worker"},
}
assert core["ports"][0]["host_ip"] == "203.0.113.10"
assert core["ports"][0]["published"] == "7780"
assert copilot["image"] == core["image"]
assert copilot["entrypoint"] == ["/opt/candaceos/copilot"]
copilot_mounts = {mount["target"]: mount for mount in copilot["volumes"]}
copilot_sha = "2ebb491db8bbbad58fb111a34b3f92798da44341976e5a6021bc13c7e57ae9e6"
assert copilot_mounts["/opt/candaceos/copilot"]["source"] == f"{state}/tools/copilot/1.0.80/{copilot_sha}/copilot"
assert copilot_mounts["/opt/candaceos/copilot"]["read_only"] is True
assert copilot["labels"]["io.candaceos.copilot.sha256"] == copilot_sha
assert set(copilot["networks"]) == {"copilot"}
assert all(key not in core["environment"] for key in ("COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"))

ollama_core = ollama_control["services"]["core"]
assert ollama_core["environment"]["CANDACEOS_HARNESS_BACKEND"] == "ollama"
assert ollama_core["environment"]["CANDACEOS_OLLAMA_URL"] == "http://203.0.113.11:11434"
assert ollama_core["environment"]["CANDACEOS_OLLAMA_MODEL"] == "qwen3:8b"
assert ollama_core["environment"]["CANDACEOS_OLLAMA_MODEL_DIGEST"] == "0" * 63 + "1"
assert ollama_core["environment"]["CANDACEOS_OLLAMA_CONTEXT_TOKENS"] == "16384"
assert ollama_core["environment"]["CANDACEOS_OLLAMA_MAX_TOOL_CALLS"] == "16"
assert ollama_core["environment"]["CANDACEOS_OLLAMA_TURN_TIMEOUT"] == "10m"
assert "copilot" not in ollama_core.get("depends_on", {})
assert all("COPILOT" not in key and key not in ("GH_TOKEN", "GITHUB_TOKEN") for key in ollama_core["environment"])

ollama = ollama_worker["services"]["ollama"]
assert ollama["image"] == "ollama/ollama:0.20.4@sha256:e771d18fe56724f01a6f691a5773df544f36f565fb37c93f0ddc5957007b7766"
assert ollama["runtime"] == "nvidia"
assert ollama["user"] == "1000:1000"
assert ollama["ports"][0]["host_ip"] == "203.0.113.11"
assert ollama["ports"][0]["published"] == "11434"
assert ollama["environment"]["HOME"] == "/var/lib/ollama"
assert ollama["environment"]["OLLAMA_MODELS"] == "/var/lib/ollama/models"
assert ollama["environment"]["OLLAMA_NO_CLOUD"] == "1"
assert ollama["environment"]["OLLAMA_FLASH_ATTENTION"] == "1"
assert ollama["environment"]["OLLAMA_KV_CACHE_TYPE"] == "q8_0"
assert ollama["environment"]["OLLAMA_NUM_PARALLEL"] == "1"
assert ollama["environment"]["OLLAMA_MAX_LOADED_MODELS"] == "1"
assert ollama["environment"]["OLLAMA_KEEP_ALIVE"] == "-1"
ollama_mounts = {mount["target"]: mount for mount in ollama["volumes"]}
assert ollama_mounts["/var/lib/ollama"]["source"] == f"{state}/runtime/ollama"

agent = worker["services"]["agent"]
environment = agent["environment"]
assert environment["CANDACEOS_AGENT_NODE_ID"] == "worker-gpu"
assert environment["CANDACEOS_AGENT_DRY_RUN"] == "false"
assert environment["CANDACEOS_AGENT_SOURCE_REMOTE"] == "git://203.0.113.10:9418/apps.git"
assert environment["CANDACEOS_AGENT_SOURCE_REPOSITORY"] == "/var/lib/candaceos-agent/source.git"
assert environment["CANDACEOS_AGENT_SOURCE_FETCH_TIMEOUT"] == "30s"
assert agent["ports"][0]["host_ip"] == "203.0.113.11"
mounts = {mount["target"]: mount for mount in agent["volumes"]}
assert mounts[f"{state}/apps"]["read_only"] is True
assert mounts["/var/lib/candaceos-agent"].get("read_only", False) is False

for model in (control, worker):
    warden = model["services"]["warden"]
    peers = warden["environment"]["WARDEN_PEERS"]
    assert peers == (
        "control=203.0.113.10:7717,"
        "worker-gpu=203.0.113.11:7717,"
        "worker=203.0.113.12:7717"
    )
PY

# A failed first-install candidate leaves no current symlink by design. A
# retry must atomically reseed apps/runtime from the new legacy snapshot rather
# than getting stuck on the old candidate worktree forever.
test_home="$temporary/home"
test_root="$test_home/state"
source_repo="$temporary/apps-source"
mkdir -p "$test_home" "$source_repo"
test_copilot_bin="$test_home/copilot"
printf '#!/bin/sh\nexit 0\n' >"$test_copilot_bin"
chmod 555 "$test_copilot_bin"
test_copilot_sha=$(sha256sum "$test_copilot_bin" | awk '{print $1}')
git -C "$source_repo" init -q -b main
git -C "$source_repo" config user.name 'Fleet Test'
git -C "$source_repo" config user.email 'fleet-test@localhost'
printf 'one\n' >"$source_repo/app.txt"
git -C "$source_repo" add app.txt
git -C "$source_repo" -c commit.gpgSign=false commit -q -m one

make_control_release() {
  local release=$1 marker=$2 stage archive incoming checksum
  stage="$temporary/stage-$release"
  mkdir -p "$stage/runtime/core" "$stage/runtime/copilot"
  printf 'services: {}\n' >"$stage/compose.yaml"
  printf 'node_id: control\n' >"$stage/warden.yaml"
  {
    printf 'CANDACEOS_HOST_WORKSPACE=%s/apps\n' "$test_root"
    printf 'CANDACEOS_COPILOT_BIN=%s\n' "$test_copilot_bin"
    printf 'CANDACEOS_COPILOT_SHA256=%s\n' "$test_copilot_sha"
  } >"$stage/.env"
  chmod 600 "$stage/.env"
  git -C "$source_repo" bundle create "$stage/apps.bundle" --all
  printf '%s\n' "$marker" >"$stage/runtime/copilot/session-state"
  tar -czf "$stage/runtime.tgz" -C "$stage/runtime" core copilot
  rm -rf "$stage/runtime"
  archive="$temporary/$release.tgz"
  tar -czf "$archive" -C "$stage" .
  incoming=$(HOME="$test_home" bash "$script_dir/fleet/node.sh" prepare-upload state "$release")
  install -m 600 "$archive" "$incoming/release.tgz"
  checksum=$(sha256sum "$archive" | awk '{print $1}')
  HOME="$test_home" bash "$script_dir/fleet/node.sh" install state "$release" control "$checksum"
}

release_one=20260819T010101Z-111111111111
release_two=20260819T010102Z-222222222222
head_one=$(git -C "$source_repo" rev-parse HEAD)
make_control_release "$release_one" first
[[ "$(git -C "$test_root/apps" rev-parse HEAD)" == "$head_one" ]] || fail "first app seed selected the wrong HEAD"
[[ "$(<"$test_root/runtime/copilot/session-state")" == first ]] || fail "first runtime seed was not restored"

printf 'two\n' >"$source_repo/app.txt"
git -C "$source_repo" add app.txt
git -C "$source_repo" -c commit.gpgSign=false commit -q -m two
head_two=$(git -C "$source_repo" rev-parse HEAD)
make_control_release "$release_two" second
[[ "$(git -C "$test_root/apps" rev-parse HEAD)" == "$head_two" ]] || fail "retry did not replace stale candidate apps"
[[ "$(<"$test_root/runtime/copilot/session-state")" == second ]] || fail "retry did not atomically replace stale candidate runtime"
[[ "$(find "$test_root/failed-apps" -mindepth 1 -maxdepth 1 -type d | wc -l)" -ge 1 ]] || fail "stale candidate apps were not preserved"

# Static guards for the first-install versus repeat-install split: reruns must
# source credentials and app history from the current control release, while
# only an empty control fleet may consult/quiesce the legacy AI prototype.
grep -q 'download_current_control_env' "$script_dir/fleet.sh" || fail "current credential reuse path is absent"
grep -q 'if \[\[ -n "$control_previous" \]\]' "$script_dir/fleet.sh" || fail "current control app source path is absent"
grep -q 'node_run "$ai_target" quiesce-legacy' "$script_dir/fleet.sh" || fail "initial legacy cutover path is absent"
grep -q 'candaceos-postgres:fleet-' "$script_dir/fleet.sh" || fail "PostgreSQL is not release-tagged before transfer"
if grep -Eq 'copilot_image|CANDACEOS_COPILOT_IMAGE|candaceos-copilot-cli|Dockerfile\.copilot' \
  "$script_dir/fleet.sh" "$script_dir/fleet/control.compose.yaml" "$script_dir/compose.yaml" \
  "$script_dir/install.sh" "$script_dir/README.md"; then
  fail "CandaceOS still builds or ships a Copilot CLI image"
fi
grep -q 'install_control_copilot' "$script_dir/fleet.sh" || fail "fleet does not install the control-host Copilot binary"
grep -q 'copilot_binary_sha256=2ebb491db8bbbad58fb111a34b3f92798da44341976e5a6021bc13c7e57ae9e6' \
  "$script_dir/install-copilot.sh" || fail "host Copilot binary checksum is not pinned"
grep -q 'CANDACEOS_COPILOT_SHA256' "$script_dir/fleet/node.sh" || fail "fleet release does not rehash its Copilot binary"
python3 - "$script_dir/fleet.sh" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
deploy = text[text.index("deploy() {"):text.index("receipt_value() {")]
if deploy.index("prepare_ollama_image") > deploy.index("capture_apps"):
    raise SystemExit("Ollama image pull happens after the legacy cutover starts")
if deploy.index('write_receipt staging') > deploy.index('capture_apps'):
    raise SystemExit("Ollama staging journal is not durable before cutover")
if deploy.index('package_role ai "$work_dir/ai.env" worker.compose.yaml "$ai_overlay"') > deploy.index("capture_apps"):
    raise SystemExit("Ollama candidate packaging happens after the legacy cutover starts")
if deploy.index('transfer_release "$ai_target" "$ai_root" ai') > deploy.index("capture_apps"):
    raise SystemExit("Ollama candidate transfer happens after the legacy cutover starts")
if deploy.index('activate-ollama') > deploy.index("capture_apps"):
    raise SystemExit("Ollama model pull/warm/verification happens after the legacy cutover starts")
if deploy.index('activate-ollama') > deploy.index('activate-control-db'):
    raise SystemExit("Ollama model activation does not complete before initial Core activation")
if deploy.index('bind_ollama_control_model') < deploy.index('activate-ollama'):
    raise SystemExit("control identity is bound before Ollama capability and digest verification")
if deploy.index('bind_ollama_control_model') > deploy.index('package_role control "$work_dir/control.env" control.compose.yaml "$control_overlay"'):
    raise SystemExit("control release is packaged before its verified Ollama model digest")
if 'package_role control "$work_dir/control.env" control.compose.yaml "$control_overlay"' not in deploy:
    raise SystemExit("control release does not package exactly one selected backend overlay")
if 'package_role ai "$work_dir/ai.env" worker.compose.yaml "$ai_overlay"' not in deploy:
    raise SystemExit("AI release does not package the Ollama-only overlay")
PY
grep -q 'warm_ollama_model "$url" "$model" "$context_tokens"' "$script_dir/fleet/node.sh" || \
  fail "Ollama activation does not warm the bounded model before verification"
grep -q 'up -d --no-build --pull never --remove-orphans' "$script_dir/fleet/node.sh" || \
  fail "backend switches do not remove deselected Copilot/Ollama services"
grep -Eq 'apt-get install .*make.*ripgrep' "$script_dir/Dockerfile.core" || fail "generic harness toolchain is incomplete"
grep -q 'AS runtime' "$script_dir/Dockerfile.core" || fail "Core image does not expose its shared runtime stage"
grep -q 'COPY --chown=0:0 --chmod=0555 candaceos-core' "$script_dir/Dockerfile.core.external" || \
  fail "external Core image does not install the supplied executable immutably"
if grep -q 'copilot-linux-x64' "$script_dir/Dockerfile.core"; then
  fail "Core image unexpectedly embeds Copilot CLI"
fi
bash "$script_dir/install-copilot.sh" --help >/dev/null
bash -s -- --help <"$script_dir/install-copilot.sh" >/dev/null
grep -Eq 'apk add --no-cache .*git-daemon' "$script_dir/Dockerfile.source" || fail "source image lacks the split Alpine git-daemon package"
grep -q 'COPY --chmod=0555 fleet/source.sh /usr/local/bin/candaceos-source' "$script_dir/Dockerfile.source" || \
  fail "source image launcher is not explicitly executable by its non-root user"
grep -q 'docker curl git gzip python3 realpath rsync sha256sum tar' "$script_dir/fleet/node.sh" || \
  fail "remote preflight does not require the rsync image transport"
grep -q '^  suspect_after: 15s$' "$script_dir/fleet/warden.yaml" || fail "fleet Warden suspect window regressed"
grep -q '^  dead_after: 45s$' "$script_dir/fleet/warden.yaml" || fail "fleet Warden dead window regressed"
grep -q '^  election_timeout_min: 10s$' "$script_dir/fleet/warden.yaml" || fail "fleet Warden election floor regressed"
grep -q '^  election_timeout_max: 15s$' "$script_dir/fleet/warden.yaml" || fail "fleet Warden election ceiling regressed"
grep -q '^  rpc_timeout: 3s$' "$script_dir/fleet/warden.yaml" || fail "fleet Warden RPC timeout regressed"

printf 'candaceos fleet tests passed\n'
