#!/bin/sh
set -eu

die() {
  printf 'candaceos source: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  serve)
    [ "$#" -eq 2 ] || die "usage: candaceos-source serve REPOSITORY"
    repository=$2
    [ -d "$repository" ] || die "repository does not exist: $repository"
    exec git daemon --reuseaddr --verbose --export-all --base-path=/srv/git \
      --listen=0.0.0.0 --port=9418 "$repository"
    ;;
  health-serve)
    [ "$#" -eq 2 ] || exit 1
    git ls-remote "$2" HEAD >/dev/null
    ;;
  *)
    die "expected serve or health-serve"
    ;;
esac
