#!/usr/bin/env bash
set -Eeuo pipefail

pinned_ollama_digest='sha256:e771d18fe56724f01a6f691a5773df544f36f565fb37c93f0ddc5957007b7766'
pinned_ollama_image="ollama/ollama:0.20.4@$pinned_ollama_digest"

die() {
  printf 'candaceos fleet node: %s\n' "$*" >&2
  exit 1
}

resolve_root() {
  local requested=$1 resolved
  if [[ "$requested" == /* ]]; then
    resolved=$(realpath -m -- "$requested")
  else
    resolved=$(realpath -m -- "$HOME/$requested")
  fi
  [[ "$resolved" == "$HOME/"* ]] || die "state root must be below the invoking user's home directory"
  [[ "$resolved" != "$HOME" ]] || die "state root cannot be the home directory"
  printf '%s\n' "$resolved"
}

validate_release_id() {
  [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || die "invalid release id: $1"
}

env_value() {
  local file=$1 key=$2 count
  count=$(grep -c "^${key}=" "$file" || true)
  [[ "$count" == 1 ]] || die "$key must occur exactly once in $file"
  sed -n "s/^${key}=//p" "$file"
}

env_optional() {
  local file=$1 key=$2 count
  count=$(grep -c "^${key}=" "$file" || true)
  [[ "$count" -le 1 ]] || die "$key must not be duplicated in $file"
  sed -n "s/^${key}=//p" "$file"
}

release_harness() {
  local env_file=$1 backend
  backend=$(env_optional "$env_file" CANDACEOS_HARNESS_BACKEND)
  [[ -n "$backend" ]] || backend=copilot-cli
  [[ "$backend" == copilot-cli || "$backend" == ollama || "$backend" == custom ]] || \
    die "release has an unsupported harness backend: $backend"
  printf '%s\n' "$backend"
}

verify_copilot_binary() {
  local env_file=$1 binary expected actual
  binary=$(env_value "$env_file" CANDACEOS_COPILOT_BIN)
  expected=$(env_value "$env_file" CANDACEOS_COPILOT_SHA256)
  [[ "$binary" == /* && "$expected" =~ ^[0-9a-f]{64}$ ]] || \
    die "control release contains invalid Copilot binary metadata"
  [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || \
    die "control Copilot binary is absent or mutable through a symlink: $binary"
  actual=$(sha256sum "$binary" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || \
    die "control Copilot binary checksum is $actual, expected $expected"
  printf '%s\n' "$actual"
}

release_dir() {
  local root=$1 release_id=$2
  validate_release_id "$release_id"
  printf '%s/releases/%s\n' "$root" "$release_id"
}

compose() {
  local directory=$1
  local -a files=(-f "$directory/compose.yaml")
  [[ ! -f "$directory/backend.compose.yaml" ]] || files+=(-f "$directory/backend.compose.yaml")
  docker compose --project-directory "$directory" --project-name candaceos-fleet \
    --env-file "$directory/.env" "${files[@]}" "${@:2}"
}

safe_archive() {
  local archive=$1 entry listing
  listing=$(tar -tzf "$archive")
  [[ -n "$listing" ]] || die "release archive is empty: $archive"
  while IFS= read -r entry; do
    case "$entry" in
      /*|../*|*/../*|*/..) die "release archive contains an unsafe path: $entry" ;;
    esac
  done <<<"$listing"
}

preflight() {
  local root=$1 version major minor docker_gid
  [[ "$(uname -s)" == Linux ]] || die "Linux is required"
  for command in docker curl git gzip python3 realpath rsync sha256sum tar; do
    command -v "$command" >/dev/null || die "$command is required"
  done
  docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable by $(id -un)"
  version=$(docker compose version --short 2>/dev/null) || die "Docker Compose v2.20 or newer is required"
  version=${version#v}
  IFS=. read -r major minor _ <<<"${version%%-*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || die "cannot parse Docker Compose version $version"
  ((major > 2 || (major == 2 && minor >= 20))) || die "Docker Compose v2.20 or newer is required"
  [[ -S /var/run/docker.sock ]] || die "/var/run/docker.sock is not a Unix socket"
  docker_gid=$(stat -c '%g' /var/run/docker.sock)
  printf 'root=%s\nuid=%s\ngid=%s\ndocker_gid=%s\n' "$root" "$(id -u)" "$(id -g)" "$docker_gid"
}

preflight_ollama() {
  docker info --format '{{json .Runtimes}}' | python3 -c 'import json, sys
runtimes = json.load(sys.stdin)
if "nvidia" not in runtimes:
    raise SystemExit("Docker does not expose the existing NVIDIA runtime")'
}

validate_ollama_model() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    die "Ollama model must be an explicit name:tag"
}

pull_pinned_image() {
  local image=$2 digest=$3
  [[ "$digest" == "$pinned_ollama_digest" && "$image" == "$pinned_ollama_image" ]] || \
    die "only the pinned Ollama 0.20.4 image is accepted"
  docker pull "$image" >&2
  docker image inspect "$image" >/dev/null
}

validate_image_role() {
  [[ "$1" == control || "$1" == worker ]] || die "image role must be control or worker"
}

image_archive_path() {
  local root=$1 role=$2
  validate_image_role "$role"
  printf '%s/image-cache/%s.tar\n' "$root" "$role"
}

prepare_image_upload() {
  local root=$1 role=$2 archive
  archive=$(image_archive_path "$root" "$role")
  [[ ! -L "$root" && ! -L "$root/image-cache" && ! -L "$archive" ]] || \
    die "image cache must not contain symbolic links"
  mkdir -p "$root/image-cache"
  chmod 700 "$root" "$root/image-cache"
  printf '%s\n' "$archive"
}

load_image_archive() {
  local root=$1 role=$2 expected=$3 archive actual
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "image archive checksum is malformed"
  archive=$(image_archive_path "$root" "$role")
  [[ -f "$archive" && ! -L "$archive" ]] || die "$role image archive is absent"
  actual=$(sha256sum "$archive" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || \
    die "$role image archive checksum is $actual, expected $expected"
  docker load --input "$archive" >/dev/null
}

check_ports() {
  local root=$1 role=$2 node_ip=$3 current
  [[ "$role" == control || "$role" == worker ]] || die "role must be control or worker"
  current=$(current_release "$root")
  # On upgrades these listeners belong to the current candaceos-fleet project
  # and Compose will replace its own containers in place.
  [[ -z "$current" ]] || return 0
  python3 - "$role" "$node_ip" <<'PY'
import socket
import sys

role, node_ip = sys.argv[1:]
targets = [(node_ip, 7717)]
if role == "control":
    targets += [(node_ip, 9418), (node_ip, 7780)]
else:
    targets += [(node_ip, 8094)]
for host, port in targets:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind((host, port))
    except OSError as exc:
        raise SystemExit(f"required listener {host}:{port} is unavailable: {exc}")
    finally:
        sock.close()
PY
}

check_ollama_port() {
  local root=$1 node_ip=$2 current directory container
  current=$(current_release "$root")
  if [[ -n "$current" ]]; then
    directory=$(release_dir "$root" "$current")
    container=$(compose "$directory" ps -q ollama 2>/dev/null || true)
    [[ -z "$container" ]] || return 0
  fi
  python3 - "$node_ip" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind((sys.argv[1], 11434))
except OSError as exc:
    raise SystemExit(f"required Ollama listener {sys.argv[1]}:11434 is unavailable: {exc}")
finally:
    sock.close()
PY
}

prepare_upload() {
  local root=$1 release_id=$2 incoming
  validate_release_id "$release_id"
  incoming="$root/incoming/$release_id"
  [[ ! -L "$root" ]] || die "state root must not be a symbolic link"
  mkdir -p "$incoming"
  chmod 700 "$root" "$root/incoming" "$incoming"
  printf '%s\n' "$incoming"
}

install_release() {
  local root=$1 release_id=$2 role=$3 archive_sha=$4
  local incoming archive target temporary workspace installed_sha installed_copilot_sha copilot_sha current candidate candidate_head workspace_head backup
  local runtime_stage runtime_name runtime_target runtime_backup backend installed_backend
  [[ "$role" == control || "$role" == worker ]] || die "role must be control or worker"
  validate_release_id "$release_id"
  incoming="$root/incoming/$release_id"
  archive="$incoming/release.tgz"
  [[ -f "$archive" ]] || die "release payload is incomplete"
  [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$archive_sha" ]] || die "release archive checksum mismatch"
  safe_archive "$archive"

  target=$(release_dir "$root" "$release_id")
  if [[ -e "$target" ]]; then
    [[ -f "$target/.installed" ]] || die "existing release is incomplete: $target"
    installed_sha=$(sed -n 's/^archive_sha256=//p' "$target/.installed")
    [[ "$installed_sha" == "$archive_sha" ]] || die "release id already contains different content"
    backend=$(release_harness "$target/.env")
    installed_backend=$(sed -n 's/^harness_backend=//p' "$target/.installed")
    [[ -z "$installed_backend" || "$installed_backend" == "$backend" ]] || \
      die "installed release does not bind its harness backend"
    if [[ "$role" == control && "$backend" == copilot-cli ]]; then
      copilot_sha=$(verify_copilot_binary "$target/.env")
      installed_copilot_sha=$(sed -n 's/^copilot_sha256=//p' "$target/.installed")
      [[ "$installed_copilot_sha" == "$copilot_sha" ]] || \
        die "installed release does not bind its recorded Copilot checksum"
    fi
  else
    mkdir -p "$root/releases"
    temporary=$(mktemp -d "$root/releases/.${release_id}.XXXXXX")
    trap 'rm -rf -- "$temporary"' RETURN
    tar -xzf "$archive" -C "$temporary"
    [[ -f "$temporary/compose.yaml" && -f "$temporary/warden.yaml" && -f "$temporary/.env" ]] || \
      die "release archive is missing runtime files"
    [[ "$(stat -c '%a' "$temporary/.env")" == 600 ]] || die "release environment must have mode 600"
    backend=$(release_harness "$temporary/.env")
    if [[ "$role" == control && "$backend" == copilot-cli ]]; then
      copilot_sha=$(verify_copilot_binary "$temporary/.env")
    fi
    {
      printf 'archive_sha256=%s\nrole=%s\nharness_backend=%s\n' "$archive_sha" "$role" "$backend"
      [[ -z "${copilot_sha:-}" ]] || printf 'copilot_sha256=%s\n' "$copilot_sha"
    } >"$temporary/.installed"
    chmod 600 "$temporary/.installed"
    mv "$temporary" "$target"
    trap - RETURN
  fi

  workspace=$(env_value "$target/.env" CANDACEOS_HOST_WORKSPACE)
  [[ "$workspace" == "$root/apps" ]] || die "workspace must be the fleet state root's apps directory"
  current=$(current_release "$root")
  mkdir -p "$root/runtime/warden" "$root/runtime/source-sync" "$root/runtime/agent" \
    "$root/runtime/core" "$root/revisions"
  [[ "$role" != control || "$backend" != copilot-cli ]] || mkdir -p "$root/runtime/copilot"
  if [[ "$role" == control ]]; then
    [[ -f "$target/apps.bundle" ]] || die "control release has no app repository bundle"
    if [[ -z "$current" ]]; then
      candidate=$(mktemp -d "$root/.apps.${release_id}.XXXXXX")
      rmdir "$candidate"
      git clone -q "$target/apps.bundle" "$candidate"
      git -C "$candidate" remote remove origin
      candidate_head=$(git -C "$candidate" rev-parse HEAD)
      workspace_head=
      if [[ -e "$workspace/.git" && ! -L "$workspace/.git" ]]; then
        workspace_head=$(git -C "$workspace" rev-parse HEAD 2>/dev/null || true)
      fi
      if [[ "$workspace_head" == "$candidate_head" && -z "$(git -C "$workspace" status --porcelain)" ]]; then
        rm -rf -- "$candidate"
      else
        if [[ -e "$workspace" || -L "$workspace" ]]; then
          mkdir -p "$root/failed-apps"
          chmod 700 "$root/failed-apps"
          backup=$(mktemp -d "$root/failed-apps/${release_id}.XXXXXX")
          rmdir "$backup"
          mv "$workspace" "$backup"
        fi
        mv "$candidate" "$workspace"
      fi
    fi
    [[ ! -L "$workspace/.git" ]] || die "$workspace/.git must not be a symbolic link"
    [[ "$(git -C "$workspace" rev-parse --show-toplevel)" == "$workspace" ]] || die "invalid control app worktree"
    git -C "$workspace" config --local --get user.name >/dev/null 2>&1 || \
      git -C "$workspace" config --local user.name 'CandaceOS Bot'
    git -C "$workspace" config --local --get user.email >/dev/null 2>&1 || \
      git -C "$workspace" config --local user.email 'candaceos@localhost'
    if [[ -f "$target/runtime.tgz" ]]; then
      safe_archive "$target/runtime.tgz"
      runtime_stage=$(mktemp -d "$root/.runtime.${release_id}.XXXXXX")
      tar -xzf "$target/runtime.tgz" -C "$runtime_stage"
      local runtime_names=(core)
      [[ "$backend" != copilot-cli ]] || runtime_names+=(copilot)
      for runtime_name in "${runtime_names[@]}"; do
        [[ -d "$runtime_stage/$runtime_name" ]] || continue
        runtime_target="$root/runtime/$runtime_name"
        if [[ -e "$runtime_target" || -L "$runtime_target" ]]; then
          mkdir -p "$root/failed-runtime/$release_id"
          chmod 700 "$root/failed-runtime" "$root/failed-runtime/$release_id"
          runtime_backup=$(mktemp -d "$root/failed-runtime/$release_id/${runtime_name}.XXXXXX")
          rmdir "$runtime_backup"
          mv "$runtime_target" "$runtime_backup"
        fi
        mv "$runtime_stage/$runtime_name" "$runtime_target"
      done
      rm -rf -- "$runtime_stage"
    fi
  else
    # Worker agents fetch approved objects into their own bare repository.
    # Keep the compatibility workspace empty and read-only.
    mkdir -p "$workspace"
    [[ -z "$(find "$workspace" -mindepth 1 -maxdepth 1 -print -quit)" ]] || \
      die "$workspace must stay empty on a worker"
  fi
  rm -f -- "$archive"
}

activate_control_database() {
  local root=$1 release_id=$2 target
  target=$(release_dir "$root" "$release_id")
  [[ "$(sed -n 's/^role=//p' "$target/.installed")" == control ]] || die "database activation requires a control release"
  compose "$target" up -d --no-build --pull never --wait --wait-timeout 120 postgres
}

control_database_container() {
  local directory=$1 container
  container=$(compose "$directory" ps -q postgres)
  [[ -n "$container" ]] || die "control PostgreSQL container is absent"
  printf '%s\n' "$container"
}

backup_control_database() {
  local root=$1 release_id=$2 current current_dir container backup
  validate_release_id "$release_id"
  current=$(current_release "$root")
  [[ -n "$current" ]] || return 0
  current_dir=$(release_dir "$root" "$current")
  container=$(control_database_container "$current_dir")
  umask 077
  mkdir -p "$root/backups"
  chmod 700 "$root/backups"
  backup="$root/backups/$release_id.dump"
  docker exec "$container" pg_dump -U candaceos -d candaceos --format=custom \
    --no-owner --no-privileges >"$backup.tmp"
  [[ -s "$backup.tmp" ]] || die "control database backup is empty"
  mv "$backup.tmp" "$backup"
  chmod 600 "$backup"
  database_fingerprint "$container"
}

restore_database_file() {
  local directory=$1 dump=$2 container
  [[ -s "$dump" ]] || die "database dump is absent or empty: $dump"
  container=$(control_database_container "$directory")
  docker exec -i "$container" pg_restore -U candaceos -d candaceos \
    --clean --if-exists --no-owner --no-privileges --single-transaction <"$dump"
}

restore_initial_database() {
  local root=$1 release_id=$2 target dump backup
  target=$(release_dir "$root" "$release_id")
  dump="$target/database.dump"
  [[ -s "$dump" ]] || die "initial database dump was not transferred"
  restore_database_file "$target" "$dump"
  umask 077
  mkdir -p "$root/backups"
  chmod 700 "$root/backups"
  backup="$root/backups/$release_id.dump"
  mv "$dump" "$backup"
  chmod 600 "$backup"
}

database_fingerprint() {
  local container=$1 table count receipt_max table_output entries=() tables=()
  table_output=$(docker exec "$container" psql -U candaceos -d candaceos -At -c \
    "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'candaceos_%' ORDER BY tablename;")
  [[ -n "$table_output" ]] || die "database contains no CandaceOS tables"
  mapfile -t tables <<<"$table_output"
  for table in "${tables[@]}"; do
    [[ "$table" =~ ^candaceos_[a-z0-9_]+$ ]] || die "database returned an invalid CandaceOS table name"
    count=$(docker exec "$container" psql -U candaceos -d candaceos -At -c "SELECT COUNT(*) FROM $table;")
    [[ "$count" =~ ^[0-9]+$ ]] || die "database returned an invalid count for $table"
    entries+=("$table=$count")
  done
  ((${#entries[@]} > 0)) || die "database contains no CandaceOS tables"
  receipt_max=$(docker exec "$container" psql -U candaceos -d candaceos -At -c \
    'SELECT COALESCE(MAX(receipt_id),0) FROM candaceos_activity_receipts;')
  [[ "$receipt_max" =~ ^[0-9]+$ ]] || die "database returned an invalid receipt maximum"
  local joined
  joined=$(IFS=';'; printf '%s' "${entries[*]}")
  printf 'tables=%s|receipt_max=%s\n' "$joined" "$receipt_max"
}

legacy_database_fingerprint() {
  database_fingerprint "$(legacy_postgres_container)"
}

verify_control_database() {
  local root=$1 release_id=$2 expected=$3 target container actual
  target=$(release_dir "$root" "$release_id")
  container=$(control_database_container "$target")
  actual=$(database_fingerprint "$container")
  [[ "$actual" == "$expected" ]] || die "restored database fingerprint is $actual, expected $expected"
}

stop_control_writers() {
  local directory=$1 output
  local services=(core)
  output=$(compose "$directory" config --services)
  if grep -qx copilot <<<"$output"; then
    services+=(copilot)
  fi
  compose "$directory" stop "${services[@]}" >/dev/null
}

quiesce_control_writers() {
  local root=$1 current directory
  current=$(current_release "$root")
  [[ -n "$current" ]] || return 0
  directory=$(release_dir "$root" "$current")
  stop_control_writers "$directory"
}

resume_control() {
  local root=$1 current directory
  current=$(current_release "$root")
  [[ -n "$current" ]] || return 0
  directory=$(release_dir "$root" "$current")
  compose "$directory" up -d --no-build --pull never --remove-orphans --wait --wait-timeout 120
}

activate_release() {
  local root=$1 release_id=$2 target
  target=$(release_dir "$root" "$release_id")
  [[ -f "$target/.installed" ]] || die "release is not installed: $release_id"
  compose "$target" config --quiet
  compose "$target" up -d --no-build --pull never --remove-orphans --wait --wait-timeout 120
}

commit_release() {
  local root=$1 release_id=$2 target link
  target=$(release_dir "$root" "$release_id")
  [[ -f "$target/.installed" ]] || die "release is not installed: $release_id"
  link="$root/.current.$release_id"
  rm -f -- "$link"
  ln -s "releases/$release_id" "$link"
  mv -Tf "$link" "$root/current"
}

current_release() {
  local root=$1 current
  if [[ ! -L "$root/current" ]]; then
    printf '\n'
    return
  fi
  current=$(readlink "$root/current")
  case "$current" in
    releases/*) printf '%s\n' "${current#releases/}" ;;
    *) die "current release link has an unexpected target" ;;
  esac
}

rollback_release() {
  local root=$1 candidate=$2 previous=${3:-} mode=${4:-manual} expected_fingerprint=${5:-}
  local candidate_dir previous_dir role backup current forward_dir forward actual
  [[ "$mode" == manual || "$mode" == automatic ]] || die "rollback mode must be manual or automatic"
  candidate_dir=$(release_dir "$root" "$candidate")
  [[ -f "$candidate_dir/.installed" ]] || die "candidate release is unavailable: $candidate"
  current=$(current_release "$root")
  if [[ "$mode" == manual ]]; then
    if [[ "$current" == "$previous" ]]; then
      if [[ -n "$previous" ]]; then
        previous_dir=$(release_dir "$root" "$previous")
        compose "$previous_dir" up -d --no-build --pull never --remove-orphans --wait --wait-timeout 120
      else
        # Activation happens before the current symlink is committed. On an
        # interrupted first install, current and previous are both empty even
        # though candidate containers may already own the ports.
        compose "$candidate_dir" down --remove-orphans
      fi
      printf 'rollback already applied: %s\n' "$candidate"
      return 0
    fi
    [[ "$current" == "$candidate" ]] || \
      die "stale rollback receipt: current release is ${current:-<none>}, not candidate $candidate"
  else
    [[ "$current" == "$candidate" || "$current" == "$previous" ]] || \
      die "automatic rollback found unexpected current release ${current:-<none>}"
  fi
  role=$(sed -n 's/^role=//p' "$candidate_dir/.installed")
  if [[ "$role" == control && -n "$previous" ]]; then
    backup="$root/backups/$candidate.dump"
    [[ -s "$backup" ]] || die "database rollback backup is unavailable: $backup"
    stop_control_writers "$candidate_dir" >/dev/null 2>&1 || true
    compose "$candidate_dir" up -d --no-build --pull never --wait --wait-timeout 120 postgres
    forward_dir="$root/forward-recovery"
    umask 077
    mkdir -p "$forward_dir"
    chmod 700 "$forward_dir"
    forward=$(mktemp "$forward_dir/${candidate}.XXXXXX.dump")
    if ! docker exec "$(control_database_container "$candidate_dir")" \
      pg_dump -U candaceos -d candaceos --format=custom --no-owner --no-privileges >"$forward"; then
      rm -f -- "$forward"
      die "could not preserve the candidate database before rollback"
    fi
    [[ -s "$forward" ]] || die "forward-recovery database backup is empty"
    chmod 600 "$forward"
    restore_database_file "$candidate_dir" "$backup"
    if [[ -n "$expected_fingerprint" ]]; then
      actual=$(database_fingerprint "$(control_database_container "$candidate_dir")")
      [[ "$actual" == "$expected_fingerprint" ]] || \
        die "rolled-back database fingerprint is $actual, expected $expected_fingerprint"
    fi
    printf 'forward_recovery_database=%s\n' "$forward"
  fi
  if [[ -n "$previous" ]]; then
    previous_dir=$(release_dir "$root" "$previous")
    [[ -f "$previous_dir/.installed" ]] || die "previous release is unavailable: $previous"
    compose "$previous_dir" up -d --no-build --pull never --remove-orphans --wait --wait-timeout 120
    commit_release "$root" "$previous"
  else
    compose "$candidate_dir" down --remove-orphans
    rm -f "$root/current"
  fi
}

verify_ollama_model() {
  local url=$1 model=$2 context_tokens=$3 expected_digest=${4:-} payload tags show digest processes
  validate_ollama_model "$model"
  [[ "$context_tokens" =~ ^[0-9]+$ ]] && ((context_tokens >= 4096 && context_tokens <= 32768)) || \
    die "Ollama context tokens must be between 4096 and 32768"
  [[ "$url" =~ ^http://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:11434$ ]] || die "Ollama URL must use the AI node's explicit port 11434"
  tags=$(curl --fail --silent --show-error --max-time 10 "$url/api/tags")
  digest=$(python3 -c 'import json, re, sys
model = sys.argv[1]
body = json.load(sys.stdin)
matches = [entry for entry in body.get("models", []) if entry.get("name") == model or entry.get("model") == model]
if len(matches) != 1:
    raise SystemExit(f"Ollama does not expose exactly one {model!r} model")
digest = matches[0].get("digest", "")
digest = digest.removeprefix("sha256:")
if not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise SystemExit("Ollama model digest is malformed")
print(digest)' "$model" <<<"$tags")
  [[ -z "$expected_digest" || "$digest" == "$expected_digest" ]] || \
    die "Ollama model digest is $digest, expected $expected_digest"
  payload=$(python3 -c 'import json, sys; print(json.dumps({"model": sys.argv[1]}))' "$model")
  show=$(curl --fail --silent --show-error --max-time 30 \
    -H 'Content-Type: application/json' --data-binary "$payload" "$url/api/show")
  python3 -c 'import json, sys
body = json.load(sys.stdin)
capabilities = body.get("capabilities")
if not isinstance(capabilities, list) or "tools" not in capabilities:
    raise SystemExit("Ollama reports that the selected model lacks tool capability")' <<<"$show"

  processes=$(curl --fail --silent --show-error --max-time 10 "$url/api/ps")
  python3 -c 'import json, sys
model = sys.argv[1]
context_tokens = int(sys.argv[2])
body = json.load(sys.stdin)
matches = [entry for entry in body.get("models", []) if entry.get("name") == model or entry.get("model") == model]
if len(matches) != 1:
    raise SystemExit(f"Ollama does not expose exactly one loaded {model!r} process")
entry = matches[0]
size = entry.get("size")
size_vram = entry.get("size_vram")
if not isinstance(size, int) or size <= 0 or size_vram != size:
    raise SystemExit("loaded Ollama model is not fully GPU resident")
actual_context = entry.get("context_length")
if actual_context != context_tokens:
    raise SystemExit(f"loaded Ollama context is {actual_context}, expected {context_tokens}")' \
    "$model" "$context_tokens" <<<"$processes"
  printf '%s\n' "$digest"
}

warm_ollama_model() {
  local url=$1 model=$2 context_tokens=$3 payload response
  payload=$(python3 -c 'import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": "Reply with one word: ready."}],
    "stream": False,
    "think": False,
    "keep_alive": -1,
    "options": {"num_ctx": int(sys.argv[2]), "num_predict": 1},
}))' "$model" "$context_tokens")
  response=$(curl --fail --silent --show-error --max-time 300 \
    -H 'Content-Type: application/json' --data-binary "$payload" "$url/api/chat")
  python3 -c 'import json, sys
body = json.load(sys.stdin)
if body.get("done") is not True:
    raise SystemExit("bounded Ollama warm-up did not complete")' <<<"$response"
}

record_ollama_model_digest() {
  local installed_file=$1 digest=$2 existing temporary
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "Ollama model digest is malformed"
  existing=$(sed -n 's/^ollama_model_digest=//p' "$installed_file")
  if [[ -n "$existing" ]]; then
    [[ "$existing" == "$digest" ]] || die "release already binds a different Ollama model digest"
    return 0
  fi
  temporary="$installed_file.model.tmp"
  { cat "$installed_file"; printf 'ollama_model_digest=%s\n' "$digest"; } >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$installed_file"
  sync -f "$installed_file"
}

current_ollama_model_digest() {
  local root=$1 current installed_file digest
  current=$(current_release "$root")
  [[ -n "$current" ]] || die "no committed Ollama release"
  installed_file="$(release_dir "$root" "$current")/.installed"
  digest=$(sed -n 's/^ollama_model_digest=//p' "$installed_file")
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "committed release has no bound Ollama model digest"
  printf '%s\n' "$digest"
}

activate_ollama() {
  local root=$1 release_id=$2 target env_file backend url model context_tokens image digest container actual_image model_digest
  target=$(release_dir "$root" "$release_id")
  [[ -f "$target/.installed" ]] || die "release is not installed: $release_id"
  env_file="$target/.env"
  backend=$(release_harness "$env_file")
  [[ "$backend" == ollama ]] || die "Ollama activation requires an Ollama release"
  url=$(env_value "$env_file" CANDACEOS_OLLAMA_URL)
  model=$(env_value "$env_file" CANDACEOS_OLLAMA_MODEL)
  context_tokens=$(env_value "$env_file" CANDACEOS_OLLAMA_CONTEXT_TOKENS)
  image=$(env_value "$env_file" CANDACEOS_OLLAMA_IMAGE)
  digest=$(env_value "$env_file" CANDACEOS_OLLAMA_IMAGE_DIGEST)
  [[ "$image" == "$pinned_ollama_image" && "$digest" == "$pinned_ollama_digest" ]] || \
    die "Ollama release image is not the pinned 0.20.4 digest"
  mkdir -p "$root/runtime/ollama"
  compose "$target" config --quiet
  compose "$target" up -d --no-build --pull never --wait --wait-timeout 120 ollama >&2
  container=$(compose "$target" ps -q ollama)
  [[ -n "$container" ]] || die "Ollama container is absent after activation"
  actual_image=$(docker inspect --format '{{.Config.Image}}' "$container")
  [[ "$actual_image" == "$image" ]] || die "Ollama container does not use the pinned image"
  compose "$target" exec -T -e OLLAMA_HOST=http://127.0.0.1:11434 ollama ollama pull "$model" >&2
  warm_ollama_model "$url" "$model" "$context_tokens"
  model_digest=$(verify_ollama_model "$url" "$model" "$context_tokens")
  record_ollama_model_digest "$target/.installed" "$model_digest"
  printf 'model_digest=%s\n' "$model_digest"
}

verify_control() {
  local root=$1 expected_head=$2 current env_file installed_file workspace web_bind_ip actual_head copilot_sha installed_copilot_sha running_output backend installed_backend expected_services
  local running=()
  current=$(current_release "$root")
  [[ -n "$current" ]] || die "no committed control release"
  env_file="$root/releases/$current/.env"
  installed_file="$root/releases/$current/.installed"
  workspace=$(env_value "$env_file" CANDACEOS_HOST_WORKSPACE)
  web_bind_ip=$(env_value "$env_file" CANDACEOS_WEB_BIND_IP)
  backend=$(release_harness "$env_file")
  installed_backend=$(sed -n 's/^harness_backend=//p' "$installed_file")
  [[ -z "$installed_backend" || "$installed_backend" == "$backend" ]] || die "current release harness evidence is inconsistent"
  case "$backend" in
    copilot-cli)
      copilot_sha=$(verify_copilot_binary "$env_file")
      installed_copilot_sha=$(sed -n 's/^copilot_sha256=//p' "$installed_file")
      [[ "$installed_copilot_sha" == "$copilot_sha" ]] || \
        die "current release does not bind its recorded Copilot checksum"
      expected_services='copilot core git-source postgres warden'
      ;;
    ollama)
      verify_ollama_model "$(env_value "$env_file" CANDACEOS_OLLAMA_URL)" \
        "$(env_value "$env_file" CANDACEOS_OLLAMA_MODEL)" \
        "$(env_value "$env_file" CANDACEOS_OLLAMA_CONTEXT_TOKENS)" >/dev/null
      expected_services='core git-source postgres warden'
      ;;
    custom)
      expected_services='core git-source postgres warden'
      ;;
  esac
  curl --fail --silent --show-error --max-time 3 "http://$web_bind_ip:7780/healthz" >/dev/null
  actual_head=$(git -C "$workspace" rev-parse HEAD)
  [[ "$actual_head" == "$expected_head" ]] || die "control app repository HEAD changed during deployment"
  git -C "$workspace" cat-file -e "$expected_head^{commit}"
  running_output=$(compose "$root/releases/$current" ps --status running --services | sort)
  [[ -z "$running_output" ]] || mapfile -t running <<<"$running_output"
  [[ "${running[*]}" == "$expected_services" ]] || \
    die "control service set is incomplete: ${running[*]}"
}

verify_worker() {
  local root=$1 expected_node=$2 expected_head=$3 current env_file installed_file node_ip token container_id response source_remote source_head running_output backend expected_services image digest ollama_container actual_image installed_digest
  local running=()
  current=$(current_release "$root")
  [[ -n "$current" ]] || die "no committed worker release"
  env_file="$root/releases/$current/.env"
  installed_file="$root/releases/$current/.installed"
  node_ip=$(env_value "$env_file" CANDACEOS_NODE_IP)
  token=$(env_value "$env_file" CANDACEOS_AGENT_TOKEN)
  source_remote=$(env_value "$env_file" CANDACEOS_AGENT_SOURCE_REMOTE)
  backend=$(release_harness "$env_file")
  source_head=$(git ls-remote "$source_remote" HEAD | awk 'NR == 1 {print $1}')
  [[ "$source_head" == "$expected_head" ]] || die "source service HEAD is $source_head, expected $expected_head"
  container_id=$(compose "$root/releases/$current" ps -q agent)
  [[ -n "$container_id" ]] || die "agent container is absent"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | \
    grep -qx 'CANDACEOS_AGENT_DRY_RUN=false' || die "worker agent is not live"
  response=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | \
    curl --config - --fail --silent --show-error --max-time 3 "http://$node_ip:8094/healthz")
  python3 -c 'import json,sys
body=json.load(sys.stdin)
expected=sys.argv[1]
actual=body.get("node_id", "")
if actual != expected:
    raise SystemExit(f"agent identity mismatch: expected {expected}, got {actual}")' "$expected_node" <<<"$response"
  expected_services='agent warden'
  # The GPU worker is the node whose release declares a pinned Ollama image,
  # not a node with a particular name.
  if [[ "$backend" == ollama && -n "$(env_optional "$env_file" CANDACEOS_OLLAMA_IMAGE)" ]]; then
    image=$(env_value "$env_file" CANDACEOS_OLLAMA_IMAGE)
    digest=$(env_value "$env_file" CANDACEOS_OLLAMA_IMAGE_DIGEST)
    [[ "$image" == "$pinned_ollama_image" && "$digest" == "$pinned_ollama_digest" ]] || \
      die "AI worker does not bind the pinned Ollama image"
    ollama_container=$(compose "$root/releases/$current" ps -q ollama)
    [[ -n "$ollama_container" ]] || die "AI worker Ollama container is absent"
    actual_image=$(docker inspect --format '{{.Config.Image}}' "$ollama_container")
    [[ "$actual_image" == "$image" ]] || die "AI worker Ollama image changed"
    installed_digest=$(sed -n 's/^ollama_model_digest=//p' "$installed_file")
    [[ "$installed_digest" =~ ^[0-9a-f]{64}$ ]] || die "AI worker release has no bound Ollama model digest"
    verify_ollama_model "$(env_value "$env_file" CANDACEOS_OLLAMA_URL)" \
      "$(env_value "$env_file" CANDACEOS_OLLAMA_MODEL)" \
      "$(env_value "$env_file" CANDACEOS_OLLAMA_CONTEXT_TOKENS)" "$installed_digest" >/dev/null
    expected_services='agent ollama warden'
  fi
  running_output=$(compose "$root/releases/$current" ps --status running --services | sort)
  [[ -z "$running_output" ]] || mapfile -t running <<<"$running_output"
  [[ "${running[*]}" == "$expected_services" ]] || die "worker service set is incomplete: ${running[*]}"
}

warden_status() {
  local root=$1 current env_file node_ip
  current=$(current_release "$root")
  [[ -n "$current" ]] || die "no committed release"
  env_file="$root/releases/$current/.env"
  node_ip=$(env_value "$env_file" CANDACEOS_NODE_IP)
  curl --fail --silent --show-error --max-time 3 "http://$node_ip:7717/api/status"
}

image_runtime_fingerprint() {
  local image=${1:-}
  [[ -n "$image" ]] || die "image reference is required"

  docker image inspect "$image" | python3 -c '
import hashlib
import json
import sys

documents = json.load(sys.stdin)
if not isinstance(documents, list) or len(documents) != 1:
    raise SystemExit("image inspect must return exactly one image")

image = documents[0]
rootfs = image.get("RootFS")
config = image.get("Config")
if not isinstance(rootfs, dict):
    raise SystemExit("image has no usable RootFS")
if not isinstance(config, dict):
    raise SystemExit("image has no usable runtime Config")

# Docker save/load can materialize absent optional Config members as explicit
# nulls or their zero values. OCI image execution treats those forms as unset,
# so they must not change the portable runtime fingerprint. Non-empty values
# remain exact, including empty strings nested inside labels or environment.
def config_value_is_unset(value):
    return (
        value is None
        or value == ""
        or value == []
        or value == {}
        or value is False
    )

config = {
    key: value
    for key, value in config.items()
    if not config_value_is_unset(value)
}

layers = rootfs.get("Layers")
if not isinstance(layers, list) or not all(isinstance(layer, str) for layer in layers):
    raise SystemExit("image has invalid RootFS layers")

platform = {}
for source, target in (
    ("Architecture", "architecture"),
    ("Os", "os"),
    ("OsVersion", "os_version"),
    ("Variant", "variant"),
):
    value = image.get(source)
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise SystemExit(f"image has invalid {source}")
    platform[target] = value

rootfs_type = rootfs.get("Type")
if rootfs_type is None:
    rootfs_type = ""
if not isinstance(rootfs_type, str):
    raise SystemExit("image has invalid RootFS type")

payload = {
    "format": "candaceos-runtime-image-v1",
    "platform": platform,
    "rootfs": {
        "type": rootfs_type,
        "layers": layers,
    },
    "config": config,
}
canonical = json.dumps(
    payload,
    ensure_ascii=True,
    sort_keys=True,
    separators=(",", ":"),
).encode("ascii")
print("sha256:" + hashlib.sha256(canonical).hexdigest())
'
}

verify_images() {
  local image expected actual
  shift
  (($# > 0 && $# % 2 == 0)) || die "verify-images requires IMAGE FINGERPRINT pairs"
  while (($#)); do
    image=$1
    expected=$2
    shift 2
    [[ "$expected" =~ ^sha256:[0-9a-f]{64}$ ]] || \
      die "invalid expected runtime fingerprint for $image"
    actual=$(image_runtime_fingerprint "$image") || \
      die "required image is absent or unreadable: $image"
    [[ "$actual" == "$expected" ]] || \
      die "required image $image has runtime fingerprint $actual, expected $expected"
  done
}

release_installed() {
  local root=$1 release_id=$2 target
  target=$(release_dir "$root" "$release_id")
  if [[ -f "$target/.installed" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

legacy_running() {
  {
    docker ps --filter label=com.docker.compose.project=candaceos --format '{{.Names}}'
    docker ps --filter name='^/candaceos-updater$' --format '{{.Names}}'
  } | awk 'NF && !seen[$0]++' | sort
}

legacy_postgres_container() {
  local output
  local containers=()
  output=$(docker ps \
    --filter label=com.docker.compose.project=candaceos \
    --filter label=com.docker.compose.service=postgres \
    --format '{{.ID}}')
  [[ -z "$output" ]] || mapfile -t containers <<<"$output"
  ((${#containers[@]} == 1)) || die "expected exactly one running legacy PostgreSQL container"
  printf '%s\n' "${containers[0]}"
}

quiesce_legacy() {
  local output name running
  local names=()
  output=$(legacy_running)
  [[ -z "$output" ]] || mapfile -t names <<<"$output"
  ((${#names[@]} == 0)) || docker stop "${names[@]}" >/dev/null
  for name in "${names[@]}"; do
    running=$(docker inspect --format '{{.State.Running}}' "$name")
    [[ "$running" == false ]] || die "legacy container remained running after quiesce: $name"
  done
}

quiesce_legacy_writers() {
  local output name service running
  local names=()
  output=$(legacy_running)
  [[ -z "$output" ]] || mapfile -t names <<<"$output"
  for name in "${names[@]}"; do
    [[ "$name" == candaceos-updater ]] || continue
    docker stop "$name" >/dev/null
  done
  for name in "${names[@]}"; do
    [[ "$name" == candaceos-updater ]] && continue
    service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$name")
    [[ "$service" == postgres ]] && continue
    docker stop "$name" >/dev/null
  done
  for name in "${names[@]}"; do
    running=$(docker inspect --format '{{.State.Running}}' "$name")
    service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$name")
    if [[ "$service" == postgres ]]; then
      [[ "$running" == true ]] || die "legacy PostgreSQL stopped before its final dump"
    else
      [[ "$running" == false ]] || die "legacy writer remained running after quiesce: $name"
    fi
  done
}

legacy_database_dump() {
  local container
  container=$(legacy_postgres_container)
  docker exec "$container" pg_dump -U candaceos -d candaceos --format=custom \
    --no-owner --no-privileges
}

restore_legacy() {
  shift
  local postgres=() updater=() others=() name status service
  for name in "$@"; do
    if [[ "$name" == candaceos-updater ]]; then
      updater+=("$name")
      continue
    fi
    service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$name")
    if [[ "$service" == postgres ]]; then
      postgres+=("$name")
    else
      others+=("$name")
    fi
  done
  ((${#postgres[@]} == 0)) || docker start "${postgres[@]}" >/dev/null
  for name in "${postgres[@]}"; do
    for _ in {1..30}; do
      status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name")
      [[ "$status" == healthy || "$status" == running ]] && break
      sleep 1
    done
    status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name")
    [[ "$status" == healthy || "$status" == running ]] || die "legacy PostgreSQL did not recover"
  done
  ((${#others[@]} == 0)) || docker start "${others[@]}" >/dev/null
  ((${#updater[@]} == 0)) || docker start "${updater[@]}" >/dev/null
}

verify_legacy() {
  shift
  local name state health
  for _ in {1..60}; do
    local ready=true
    for name in "$@"; do
      state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
      health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)
      if [[ "$state" != running || ( "$health" != none && "$health" != healthy ) ]]; then
        ready=false
        break
      fi
    done
    $ready && return 0
    sleep 1
  done
  die "legacy CandaceOS containers did not all return healthy"
}

legacy_copilot_container() {
  local output
  local containers=()
  output=$(docker ps \
    --filter label=com.docker.compose.project=candaceos \
    --filter label=com.docker.compose.service=copilot \
    --format '{{.ID}}')
  [[ -z "$output" ]] || mapfile -t containers <<<"$output"
  ((${#containers[@]} == 1)) || die "expected exactly one running legacy Copilot container"
  printf '%s\n' "${containers[0]}"
}

legacy_workspace() {
  local container
  container=$(legacy_copilot_container)
  docker inspect "$container" | python3 -c 'import json,sys
item=json.load(sys.stdin)[0]
matches=[m.get("Source", "") for m in item.get("Mounts", []) if m.get("Destination") == "/workspace"]
if len(matches) != 1 or not matches[0].startswith("/"):
    raise SystemExit("legacy Copilot has no unique /workspace bind mount")
print(matches[0])'
}

legacy_token() {
  local container
  container=$(legacy_copilot_container)
  docker inspect "$container" | python3 -c 'import json,sys
item=json.load(sys.stdin)[0]
values=[]
for entry in item.get("Config", {}).get("Env", []):
    if entry.startswith("COPILOT_GITHUB_TOKEN="):
        values.append(entry.split("=", 1)[1])
if len(values) != 1 or not values[0]:
    raise SystemExit("legacy Copilot has no non-empty COPILOT_GITHUB_TOKEN")
print(values[0])'
}

bundle_apps() {
  local root=$1 release_id=$2 workspace=$3 incoming head
  validate_release_id "$release_id"
  [[ "$workspace" == /* ]] || die "app workspace must be absolute"
  [[ ! -L "$workspace/.git" ]] || die "app workspace .git must not be a symbolic link"
  [[ "$(git -C "$workspace" rev-parse --show-toplevel 2>/dev/null)" == "$workspace" ]] || \
    die "$workspace is not a standalone Git worktree"
  [[ -z "$(git -C "$workspace" status --porcelain)" ]] || die "$workspace has uncommitted or untracked files"
  head=$(git -C "$workspace" rev-parse HEAD)
  incoming="$root/incoming/$release_id"
  mkdir -p "$incoming"
  git -C "$workspace" bundle create "$incoming/apps.bundle.tmp" --all
  git -C "$workspace" bundle verify "$incoming/apps.bundle.tmp" >/dev/null 2>&1
  [[ "$(git -C "$workspace" rev-parse HEAD)" == "$head" ]] || die "app workspace changed while it was bundled"
  mv "$incoming/apps.bundle.tmp" "$incoming/apps.bundle"
  chmod 600 "$incoming/apps.bundle"
  printf '%s\n' "$head"
}

bundle_legacy_runtime() {
  local root=$1 release_id=$2 workspace=$3 backend=${4:-copilot-cli} state_root incoming
  validate_release_id "$release_id"
  state_root=$(dirname "$workspace")
  incoming="$root/incoming/$release_id"
  mkdir -p "$incoming"
  if [[ ! -d "$state_root/runtime" ]]; then
    printf 'absent\n'
    return 0
  fi
  local names=()
  [[ -d "$state_root/runtime/core" ]] && names+=(core)
  [[ "$backend" != copilot-cli || ! -d "$state_root/runtime/copilot" ]] || names+=(copilot)
  if ((${#names[@]} == 0)); then
    printf 'absent\n'
    return 0
  fi
  tar -czf "$incoming/runtime.tgz.tmp" \
    --exclude='copilot/.cache' --exclude='copilot/.cache/*' \
    --exclude='copilot/logs' --exclude='copilot/logs/*' \
    -C "$state_root/runtime" "${names[@]}"
  mv "$incoming/runtime.tgz.tmp" "$incoming/runtime.tgz"
  chmod 600 "$incoming/runtime.tgz"
  sha256sum "$incoming/runtime.tgz" | awk '{print $1}'
}

app_head() {
  local root=$1 current env_file workspace
  current=$(current_release "$root")
  [[ -n "$current" ]] || die "no committed control release"
  env_file="$root/releases/$current/.env"
  workspace=$(env_value "$env_file" CANDACEOS_HOST_WORKSPACE)
  git -C "$workspace" rev-parse HEAD
}

echo_arguments_for_test() {
  shift
  printf '<%s>\n' "$@"
}

command=${1:-}
root_arg=${2:-.local/share/candaceos-fleet}
root=$(resolve_root "$root_arg")
case "$command" in
  preflight) preflight "$root" ;;
  preflight-ollama) preflight_ollama ;;
  check-ports) check_ports "$root" "${3:-}" "${4:-}" ;;
  check-ollama-port) check_ollama_port "$root" "${3:-}" ;;
  prepare-upload) prepare_upload "$root" "${3:-}" ;;
  install) install_release "$root" "${3:-}" "${4:-}" "${5:-}" ;;
  activate) activate_release "$root" "${3:-}" ;;
  activate-ollama) activate_ollama "$root" "${3:-}" ;;
  verify-ollama-model) verify_ollama_model "${3:-}" "${4:-}" "${5:-}" "${6:-}" ;;
  ollama-model-digest) current_ollama_model_digest "$root" ;;
  activate-control-db) activate_control_database "$root" "${3:-}" ;;
  backup-control-db) backup_control_database "$root" "${3:-}" ;;
  restore-initial-db) restore_initial_database "$root" "${3:-}" ;;
  verify-control-db) verify_control_database "$root" "${3:-}" "${4:-}" ;;
  quiesce-control-writers) quiesce_control_writers "$root" ;;
  resume-control) resume_control "$root" ;;
  commit) commit_release "$root" "${3:-}" ;;
  current) current_release "$root" ;;
  rollback) rollback_release "$root" "${3:-}" "${4:-}" "${5:-manual}" "${6:-}" ;;
  verify-control) verify_control "$root" "${3:-}" ;;
  verify-worker) verify_worker "$root" "${3:-}" "${4:-}" ;;
  image-fingerprint) image_runtime_fingerprint "${3:-}" ;;
  verify-images) verify_images "$root" "${@:3}" ;;
  prepare-image-upload) prepare_image_upload "$root" "${3:-}" ;;
  load-image-archive) load_image_archive "$root" "${3:-}" "${4:-}" ;;
  pull-pinned-image) pull_pinned_image "$root" "${3:-}" "${4:-}" ;;
  release-installed) release_installed "$root" "${3:-}" ;;
  warden-status) warden_status "$root" ;;
  legacy-running) legacy_running ;;
  quiesce-legacy) quiesce_legacy ;;
  quiesce-legacy-writers) quiesce_legacy_writers ;;
  legacy-db-dump) legacy_database_dump ;;
  legacy-db-fingerprint) legacy_database_fingerprint ;;
  restore-legacy) restore_legacy "$root" "${@:3}" ;;
  verify-legacy) verify_legacy "$root" "${@:3}" ;;
  legacy-workspace) legacy_workspace ;;
  legacy-token) legacy_token ;;
  bundle-apps) bundle_apps "$root" "${3:-}" "${4:-}" ;;
  bundle-legacy-runtime) bundle_legacy_runtime "$root" "${3:-}" "${4:-}" "${5:-copilot-cli}" ;;
  app-head) app_head "$root" ;;
  echo-args-for-test) echo_arguments_for_test "$root" "${@:3}" ;;
  *) die "unknown node operation: $command" ;;
esac
