# Code generated from Candacefile by tools/candace_environment.py; DO NOT EDIT.
# Regenerate with: python3 tools/candace_environment.py write

readonly candaceos_env_postgres_database=POSTGRES_DB
readonly candaceos_default_postgres_database=candaceos
readonly candaceos_env_postgres_user=POSTGRES_USER
readonly candaceos_default_postgres_user=candaceos
readonly candaceos_env_postgres_password=POSTGRES_PASSWORD
readonly candaceos_env_state_root=CANDACEOS_STATE_ROOT
readonly candaceos_env_uid=CANDACEOS_UID
readonly candaceos_env_gid=CANDACEOS_GID
readonly candaceos_env_host_workspace=CANDACEOS_HOST_WORKSPACE
readonly candaceos_env_agent_token=CANDACEOS_AGENT_TOKEN
readonly candaceos_env_copilot_connection_token=CANDACEOS_COPILOT_CONNECTION_TOKEN
readonly candaceos_env_opencode_password=CANDACEOS_OPENCODE_PASSWORD
readonly candaceos_env_copilot_github_token=COPILOT_GITHUB_TOKEN
readonly candaceos_default_copilot_github_token=''
readonly candaceos_env_opencode_model=CANDACEOS_OPENCODE_MODEL
readonly candaceos_default_opencode_model=''
readonly candaceos_env_agent_revision_max_entries=CANDACEOS_AGENT_REVISION_MAX_ENTRIES
readonly candaceos_default_agent_revision_max_entries=128
readonly candaceos_env_agent_revision_max_bytes=CANDACEOS_AGENT_REVISION_MAX_BYTES
readonly candaceos_default_agent_revision_max_bytes=4294967296
readonly candaceos_env_copilot_bin=CANDACEOS_COPILOT_BIN
readonly candaceos_env_copilot_sha256=CANDACEOS_COPILOT_SHA256
readonly candaceos_env_gh_token=GH_TOKEN
readonly candaceos_env_github_token=GITHUB_TOKEN
readonly candaceos_env_live_confirm=CANDACEOS_LIVE_CONFIRM
readonly candaceos_env_legacy_mode=CANDACEOS_MODE
readonly candaceos_env_openai_api_key=OPENAI_API_KEY
readonly candaceos_env_anthropic_api_key=ANTHROPIC_API_KEY
readonly candaceos_env_openrouter_api_key=OPENROUTER_API_KEY
readonly candaceos_env_agent_bind=CANDACEOS_AGENT_BIND
readonly candaceos_default_agent_bind=0.0.0.0:8094
readonly candaceos_env_agent_node_id=CANDACEOS_AGENT_NODE_ID
readonly candaceos_default_agent_node_id=candaceos-demo
readonly candaceos_env_agent_state_file=CANDACEOS_AGENT_STATE_FILE
readonly candaceos_default_agent_state_file=/var/lib/candaceos-agent/state.json
readonly candaceos_env_agent_revision_root=CANDACEOS_AGENT_REVISION_ROOT
readonly candaceos_default_agent_revision_root=/var/lib/candaceos-agent/revisions
readonly candaceos_env_docker_config=DOCKER_CONFIG
readonly candaceos_default_docker_config=/tmp/docker-config
readonly candaceos_env_agent_dry_workspace=CANDACEOS_AGENT_DRY_WORKSPACE
readonly candaceos_default_agent_dry_workspace=/workspace
readonly candaceos_env_agent_live_workspace=CANDACEOS_AGENT_LIVE_WORKSPACE
readonly candaceos_default_agent_live_workspace=/workspace
readonly candaceos_env_agent_dry_run_enabled=CANDACEOS_AGENT_DRY_RUN_ENABLED
readonly candaceos_default_agent_dry_run_enabled=true
readonly candaceos_env_agent_dry_run_disabled=CANDACEOS_AGENT_DRY_RUN_DISABLED
readonly candaceos_default_agent_dry_run_disabled=false
readonly candaceos_env_warden_config=WARDEN_CONFIG
readonly candaceos_default_warden_config=/etc/warden/warden.yaml
readonly candaceos_env_warden_log_format=WARDEN_LOG_FORMAT
readonly candaceos_default_warden_log_format=console
readonly candaceos_env_copilot_home=CANDACEOS_COPILOT_HOME
readonly candaceos_default_copilot_home=/var/lib/copilot
readonly candaceos_env_harness_backend=CANDACEOS_HARNESS_BACKEND
readonly candaceos_default_harness_backend=copilot-cli
readonly candaceos_env_core_bind=CANDACEOS_BIND
readonly candaceos_default_core_bind=0.0.0.0:7780
readonly candaceos_env_core_data_dir=CANDACEOS_DATA_DIR
readonly candaceos_default_core_data_dir=/var/lib/candaceos
readonly candaceos_env_core_workspace=CANDACEOS_WORKSPACE
readonly candaceos_default_core_workspace=/workspace
readonly candaceos_env_core_database_url=CANDACEOS_DATABASE_URL
readonly candaceos_default_core_database_url=''
readonly candaceos_env_core_warden_url=CANDACEOS_WARDEN_URL
readonly candaceos_default_core_warden_url=http://127.0.0.1:7717
readonly candaceos_env_core_agent_url=CANDACEOS_AGENT_URL
readonly candaceos_default_core_agent_url=''
readonly candaceos_env_core_agent_port=CANDACEOS_AGENT_PORT
readonly candaceos_default_core_agent_port=8094
readonly candaceos_env_core_node_labels=CANDACEOS_NODE_LABELS
readonly candaceos_default_core_node_labels='{}'
readonly candaceos_env_core_approval_timeout=CANDACEOS_APPROVAL_TIMEOUT
readonly candaceos_default_core_approval_timeout=15m
readonly candaceos_env_core_fleet_poll_interval=CANDACEOS_FLEET_POLL_INTERVAL
readonly candaceos_default_core_fleet_poll_interval=2s
readonly candaceos_env_copilot_cli=CANDACEOS_COPILOT_CLI
readonly candaceos_default_copilot_cli=/usr/local/bin/copilot
readonly candaceos_env_copilot_url=CANDACEOS_COPILOT_URL
readonly candaceos_default_copilot_url=''
readonly candaceos_env_copilot_model=CANDACEOS_COPILOT_MODEL
readonly candaceos_default_copilot_model=gpt-5.4
readonly candaceos_env_ollama_url=CANDACEOS_OLLAMA_URL
readonly candaceos_default_ollama_url=''
readonly candaceos_env_ollama_model=CANDACEOS_OLLAMA_MODEL
readonly candaceos_default_ollama_model=''
readonly candaceos_env_ollama_model_digest=CANDACEOS_OLLAMA_MODEL_DIGEST
readonly candaceos_default_ollama_model_digest=''
readonly candaceos_env_ollama_context_tokens=CANDACEOS_OLLAMA_CONTEXT_TOKENS
readonly candaceos_default_ollama_context_tokens=16384
readonly candaceos_env_ollama_max_tool_calls=CANDACEOS_OLLAMA_MAX_TOOL_CALLS
readonly candaceos_default_ollama_max_tool_calls=16
readonly candaceos_env_ollama_turn_timeout=CANDACEOS_OLLAMA_TURN_TIMEOUT
readonly candaceos_default_ollama_turn_timeout=10m
readonly candaceos_env_opencode_url=CANDACEOS_OPENCODE_URL
readonly candaceos_default_opencode_url=http://127.0.0.1:4096
readonly candaceos_env_opencode_username=CANDACEOS_OPENCODE_USERNAME
readonly candaceos_default_opencode_username=opencode
readonly candaceos_env_opencode_session_id=CANDACEOS_OPENCODE_SESSION_ID
readonly candaceos_default_opencode_session_id=''
readonly candaceos_env_opencode_request_timeout=CANDACEOS_OPENCODE_REQUEST_TIMEOUT
readonly candaceos_default_opencode_request_timeout=10s
readonly candaceos_env_opencode_poll_interval=CANDACEOS_OPENCODE_POLL_INTERVAL
readonly candaceos_default_opencode_poll_interval=1s
readonly candaceos_env_opencode_queue_capacity=CANDACEOS_OPENCODE_QUEUE_CAPACITY
readonly candaceos_default_opencode_queue_capacity=32
readonly candaceos_env_live_confirm_phrase=CANDACEOS_LIVE_CONFIRM_PHRASE
readonly candaceos_default_live_confirm_phrase=I_UNDERSTAND_DOCKER_SOCKET_IS_ROOT
readonly candaceos_profile_local=local
readonly candaceos_profile_demo=demo
readonly candaceos_profile_copilot=copilot
readonly candaceos_profile_opencode=opencode

declare -gra candaceos_environment_state_symbols=(
  postgres_password
  state_root
  uid
  gid
  host_workspace
  agent_token
  copilot_connection_token
  opencode_password
  copilot_github_token
  opencode_model
  agent_revision_max_entries
  agent_revision_max_bytes
)
declare -grA candaceos_environment_names=(
  [postgres_database]=POSTGRES_DB
  [postgres_user]=POSTGRES_USER
  [postgres_password]=POSTGRES_PASSWORD
  [state_root]=CANDACEOS_STATE_ROOT
  [uid]=CANDACEOS_UID
  [gid]=CANDACEOS_GID
  [host_workspace]=CANDACEOS_HOST_WORKSPACE
  [agent_token]=CANDACEOS_AGENT_TOKEN
  [copilot_connection_token]=CANDACEOS_COPILOT_CONNECTION_TOKEN
  [opencode_password]=CANDACEOS_OPENCODE_PASSWORD
  [copilot_github_token]=COPILOT_GITHUB_TOKEN
  [opencode_model]=CANDACEOS_OPENCODE_MODEL
  [agent_revision_max_entries]=CANDACEOS_AGENT_REVISION_MAX_ENTRIES
  [agent_revision_max_bytes]=CANDACEOS_AGENT_REVISION_MAX_BYTES
  [copilot_bin]=CANDACEOS_COPILOT_BIN
  [copilot_sha256]=CANDACEOS_COPILOT_SHA256
  [gh_token]=GH_TOKEN
  [github_token]=GITHUB_TOKEN
  [live_confirm]=CANDACEOS_LIVE_CONFIRM
  [legacy_mode]=CANDACEOS_MODE
  [openai_api_key]=OPENAI_API_KEY
  [anthropic_api_key]=ANTHROPIC_API_KEY
  [openrouter_api_key]=OPENROUTER_API_KEY
  [agent_bind]=CANDACEOS_AGENT_BIND
  [agent_node_id]=CANDACEOS_AGENT_NODE_ID
  [agent_state_file]=CANDACEOS_AGENT_STATE_FILE
  [agent_revision_root]=CANDACEOS_AGENT_REVISION_ROOT
  [docker_config]=DOCKER_CONFIG
  [agent_dry_workspace]=CANDACEOS_AGENT_DRY_WORKSPACE
  [agent_live_workspace]=CANDACEOS_AGENT_LIVE_WORKSPACE
  [agent_dry_run_enabled]=CANDACEOS_AGENT_DRY_RUN_ENABLED
  [agent_dry_run_disabled]=CANDACEOS_AGENT_DRY_RUN_DISABLED
  [warden_config]=WARDEN_CONFIG
  [warden_log_format]=WARDEN_LOG_FORMAT
  [copilot_home]=CANDACEOS_COPILOT_HOME
  [harness_backend]=CANDACEOS_HARNESS_BACKEND
  [core_bind]=CANDACEOS_BIND
  [core_data_dir]=CANDACEOS_DATA_DIR
  [core_workspace]=CANDACEOS_WORKSPACE
  [core_database_url]=CANDACEOS_DATABASE_URL
  [core_warden_url]=CANDACEOS_WARDEN_URL
  [core_agent_url]=CANDACEOS_AGENT_URL
  [core_agent_port]=CANDACEOS_AGENT_PORT
  [core_node_labels]=CANDACEOS_NODE_LABELS
  [core_approval_timeout]=CANDACEOS_APPROVAL_TIMEOUT
  [core_fleet_poll_interval]=CANDACEOS_FLEET_POLL_INTERVAL
  [copilot_cli]=CANDACEOS_COPILOT_CLI
  [copilot_url]=CANDACEOS_COPILOT_URL
  [copilot_model]=CANDACEOS_COPILOT_MODEL
  [ollama_url]=CANDACEOS_OLLAMA_URL
  [ollama_model]=CANDACEOS_OLLAMA_MODEL
  [ollama_model_digest]=CANDACEOS_OLLAMA_MODEL_DIGEST
  [ollama_context_tokens]=CANDACEOS_OLLAMA_CONTEXT_TOKENS
  [ollama_max_tool_calls]=CANDACEOS_OLLAMA_MAX_TOOL_CALLS
  [ollama_turn_timeout]=CANDACEOS_OLLAMA_TURN_TIMEOUT
  [opencode_url]=CANDACEOS_OPENCODE_URL
  [opencode_username]=CANDACEOS_OPENCODE_USERNAME
  [opencode_session_id]=CANDACEOS_OPENCODE_SESSION_ID
  [opencode_request_timeout]=CANDACEOS_OPENCODE_REQUEST_TIMEOUT
  [opencode_poll_interval]=CANDACEOS_OPENCODE_POLL_INTERVAL
  [opencode_queue_capacity]=CANDACEOS_OPENCODE_QUEUE_CAPACITY
  [live_confirm_phrase]=CANDACEOS_LIVE_CONFIRM_PHRASE
)
declare -grA candaceos_environment_lifecycles=(
  [postgres_password]=secret
  [state_root]=host
  [uid]=host
  [gid]=host
  [host_workspace]=host
  [agent_token]=secret
  [copilot_connection_token]=secret
  [opencode_password]=secret
  [copilot_github_token]=operator
  [opencode_model]=operator
  [agent_revision_max_entries]=operator
  [agent_revision_max_bytes]=operator
)
declare -grA candaceos_environment_values=(
  [postgres_password]=random_hex_32
  [state_root]=state_root
  [uid]=uid
  [gid]=gid
  [host_workspace]=apps_dir
  [agent_token]=random_hex_32
  [copilot_connection_token]=random_hex_32
  [opencode_password]=random_hex_32
  [copilot_github_token]=''
  [opencode_model]=''
  [agent_revision_max_entries]=128
  [agent_revision_max_bytes]=4294967296
)
declare -grA candaceos_environment_required=(
  [postgres_password]=true
  [state_root]=true
  [uid]=true
  [gid]=true
  [host_workspace]=true
  [agent_token]=true
  [copilot_connection_token]=true
  [opencode_password]=true
  [copilot_github_token]=false
  [opencode_model]=false
  [agent_revision_max_entries]=true
  [agent_revision_max_bytes]=true
)
declare -grA candaceos_environment_state_names=(
  [POSTGRES_PASSWORD]=postgres_password
  [CANDACEOS_STATE_ROOT]=state_root
  [CANDACEOS_UID]=uid
  [CANDACEOS_GID]=gid
  [CANDACEOS_HOST_WORKSPACE]=host_workspace
  [CANDACEOS_AGENT_TOKEN]=agent_token
  [CANDACEOS_COPILOT_CONNECTION_TOKEN]=copilot_connection_token
  [CANDACEOS_OPENCODE_PASSWORD]=opencode_password
  [COPILOT_GITHUB_TOKEN]=copilot_github_token
  [CANDACEOS_OPENCODE_MODEL]=opencode_model
  [CANDACEOS_AGENT_REVISION_MAX_ENTRIES]=agent_revision_max_entries
  [CANDACEOS_AGENT_REVISION_MAX_BYTES]=agent_revision_max_bytes
)

candaceos_environment_reconcile() {
  local env_file=$1 state_root=$2 apps_dir=$3
  local line key symbol name lifecycle generator required value incoming temporary
  local -A existing=() seen=()

  [[ ! -L "$env_file" ]] || { printf 'environment file must not be a symbolic link: %s\n' "$env_file" >&2; return 1; }
  if [[ -f "$env_file" ]]; then
    [[ "$(stat -c '%a' "$env_file")" == 600 ]] || { printf 'environment file must have mode 600: %s\n' "$env_file" >&2; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      [[ "$line" == *=* ]] || { printf 'malformed environment state in %s\n' "$env_file" >&2; return 1; }
      key=${line%%=*}
      [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || { printf 'invalid environment name %s in %s\n' "$key" "$env_file" >&2; return 1; }
      [[ -z "${seen[$key]+present}" ]] || { printf 'duplicate environment name %s in %s\n' "$key" "$env_file" >&2; return 1; }
      seen[$key]=true
      if [[ -n "${candaceos_environment_state_names[$key]+present}" ]]; then
        existing[$key]=${line#*=}
      fi
    done <"$env_file"
  fi

  command -v openssl >/dev/null || { printf 'openssl is required to generate local secrets\n' >&2; return 1; }
  umask 077
  temporary=$(mktemp "${env_file}.tmp.XXXXXX") || return 1
  : >"$temporary"
  for symbol in "${candaceos_environment_state_symbols[@]}"; do
    name=${candaceos_environment_names[$symbol]}
    lifecycle=${candaceos_environment_lifecycles[$symbol]}
    generator=${candaceos_environment_values[$symbol]}
    required=${candaceos_environment_required[$symbol]}
    case "$lifecycle" in
      secret)
        value=${existing[$name]-}
        case "$generator" in
          random_hex_32)
            if [[ -z "$value" ]]; then
              value=$(openssl rand -hex 32) || { rm -f "$temporary"; printf 'could not generate %s\n' "$name" >&2; return 1; }
            fi
            if [[ ! "$value" =~ ^[0-9a-f]{64}$ ]]; then
              rm -f "$temporary"
              printf '%s is malformed in %s; expected 64 lowercase hexadecimal characters\n' "$name" "$env_file" >&2
              return 1
            fi
            ;;
          *) rm -f "$temporary"; printf 'unsupported secret generator %s\n' "$generator" >&2; return 1 ;;
        esac
        ;;
      host)
        case "$generator" in
          uid) value=$(id -u) ;;
          gid) value=$(id -g) ;;
          apps_dir) value=$apps_dir ;;
          state_root) value=$state_root ;;
          *) rm -f "$temporary"; printf 'unsupported host generator %s\n' "$generator" >&2; return 1 ;;
        esac
        ;;
      operator)
        incoming=${!name-}
        if [[ -n "$incoming" ]]; then
          value=$incoming
        elif [[ -n "${existing[$name]+present}" ]]; then
          value=${existing[$name]}
        else
          value=$generator
        fi
        ;;
      *) rm -f "$temporary"; printf 'unsupported environment lifecycle %s\n' "$lifecycle" >&2; return 1 ;;
    esac
    if [[ "$required" == true && -z "$value" ]]; then
      rm -f "$temporary"
      printf '%s is required by Candacefile\n' "$name" >&2
      return 1
    fi
    case "$value" in
      *[[:space:]]*|*'#'*|*'$'*|*'"'*|*"'"*|*$'\x5c'*)
        rm -f "$temporary"
        printf '%s contains characters that Docker Compose env files cannot represent safely\n' "$name" >&2
        return 1
        ;;
    esac
    printf '%s=%s\n' "$name" "$value" >>"$temporary"
    printf -v "$name" '%s' "$value"
    export "$name"
  done
  chmod 600 "$temporary"
  mv "$temporary" "$env_file"
}

candaceos_environment_apply_defaults() {
  if [[ -z "${POSTGRES_DB:-}" ]]; then
    printf -v POSTGRES_DB %s candaceos
    export POSTGRES_DB
  fi
  if [[ -z "${POSTGRES_USER:-}" ]]; then
    printf -v POSTGRES_USER %s candaceos
    export POSTGRES_USER
  fi
  if [[ -z "${CANDACEOS_AGENT_BIND:-}" ]]; then
    printf -v CANDACEOS_AGENT_BIND %s 0.0.0.0:8094
    export CANDACEOS_AGENT_BIND
  fi
  if [[ -z "${CANDACEOS_AGENT_NODE_ID:-}" ]]; then
    printf -v CANDACEOS_AGENT_NODE_ID %s candaceos-demo
    export CANDACEOS_AGENT_NODE_ID
  fi
  if [[ -z "${CANDACEOS_AGENT_STATE_FILE:-}" ]]; then
    printf -v CANDACEOS_AGENT_STATE_FILE %s /var/lib/candaceos-agent/state.json
    export CANDACEOS_AGENT_STATE_FILE
  fi
  if [[ -z "${CANDACEOS_AGENT_REVISION_ROOT:-}" ]]; then
    printf -v CANDACEOS_AGENT_REVISION_ROOT %s /var/lib/candaceos-agent/revisions
    export CANDACEOS_AGENT_REVISION_ROOT
  fi
  if [[ -z "${DOCKER_CONFIG:-}" ]]; then
    printf -v DOCKER_CONFIG %s /tmp/docker-config
    export DOCKER_CONFIG
  fi
  if [[ -z "${CANDACEOS_AGENT_DRY_WORKSPACE:-}" ]]; then
    printf -v CANDACEOS_AGENT_DRY_WORKSPACE %s /workspace
    export CANDACEOS_AGENT_DRY_WORKSPACE
  fi
  if [[ -z "${CANDACEOS_AGENT_LIVE_WORKSPACE:-}" ]]; then
    printf -v CANDACEOS_AGENT_LIVE_WORKSPACE %s /workspace
    export CANDACEOS_AGENT_LIVE_WORKSPACE
  fi
  if [[ -z "${CANDACEOS_AGENT_DRY_RUN_ENABLED:-}" ]]; then
    printf -v CANDACEOS_AGENT_DRY_RUN_ENABLED %s true
    export CANDACEOS_AGENT_DRY_RUN_ENABLED
  fi
  if [[ -z "${CANDACEOS_AGENT_DRY_RUN_DISABLED:-}" ]]; then
    printf -v CANDACEOS_AGENT_DRY_RUN_DISABLED %s false
    export CANDACEOS_AGENT_DRY_RUN_DISABLED
  fi
  if [[ -z "${WARDEN_CONFIG:-}" ]]; then
    printf -v WARDEN_CONFIG %s /etc/warden/warden.yaml
    export WARDEN_CONFIG
  fi
  if [[ -z "${WARDEN_LOG_FORMAT:-}" ]]; then
    printf -v WARDEN_LOG_FORMAT %s console
    export WARDEN_LOG_FORMAT
  fi
  if [[ -z "${CANDACEOS_COPILOT_HOME:-}" ]]; then
    printf -v CANDACEOS_COPILOT_HOME %s /var/lib/copilot
    export CANDACEOS_COPILOT_HOME
  fi
  if [[ -z "${CANDACEOS_HARNESS_BACKEND:-}" ]]; then
    printf -v CANDACEOS_HARNESS_BACKEND %s copilot-cli
    export CANDACEOS_HARNESS_BACKEND
  fi
  if [[ -z "${CANDACEOS_BIND:-}" ]]; then
    printf -v CANDACEOS_BIND %s 0.0.0.0:7780
    export CANDACEOS_BIND
  fi
  if [[ -z "${CANDACEOS_DATA_DIR:-}" ]]; then
    printf -v CANDACEOS_DATA_DIR %s /var/lib/candaceos
    export CANDACEOS_DATA_DIR
  fi
  if [[ -z "${CANDACEOS_WORKSPACE:-}" ]]; then
    printf -v CANDACEOS_WORKSPACE %s /workspace
    export CANDACEOS_WORKSPACE
  fi
  if [[ -z "${CANDACEOS_DATABASE_URL:-}" ]]; then
    export CANDACEOS_DATABASE_URL=''
  fi
  if [[ -z "${CANDACEOS_WARDEN_URL:-}" ]]; then
    printf -v CANDACEOS_WARDEN_URL %s http://127.0.0.1:7717
    export CANDACEOS_WARDEN_URL
  fi
  if [[ -z "${CANDACEOS_AGENT_URL:-}" ]]; then
    export CANDACEOS_AGENT_URL=''
  fi
  if [[ -z "${CANDACEOS_AGENT_PORT:-}" ]]; then
    printf -v CANDACEOS_AGENT_PORT %s 8094
    export CANDACEOS_AGENT_PORT
  fi
  if [[ -z "${CANDACEOS_NODE_LABELS:-}" ]]; then
    printf -v CANDACEOS_NODE_LABELS %s '{}'
    export CANDACEOS_NODE_LABELS
  fi
  if [[ -z "${CANDACEOS_APPROVAL_TIMEOUT:-}" ]]; then
    printf -v CANDACEOS_APPROVAL_TIMEOUT %s 15m
    export CANDACEOS_APPROVAL_TIMEOUT
  fi
  if [[ -z "${CANDACEOS_FLEET_POLL_INTERVAL:-}" ]]; then
    printf -v CANDACEOS_FLEET_POLL_INTERVAL %s 2s
    export CANDACEOS_FLEET_POLL_INTERVAL
  fi
  if [[ -z "${CANDACEOS_COPILOT_CLI:-}" ]]; then
    printf -v CANDACEOS_COPILOT_CLI %s /usr/local/bin/copilot
    export CANDACEOS_COPILOT_CLI
  fi
  if [[ -z "${CANDACEOS_COPILOT_URL:-}" ]]; then
    export CANDACEOS_COPILOT_URL=''
  fi
  if [[ -z "${CANDACEOS_COPILOT_MODEL:-}" ]]; then
    printf -v CANDACEOS_COPILOT_MODEL %s gpt-5.4
    export CANDACEOS_COPILOT_MODEL
  fi
  if [[ -z "${CANDACEOS_OLLAMA_URL:-}" ]]; then
    export CANDACEOS_OLLAMA_URL=''
  fi
  if [[ -z "${CANDACEOS_OLLAMA_MODEL:-}" ]]; then
    export CANDACEOS_OLLAMA_MODEL=''
  fi
  if [[ -z "${CANDACEOS_OLLAMA_MODEL_DIGEST:-}" ]]; then
    export CANDACEOS_OLLAMA_MODEL_DIGEST=''
  fi
  if [[ -z "${CANDACEOS_OLLAMA_CONTEXT_TOKENS:-}" ]]; then
    printf -v CANDACEOS_OLLAMA_CONTEXT_TOKENS %s 16384
    export CANDACEOS_OLLAMA_CONTEXT_TOKENS
  fi
  if [[ -z "${CANDACEOS_OLLAMA_MAX_TOOL_CALLS:-}" ]]; then
    printf -v CANDACEOS_OLLAMA_MAX_TOOL_CALLS %s 16
    export CANDACEOS_OLLAMA_MAX_TOOL_CALLS
  fi
  if [[ -z "${CANDACEOS_OLLAMA_TURN_TIMEOUT:-}" ]]; then
    printf -v CANDACEOS_OLLAMA_TURN_TIMEOUT %s 10m
    export CANDACEOS_OLLAMA_TURN_TIMEOUT
  fi
  if [[ -z "${CANDACEOS_OPENCODE_URL:-}" ]]; then
    printf -v CANDACEOS_OPENCODE_URL %s http://127.0.0.1:4096
    export CANDACEOS_OPENCODE_URL
  fi
  if [[ -z "${CANDACEOS_OPENCODE_USERNAME:-}" ]]; then
    printf -v CANDACEOS_OPENCODE_USERNAME %s opencode
    export CANDACEOS_OPENCODE_USERNAME
  fi
  if [[ -z "${CANDACEOS_OPENCODE_SESSION_ID:-}" ]]; then
    export CANDACEOS_OPENCODE_SESSION_ID=''
  fi
  if [[ -z "${CANDACEOS_OPENCODE_REQUEST_TIMEOUT:-}" ]]; then
    printf -v CANDACEOS_OPENCODE_REQUEST_TIMEOUT %s 10s
    export CANDACEOS_OPENCODE_REQUEST_TIMEOUT
  fi
  if [[ -z "${CANDACEOS_OPENCODE_POLL_INTERVAL:-}" ]]; then
    printf -v CANDACEOS_OPENCODE_POLL_INTERVAL %s 1s
    export CANDACEOS_OPENCODE_POLL_INTERVAL
  fi
  if [[ -z "${CANDACEOS_OPENCODE_QUEUE_CAPACITY:-}" ]]; then
    printf -v CANDACEOS_OPENCODE_QUEUE_CAPACITY %s 32
    export CANDACEOS_OPENCODE_QUEUE_CAPACITY
  fi
  if [[ -z "${CANDACEOS_LIVE_CONFIRM_PHRASE:-}" ]]; then
    printf -v CANDACEOS_LIVE_CONFIRM_PHRASE %s I_UNDERSTAND_DOCKER_SOCKET_IS_ROOT
    export CANDACEOS_LIVE_CONFIRM_PHRASE
  fi
}

candaceos_environment_apply_profile() {
  case $1 in
    local)
      printf -v CANDACEOS_AGENT_REVISION_ROOT %s%s "${CANDACEOS_STATE_ROOT:-}" /revisions
      export CANDACEOS_AGENT_REVISION_ROOT
      printf -v CANDACEOS_AGENT_LIVE_WORKSPACE %s "${CANDACEOS_HOST_WORKSPACE:-}"
      export CANDACEOS_AGENT_LIVE_WORKSPACE
      printf -v CANDACEOS_DATABASE_URL %s%s%s postgres://candaceos: "${POSTGRES_PASSWORD:-}" '@postgres:5432/candaceos?sslmode=disable'
      export CANDACEOS_DATABASE_URL
      printf -v CANDACEOS_WARDEN_URL %s http://warden:7717
      export CANDACEOS_WARDEN_URL
      printf -v CANDACEOS_AGENT_URL %s http://candaceos-agent:8094
      export CANDACEOS_AGENT_URL
      printf -v CANDACEOS_NODE_LABELS %s '{"candaceos-demo":{"environment":"prototype","runtime":"compose"}}'
      export CANDACEOS_NODE_LABELS
      ;;
    demo)
      printf -v CANDACEOS_HARNESS_BACKEND %s demo
      export CANDACEOS_HARNESS_BACKEND
      export CANDACEOS_COPILOT_URL=''
      export CANDACEOS_OPENCODE_URL=''
      ;;
    copilot)
      printf -v CANDACEOS_HARNESS_BACKEND %s copilot-cli
      export CANDACEOS_HARNESS_BACKEND
      printf -v CANDACEOS_COPILOT_URL %s http://copilot:4321
      export CANDACEOS_COPILOT_URL
      export CANDACEOS_OPENCODE_URL=''
      ;;
    opencode)
      printf -v CANDACEOS_HARNESS_BACKEND %s opencode
      export CANDACEOS_HARNESS_BACKEND
      export CANDACEOS_COPILOT_URL=''
      printf -v CANDACEOS_OPENCODE_URL %s http://opencode:4096
      export CANDACEOS_OPENCODE_URL
      ;;
    *) printf 'unknown Candacefile environment profile: %s\n' "$1" >&2; return 1 ;;
  esac
}
