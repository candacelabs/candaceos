#!/usr/bin/env bash
set -Eeuo pipefail

copilot_version=1.0.80
copilot_archive_sha256=039933c9247686131c4406abb1d439bdbf68103edc1ff585bd70d5b0dc940f72
copilot_binary_sha256=2ebb491db8bbbad58fb111a34b3f92798da44341976e5a6021bc13c7e57ae9e6
copilot_archive_url=https://github.com/github/copilot-cli/releases/download/v${copilot_version}/copilot-linux-x64.tar.gz

die() {
  printf 'candaceos Copilot installer: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./install-copilot.sh [STATE_ROOT]

Reuse the exact official Copilot CLI from PATH when available, or checksum-
install it into digest-addressed CandaceOS state. STATE_ROOT defaults to
CANDACEOS_STATE_ROOT, then ~/.local/share/candaceos.

The script prints the binary path and SHA-256 as KEY=value metadata. It never
stores a GitHub credential and does not install packages or change the host.
EOF
}

valid_copilot_binary() {
  local candidate=$1
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] || return 1
  [[ "$(sha256sum "$candidate" | awk '{print $1}')" == "$copilot_binary_sha256" ]]
}

resolve_root() {
  local requested=$1 resolved
  if [[ "$requested" == /* ]]; then
    resolved=$(realpath -m -- "$requested")
  else
    resolved=$(realpath -m -- "$HOME/$requested")
    [[ "$resolved" == "$HOME/"* ]] || die "relative state root escaped the invoking user's home directory"
  fi
  [[ "$resolved" != / && "$resolved" != "$HOME" ]] || die "state root is too broad: $resolved"
  printf '%s\n' "$resolved"
}

install_copilot() {
  local root=$1 directory destination legacy ambient source stage archive extracted temporary
  [[ "$(uname -s)" == Linux ]] || die "Linux is required"
  [[ "$(uname -m)" == x86_64 ]] || die "the pinned Copilot CLI supports Linux x86_64 only"
  for command in curl install mktemp realpath sha256sum tar; do
    command -v "$command" >/dev/null || die "$command is required"
  done

  directory="$root/tools/copilot/$copilot_version/$copilot_binary_sha256"
  destination="$directory/copilot"
  if ! valid_copilot_binary "$destination"; then
    [[ ! -L "$root" ]] || die "state root must not be a symbolic link"
    mkdir -p "$directory"
    chmod 700 "$root/tools" "$root/tools/copilot" \
      "$root/tools/copilot/$copilot_version" "$directory"
    stage=$(mktemp -d "$directory/.install.XXXXXX")
    trap 'rm -rf -- "$stage"' RETURN
    extracted="$stage/copilot"
    legacy="$root/tools/copilot/$copilot_version/copilot"
    ambient=$(command -v copilot 2>/dev/null || true)
    source=
    if valid_copilot_binary "$legacy"; then
      source=$legacy
    elif [[ -n "$ambient" ]] && valid_copilot_binary "$(realpath -- "$ambient")"; then
      source=$(realpath -- "$ambient")
    fi
    if [[ -n "$source" ]]; then
      install -m 0555 "$source" "$extracted"
    else
      archive="$stage/copilot.tar.gz"
      env -u COPILOT_GITHUB_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
        curl --fail --location --silent --show-error --output "$archive" "$copilot_archive_url"
      [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$copilot_archive_sha256" ]] || \
        die "downloaded Copilot CLI archive checksum mismatch"
      tar -xzf "$archive" -C "$stage" copilot
      chmod 0555 "$extracted"
    fi
    valid_copilot_binary "$extracted" || die "installed Copilot CLI binary failed verification"
    temporary="$directory/.copilot.$$.tmp"
    install -m 0555 "$extracted" "$temporary"
    mv -f "$temporary" "$destination"
    trap - RETURN
    rm -rf -- "$stage"
  fi

  printf 'CANDACEOS_COPILOT_BIN=%s\n' "$destination"
  printf 'CANDACEOS_COPILOT_SHA256=%s\n' "$copilot_binary_sha256"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
(($# <= 1)) || { usage >&2; die "expected at most one STATE_ROOT"; }
requested_root=${1:-${CANDACEOS_STATE_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/candaceos}}
install_copilot "$(resolve_root "$requested_root")"
