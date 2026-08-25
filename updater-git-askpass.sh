#!/usr/bin/env sh
set -eu

case "${1:-}" in
  *Username*) printf '%s\n' x-access-token ;;
  *Password*) cat "${CANDACEOS_GITHUB_TOKEN_FILE:?}" ;;
  *) exit 1 ;;
esac
