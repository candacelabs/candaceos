#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image=candaceos-opencode:1.18.21
container="candaceos-opencode-sdk-contract-$$"
command -v openssl >/dev/null || { printf 'openssl is required\n' >&2; exit 1; }
# A fresh disposable credential per run: nothing reusable is committed, and
# bare --env names keep it off every argument vector.
export OPENCODE_SERVER_USERNAME=opencode
export OPENCODE_SERVER_PASSWORD
OPENCODE_SERVER_PASSWORD=$(openssl rand -hex 32)
export CANDACEOS_OPENCODE_CONTRACT_USERNAME="$OPENCODE_SERVER_USERNAME"
export CANDACEOS_OPENCODE_CONTRACT_PASSWORD="$OPENCODE_SERVER_PASSWORD"
go_image=golang:1.26.5-bookworm@sha256:6c5605ab3a9a9fb3c4eafe5b3d63cdbf3881caf113262b67862547b54a9db599

cleanup() {
  docker stop "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build --tag "$image" --file "$repo_root/candaceos/Dockerfile.opencode" "$repo_root/candaceos"
docker run --detach --rm \
  --name "$container" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,nosuid,nodev,noexec \
  --tmpfs /workspace:rw,nosuid,nodev,uid=65532,gid=65532 \
  --tmpfs /var/lib/opencode:rw,nosuid,nodev,uid=65532,gid=65532 \
  --env OPENCODE_SERVER_USERNAME \
  --env OPENCODE_SERVER_PASSWORD \
  --publish 127.0.0.1::4096 \
  "$image" >/dev/null

port=$(docker port "$container" 4096/tcp | sed -n 's/^127\.0\.0\.1://p')
test -n "$port"
endpoint="http://127.0.0.1:$port"
health_check() {
  printf 'user = "%s:%s"\n' \
    "$OPENCODE_SERVER_USERNAME" "$OPENCODE_SERVER_PASSWORD" | \
    curl --config - --fail --silent --show-error "$endpoint/global/health" >/dev/null
}
for _ in $(seq 1 30); do
  if health_check 2>/dev/null; then
    break
  fi
  sleep 1
done
health_check

set +e
contract_output=$(docker run --rm --network host \
  --env CANDACEOS_OPENCODE_CONTRACT_URL="$endpoint" \
  --env CANDACEOS_OPENCODE_CONTRACT_USERNAME \
  --env CANDACEOS_OPENCODE_CONTRACT_PASSWORD \
  --volume "$repo_root/go:/src" \
  --workdir /src \
  "$go_image" \
  go test ./pkg/candaceos/harness/opencode \
    -count=1 -v -ginkgo.no-color -ginkgo.focus='OpenCode SDK live contract' 2>&1)
contract_status=$?
set -e
printf '%s\n' "$contract_output"
test "$contract_status" -eq 0
grep -Eq 'Will run 1 of [0-9]+ specs' <<<"$contract_output"
grep -Eq 'Ran 1 of [0-9]+ Specs' <<<"$contract_output"
