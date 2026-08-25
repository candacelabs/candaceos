#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
environment_projection="$script_dir/environment.generated.sh"
[[ -r "$environment_projection" ]] || { printf 'generated environment projection is missing\n' >&2; exit 1; }
# shellcheck source=environment.generated.sh
source "$environment_projection"
state_root=${!candaceos_env_state_root-}
state_root=${state_root:-$script_dir}
[[ "$state_root" == /* ]] || { printf '%s must be absolute\n' "$candaceos_env_state_root" >&2; exit 1; }
[[ -f "$state_root/.env" ]] || { printf 'CandaceOS is not installed.\n'; exit 0; }
printf -v "$candaceos_env_state_root" '%s' "$state_root"
export "$candaceos_env_state_root"

docker compose --project-directory "$script_dir" --env-file "$state_root/.env" \
  -f "$script_dir/compose.yaml" -f "$script_dir/compose.environment.generated.yaml" \
  --profile dry-run --profile live --profile copilot \
  --profile opencode \
  down --remove-orphans

printf 'Containers and networks removed. Database, receipts, app files, and .env were preserved.\n'
