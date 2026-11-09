#!/usr/bin/env bash
# Read-only Tandoor API helper. Always issues a GET (curl -G) - no -X override
# is possible, so this script can never mutate the instance. Safe to auto-approve.
#
# Usage: tandoor-get.sh <api-path> [key=value ...]
#   tandoor-get.sh /api/food/ query=rum
#   tandoor-get.sh /api/recipe/6/
#
# Creds come from OpenBao kv/claude/tandoor-ro (fields url, token) via
# claude-secret (installed next to this script's directory, in ../bin/).
# The read-write token is gated; until a read-scope token exists as
# tandoor-ro, this script fails on purpose.
set -euo pipefail

S="$(cd "$(dirname "$0")/.." && pwd)/bin/claude-secret"
if ! "$S" list | grep -qx 'tandoor-ro'; then
  echo "tandoor-get: no kv/claude/tandoor-ro in OpenBao yet - a read-scope Tandoor token is needed (the rw one is gated)" >&2
  exit 2
fi
TANDOOR_URL=$("$S" get tandoor-ro url)

API_PATH="$1"
shift

ARGS=()
for kv in "$@"; do
  ARGS+=(--data-urlencode "$kv")
done

# token goes to curl on stdin (-K -), never on the command line
printf 'header = "Authorization: Bearer %s"\n' "$("$S" get tandoor-ro token)" |
  curl -s -G -K - "${TANDOOR_URL}${API_PATH}" "${ARGS[@]}"
