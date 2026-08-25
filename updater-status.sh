#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
deploy_root=${CANDACEOS_DEPLOY_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/candaceos-deployer}
[[ "$deploy_root" == /* ]] || { printf 'CANDACEOS_DEPLOY_ROOT must be absolute\n' >&2; exit 1; }

printf 'Active revision: %s\n' "$(cat "$deploy_root/control/current" 2>/dev/null || printf none)"
printf 'Source: %s\n' "$(cat "$deploy_root/control/current-origin" 2>/dev/null || printf none)"
printf 'Last observed main: %s\n' "$(cat "$deploy_root/control/last-observed" 2>/dev/null || printf none)"
printf '\nRecent deployment receipts:\n'
tail -n 10 "$deploy_root/control/deployments.jsonl" 2>/dev/null || printf '(none)\n'
printf '\nUpdater container:\n'
docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  candaceos-updater 2>/dev/null || printf 'not installed\n'
printf '\nRecent updater log:\n'
docker logs --tail 40 candaceos-updater 2>&1 || true

printf '\nCandaceOS containers:\n'
docker ps --filter label=com.docker.compose.project=candaceos \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>&1 || true
