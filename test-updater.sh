#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
image=candaceos-updater:runtime-test
test_root=$(mktemp -d)
cleanup() {
  docker image rm --force "$image" >/dev/null 2>&1 || true
  chmod -R u+w "$test_root" >/dev/null 2>&1 || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT

"$script_dir/test-install-validation.sh"

for script in \
  "$script_dir/bootstrap-updater.sh" \
  "$script_dir/record-bootstrap-revision.sh" \
  "$script_dir/updater-git-askpass.sh" \
  "$script_dir/updater-status.sh" \
  "$script_dir/updater.sh"; do
  bash -n "$script"
done

revision_a=0123456789abcdef0123456789abcdef01234567
revision_b=89abcdef0123456789abcdef0123456789abcdef
control_a="$test_root/control-a"
control_b="$test_root/control-b"

# A fresh adoption gets an exact rollback marker once. Re-running bootstrap
# is idempotent and a later source checkout cannot overwrite last-known-good.
"$script_dir/record-bootstrap-revision.sh" "$control_a" "$revision_a"
[[ "$(cat "$control_a/current")" == "$revision_a" ]]
[[ "$(cat "$control_a/current-origin")" == bootstrap ]]
[[ "$(wc -l <"$control_a/deployments.jsonl")" -eq 1 ]]
"$script_dir/record-bootstrap-revision.sh" "$control_a" "$revision_b"
[[ "$(cat "$control_a/current")" == "$revision_a" ]]
[[ "$(wc -l <"$control_a/deployments.jsonl")" -eq 1 ]]

# A retry after adoption completed but marker creation did not is repaired by
# the same operation and then remains stable.
mkdir -p "$control_b"
touch "$control_b/state-adopted"
"$script_dir/record-bootstrap-revision.sh" "$control_b" "$revision_b"
[[ "$(cat "$control_b/current")" == "$revision_b" ]]
[[ "$(cat "$control_b/current-origin")" == bootstrap ]]
[[ "$(wc -l <"$control_b/deployments.jsonl")" -eq 1 ]]
"$script_dir/record-bootstrap-revision.sh" "$control_b" "$revision_b"
[[ "$(wc -l <"$control_b/deployments.jsonl")" -eq 1 ]]

# These first-party packages are transitive build inputs for Core and the
# agent, so changing either must route the next main revision to deployment.
for dependency in go/pkg/telemetry go/proto/candace/telemetry; do
  grep -Fq -- "$dependency" "$script_dir/updater.sh"
done

grep -Fq 'current_revision=$(git -C "$deploy_root/repo" rev-parse HEAD)' \
  "$script_dir/bootstrap-updater.sh"

# Source the updater with its main loop disabled so verification can be tested
# against Docker's legacy and current health metadata shapes.
verify_root="$test_root/verify"
mkdir -p "$verify_root"
printf 'not-a-real-token' >"$verify_root/github-token"
export CANDACEOS_DEPLOY_ROOT="$verify_root"
export CANDACEOS_GITHUB_TOKEN_FILE="$verify_root/github-token"
export CANDACEOS_REPOSITORY=example-org/example-repo
# shellcheck source=updater.sh
source "$script_dir/updater.sh"

mock_agent_health=absent
mock_exec_status=0
mock_exec_failures=2
legacy_probe_count=0
legacy_sleep_count=0
curl() {
  return 0
}
sleep() {
  ((legacy_sleep_count += 1))
}
docker() {
  local args=" $* "
  if [[ "$1" == compose && "$args" == *" ps --services "* ]]; then
    printf '%s\n' postgres warden agent-dry-run copilot core
    return 0
  fi
  if [[ "$1" == compose && "$args" == *" ps -q agent-dry-run "* ]]; then
    printf 'agent-container-id\n'
    return 0
  fi
  if [[ "$1" == inspect ]]; then
    printf '%s\n' "$mock_agent_health"
    return 0
  fi
  if [[ "$1" == exec && "$2" == agent-container-id ]]; then
    ((legacy_probe_count += 1))
    [[ "$args" == *'CANDACEOS_AGENT_TOKEN'* ]]
    [[ "$args" == *'http://127.0.0.1:8094/healthz'* ]]
    [[ "$args" != *'not-a-real-token'* ]]
    ((legacy_probe_count > mock_exec_failures)) || return 1
    return "$mock_exec_status"
  fi
  return 1
}

verify_deployment "$script_dir"
[[ "$legacy_probe_count" -eq 3 ]]
[[ "$legacy_sleep_count" -eq 2 ]]

mock_exec_failures=30
legacy_probe_count=0
legacy_sleep_count=0
if verify_deployment "$script_dir" >"$test_root/legacy-unhealthy.out" 2>&1; then
  printf 'updater accepted an unhealthy legacy agent\n' >&2
  exit 1
fi
[[ "$legacy_probe_count" -eq 30 ]]
[[ "$legacy_sleep_count" -eq 29 ]]

mock_agent_health=unhealthy
legacy_probe_count=0
if verify_deployment "$script_dir" >"$test_root/unhealthy.out" 2>&1; then
  printf 'updater accepted an unhealthy current agent\n' >&2
  exit 1
fi
[[ "$legacy_probe_count" -eq 0 ]]
grep -Fq 'required service is not healthy: agent-dry-run (unhealthy)' \
  "$test_root/unhealthy.out"
unset -f curl docker sleep

# Exact rollback checkouts remove both ordinary and ignored residue left by a
# failed candidate before the previous revision is built.
repo_dir="$test_root/checkout-repo"
git init --quiet "$repo_dir"
git -C "$repo_dir" config user.email candaceos-test@example.invalid
git -C "$repo_dir" config user.name CandaceOS-Test
printf 'candidate-junk\n' >"$repo_dir/.gitignore"
printf 'rollback\n' >"$repo_dir/version"
git -C "$repo_dir" add .gitignore version
git -C "$repo_dir" commit --quiet -m rollback
checkout_revision_a=$(git -C "$repo_dir" rev-parse HEAD)
printf 'candidate\n' >"$repo_dir/version"
git -C "$repo_dir" commit --quiet -am candidate
printf 'untracked\n' >"$repo_dir/untracked-candidate-file"
printf 'ignored\n' >"$repo_dir/candidate-junk"
checkout_revision "$checkout_revision_a"
[[ ! -e "$repo_dir/untracked-candidate-file" ]]
[[ ! -e "$repo_dir/candidate-junk" ]]
[[ "$(cat "$repo_dir/version")" == rollback ]]
[[ -z "$(git -C "$repo_dir" status --porcelain --untracked-files=all)" ]]

# Failed candidates retain durable, per-revision retry state. Retries wait for
# an exponential delay capped at one hour; a new main revision starts fresh.
control_dir="$test_root/retry-control"
state_root="$test_root/retry-state"
retry_state_file="$control_dir/retry-state"
success_pending_file="$control_dir/success-pending"
status_outbox_dir="$control_dir/status-outbox"
receipt_file="$control_dir/deployments.jsonl"
mkdir -p "$control_dir" "$state_root" "$status_outbox_dir"
retry_candidate_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
retry_candidate_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
retry_candidate_c=cccccccccccccccccccccccccccccccccccccccc
retry_previous=dddddddddddddddddddddddddddddddddddddddd
retry_candidate_skip=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
retry_candidate_retry_write_fail=ffffffffffffffffffffffffffffffffffffffff
finalize_candidate_current=1111111111111111111111111111111111111111
finalize_candidate_last=2222222222222222222222222222222222222222
finalize_candidate_receipt=3333333333333333333333333333333333333333
finalize_candidate_status=4444444444444444444444444444444444444444
finalize_candidate_corrupt_previous=6666666666666666666666666666666666666666
finalize_candidate_outbox=7777777777777777777777777777777777777777
finalize_candidate_newer=8888888888888888888888888888888888888888
test_now=1000
retry_write_warnings=0
now_epoch() {
  printf '%s\n' "$test_now"
}
log() {
  if [[ "$*" == *'could not persist retry state'* ]]; then
    ((retry_write_warnings += 1))
  fi
  return 0
}
assert_retry_state() {
  local expected_candidate=$1 expected_count=$2 expected_next_at=$3
  local actual_candidate actual_count actual_next_at
  read -r actual_candidate actual_count actual_next_at <"$retry_state_file"
  [[ "$actual_candidate" == "$expected_candidate" ]]
  [[ "$actual_count" == "$expected_count" ]]
  [[ "$actual_next_at" == "$expected_next_at" ]]
}

schedule_retry "$retry_candidate_a"
assert_retry_state "$retry_candidate_a" 1 1060
retry_is_deferred "$retry_candidate_a"
test_now=1060
if retry_is_deferred "$retry_candidate_a"; then
  printf 'retry remained deferred after its deadline\n' >&2
  exit 1
else
  [[ "$?" -eq 1 ]]
fi
schedule_retry "$retry_candidate_a"
assert_retry_state "$retry_candidate_a" 2 1180

# Seed the sixth failure so the seventh and later delays can be checked without
# looping through wall-clock time.
write_state "$retry_state_file" "$retry_candidate_a 6 1"
test_now=2000
schedule_retry "$retry_candidate_a"
assert_retry_state "$retry_candidate_a" 7 5600
test_now=5600
schedule_retry "$retry_candidate_a"
assert_retry_state "$retry_candidate_a" 8 9200
clear_retry_state

mock_candidate=$retry_candidate_a
mock_candidate_status=1
mock_has_contract=1
candidate_attempts=0
success_receipts=0
success_statuses=0
success_status_attempts=0
success_receipt_failures=0
success_status_failures=0
skipped_receipts=0
affects_calls=0
fetch_main() {
  printf '%s\n' "$mock_candidate"
}
has_deploy_contract() {
  [[ "$mock_has_contract" -eq 1 ]]
}
affects_candaceos() {
  ((affects_calls += 1))
  return 0
}
post_status() {
  if [[ "$2" == success ]]; then
    ((success_status_attempts += 1))
    if ((success_status_failures > 0)); then
      success_status_failures=$((success_status_failures - 1))
      return 1
    fi
    ((success_statuses += 1))
  fi
  return 0
}
record_receipt() {
  if [[ "$3" == success ]]; then
    if ((success_receipt_failures > 0)); then
      success_receipt_failures=$((success_receipt_failures - 1))
      return 1
    fi
    ((success_receipts += 1))
  fi
  if [[ "$3" == skipped ]]; then
    ((skipped_receipts += 1))
  fi
  printf '{"candidate":"%s","previous":"%s","outcome":"%s","rollback":"%s"}\n' \
    "$1" "$2" "$3" "$4" >>"$receipt_file"
  return 0
}
checkout_revision() {
  return 0
}
deploy_revision() {
  if [[ "$1" == "$mock_candidate" ]]; then
    ((candidate_attempts += 1))
    return "$mock_candidate_status"
  fi
  return 0
}

write_state "$control_dir/current" "$retry_previous"
write_state "$control_dir/current-origin" main
write_state "$control_dir/last-observed" "$retry_previous"
test_now=1000
if reconcile_once; then
  printf 'failed candidate was reported as reconciled\n' >&2
  exit 1
fi
assert_retry_state "$retry_candidate_a" 1 1060
[[ "$(read_state "$control_dir/last-observed")" == "$retry_previous" ]]
[[ "$candidate_attempts" -eq 1 ]]

test_now=1030
reconcile_once
[[ "$candidate_attempts" -eq 1 ]]
assert_retry_state "$retry_candidate_a" 1 1060

test_now=1060
if reconcile_once; then
  printf 'second failed candidate attempt was reported as reconciled\n' >&2
  exit 1
fi
[[ "$candidate_attempts" -eq 2 ]]
assert_retry_state "$retry_candidate_a" 2 1180

# Superseding main resets the attempt count instead of inheriting the old
# candidate's backoff.
mock_candidate=$retry_candidate_b
test_now=1061
if reconcile_once; then
  printf 'failed superseding candidate was reported as reconciled\n' >&2
  exit 1
fi
[[ "$candidate_attempts" -eq 3 ]]
assert_retry_state "$retry_candidate_b" 1 1121
[[ "$(read_state "$control_dir/last-observed")" == "$retry_previous" ]]

# A due retry that succeeds becomes last-observed and clears retry state.
mock_candidate_status=0
test_now=1121
reconcile_once
[[ "$candidate_attempts" -eq 4 ]]
[[ "$(read_state "$control_dir/current")" == "$retry_candidate_b" ]]
[[ "$(read_state "$control_dir/last-observed")" == "$retry_candidate_b" ]]
[[ ! -e "$retry_state_file" ]]
[[ "$success_receipts" -eq 1 ]]
[[ "$success_statuses" -eq 1 ]]

# Every transient local finalization failure retains the durable proof that
# deploy_revision already verified the exact candidate. The next poll finishes
# without a second deploy or an irrelevant-change misclassification.
fail_write_path=
fail_write_count=0
mv() {
  local target=${!#}
  if [[ -n "$fail_write_path" && "$target" == "$fail_write_path" ]] &&
    ((fail_write_count > 0)); then
    fail_write_count=$((fail_write_count - 1))
    return 1
  fi
  command mv "$@"
}

for finalization_case in \
  "$retry_candidate_c:origin" \
  "$finalize_candidate_current:current" \
  "$finalize_candidate_last:last" \
  "$finalize_candidate_receipt:receipt" \
  "$finalize_candidate_outbox:outbox"; do
  finalization_candidate=${finalization_case%%:*}
  finalization_failure=${finalization_case#*:}
  previous_observed=$(read_state "$control_dir/last-observed")
  attempts_before=$candidate_attempts
  affects_before=$affects_calls
  receipts_before=$success_receipts
  statuses_before=$success_statuses
  status_attempts_before=$success_status_attempts
  skips_before=$skipped_receipts
  mock_candidate=$finalization_candidate
  mock_candidate_status=0
  mock_has_contract=1
  fail_write_path=
  fail_write_count=0
  success_receipt_failures=0
  success_status_failures=0
  case "$finalization_failure" in
    origin)
      fail_write_path="$control_dir/current-origin"
      fail_write_count=1
      ;;
    current)
      fail_write_path="$control_dir/current"
      fail_write_count=1
      ;;
    last)
      fail_write_path="$control_dir/last-observed"
      fail_write_count=1
      ;;
    receipt)
      success_receipt_failures=1
      ;;
    outbox)
      fail_write_path="$status_outbox_dir/$finalization_candidate"
      fail_write_count=1
      ;;
  esac

  if reconcile_once; then
    printf '%s finalization failure was reported as reconciled\n' \
      "$finalization_failure" >&2
    exit 1
  fi
  [[ -f "$success_pending_file" ]]
  [[ "$(read_state "$control_dir/last-observed")" == "$previous_observed" ]]
  [[ "$candidate_attempts" -eq $((attempts_before + 1)) ]]
  [[ "$affects_calls" -eq $((affects_before + 1)) ]]

  fail_write_path=
  fail_write_count=0
  reconcile_once
  [[ ! -e "$success_pending_file" ]]
  [[ "$(read_state "$control_dir/current")" == "$finalization_candidate" ]]
  [[ "$(read_state "$control_dir/current-origin")" == main ]]
  [[ "$(read_state "$control_dir/last-observed")" == "$finalization_candidate" ]]
  [[ "$candidate_attempts" -eq $((attempts_before + 1)) ]]
  [[ "$affects_calls" -eq $((affects_before + 1)) ]]
  [[ "$success_receipts" -eq $((receipts_before + 1)) ]]
  [[ "$skipped_receipts" -eq "$skips_before" ]]
  [[ "$success_statuses" -eq $((statuses_before + 1)) ]]
  [[ "$success_status_attempts" -eq $((status_attempts_before + 1)) ]]
done
unset -f mv

# A remote status outage leaves durable outbox entries but does not block local
# success or a newer main revision. A later poll retries both without another
# deployment.
attempts_before=$candidate_attempts
affects_before=$affects_calls
receipts_before=$success_receipts
statuses_before=$success_statuses
status_attempts_before=$success_status_attempts
skips_before=$skipped_receipts
mock_candidate=$finalize_candidate_status
mock_candidate_status=0
success_status_failures=100
reconcile_once
[[ ! -e "$success_pending_file" ]]
[[ -f "$status_outbox_dir/$finalize_candidate_status" ]]
[[ "$(read_state "$control_dir/last-observed")" == "$finalize_candidate_status" ]]
[[ "$candidate_attempts" -eq $((attempts_before + 1)) ]]
[[ "$affects_calls" -eq $((affects_before + 1)) ]]
[[ "$success_receipts" -eq $((receipts_before + 1)) ]]
[[ "$success_statuses" -eq "$statuses_before" ]]
[[ "$success_status_attempts" -eq $((status_attempts_before + 1)) ]]
[[ "$skipped_receipts" -eq "$skips_before" ]]

mock_candidate=$finalize_candidate_newer
reconcile_once
[[ "$(read_state "$control_dir/current")" == "$finalize_candidate_newer" ]]
[[ "$(read_state "$control_dir/last-observed")" == "$finalize_candidate_newer" ]]
[[ "$candidate_attempts" -eq $((attempts_before + 2)) ]]
[[ "$affects_calls" -eq $((affects_before + 2)) ]]
[[ "$success_receipts" -eq $((receipts_before + 2)) ]]
[[ "$success_statuses" -eq "$statuses_before" ]]
[[ "$success_status_attempts" -eq $((status_attempts_before + 4)) ]]
[[ -f "$status_outbox_dir/$finalize_candidate_status" ]]
[[ -f "$status_outbox_dir/$finalize_candidate_newer" ]]

success_status_failures=0
reconcile_once
[[ ! -e "$status_outbox_dir/$finalize_candidate_status" ]]
[[ ! -e "$status_outbox_dir/$finalize_candidate_newer" ]]
[[ "$candidate_attempts" -eq $((attempts_before + 2)) ]]
[[ "$affects_calls" -eq $((affects_before + 2)) ]]
[[ "$success_receipts" -eq $((receipts_before + 2)) ]]
[[ "$success_statuses" -eq $((statuses_before + 2)) ]]
[[ "$success_status_attempts" -eq $((status_attempts_before + 6)) ]]
[[ "$skipped_receipts" -eq "$skips_before" ]]

# Corrupt legacy current state is normalized to no previous revision instead
# of creating a success marker that can never be parsed on the next poll.
write_state "$control_dir/current" corrupt
mock_candidate=$finalize_candidate_corrupt_previous
mock_candidate_status=0
reconcile_once
[[ "$(read_state "$control_dir/current")" == "$finalize_candidate_corrupt_previous" ]]
[[ "$(read_state "$control_dir/last-observed")" == "$finalize_candidate_corrupt_previous" ]]
[[ ! -e "$success_pending_file" ]]
grep -Fq \
  "\"candidate\":\"$finalize_candidate_corrupt_previous\",\"previous\":\"\",\"outcome\":\"success\"" \
  "$receipt_file"

# Contract-absent revisions are intentional skips and are also last-observed.
mock_candidate=$retry_candidate_skip
mock_has_contract=0
test_now=1122
reconcile_once
[[ "$(read_state "$control_dir/last-observed")" == "$retry_candidate_skip" ]]
[[ ! -e "$retry_state_file" ]]

# A retry-state write failure is loud and never marks the failed candidate as
# observed, so an operator-visible storage error cannot silently suppress it.
mock_candidate=$retry_candidate_retry_write_fail
mock_candidate_status=1
mock_has_contract=1
fail_write_path=$retry_state_file
mv() {
  local target=${!#}
  if [[ "$target" == "$fail_write_path" ]]; then
    return 1
  fi
  command mv "$@"
}
if reconcile_once; then
  printf 'failed candidate with no retry state was reported as reconciled\n' >&2
  exit 1
fi
unset -f mv
[[ "$retry_write_warnings" -eq 1 ]]
[[ "$(read_state "$control_dir/last-observed")" == "$retry_candidate_skip" ]]
[[ ! -e "$retry_state_file" ]]

# Recreating the updater is what makes an atomic host credential rotation
# replace the bind-mounted token inode inside the long-running container.
tr '\n' ' ' <"$script_dir/bootstrap-updater.sh" |
  grep -Eq 'up -d --build --force-recreate[[:space:]]+\\?[[:space:]]*--wait'

docker build --tag "$image" --file "$script_dir/Dockerfile.updater" "$script_dir"

mkdir -p "$test_root/control" "$test_root/secrets" "$test_root/state"
printf 'not-a-real-token' >"$test_root/secrets/github-token"
touch "$test_root/control/heartbeat"
chmod -R a+rX "$test_root"
chmod -R a-w "$test_root"
heartbeat_before=$(stat -c '%y:%s:%a:%i' "$test_root/control/heartbeat")

runtime=(docker run --rm --user 1000:1000
  --env "CANDACEOS_DEPLOY_ROOT=$test_root"
  --env CANDACEOS_GITHUB_TOKEN_FILE=/run/secrets/github-token
  --env CANDACEOS_REPOSITORY=example-org/example-repo
  --volume "$test_root:$test_root"
  --volume "$test_root/secrets/github-token:/run/secrets/github-token:ro"
  "$image")

"${runtime[@]}" --health
[[ ! -e "$test_root/control/status-outbox" ]]
[[ "$(stat -c '%y:%s:%a:%i' "$test_root/control/heartbeat")" == "$heartbeat_before" ]]
docker run --rm --user 1000:1000 \
  --entrypoint /usr/local/bin/candaceos-git-askpass \
  --env CANDACEOS_GITHUB_TOKEN_FILE=/run/secrets/github-token \
  --volume "$test_root/secrets/github-token:/run/secrets/github-token:ro" \
  "$image" 'Password for https://github.com:' >/dev/null

printf 'CandaceOS updater runtime tests passed.\n'
