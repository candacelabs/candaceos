#!/usr/bin/env bash
set -euo pipefail

[[ ${1:-} == get ]] || exit 1
command -v python3 >/dev/null 2>&1 || exit 1

python3 -c '
import json
import sys
from urllib.parse import urlsplit

try:
    uri = json.load(sys.stdin)["uri"]
    parsed = urlsplit(uri)
    accepted = (
        parsed.scheme == "https"
        and parsed.hostname == "api.github.com"
        and parsed.username is None
        and parsed.password is None
        and parsed.port in (None, 443)
    )
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    accepted = False

raise SystemExit(0 if accepted else 1)
' >/dev/null 2>&1 || exit 1

[[ -z ${CANDACEOS_SDK_GITHUB_TOKEN:-} && \
  -z ${GH_TOKEN:-} && \
  -z ${GITHUB_TOKEN:-} ]] || exit 1

token_file=${CANDACEOS_SDK_GITHUB_TOKEN_FILE:-}
if [[ -n "$token_file" ]]; then
  [[ "$token_file" == /* && -f "$token_file" && ! -L "$token_file" ]] || exit 1
  command -v stat >/dev/null 2>&1 || exit 1
  permissions="$(stat -Lc '%a' -- "$token_file" 2>/dev/null)" || exit 1
  [[ "$permissions" == 600 ]] || exit 1
  token="$(<"$token_file")"
else
  command -v gh >/dev/null 2>&1 || exit 1
  token="$(gh auth token --hostname github.com 2>/dev/null)" || exit 1
fi
[[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || exit 1

printf '%s' "$token" | python3 -c '
import json
import sys

token = sys.stdin.read()

print(json.dumps({
    "headers": {
        "Authorization": ["Bearer " + token],
        "Accept": ["application/octet-stream"],
        "X-GitHub-Api-Version": ["2022-11-28"],
    },
}, separators=(",", ":")))
'
