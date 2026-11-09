#!/usr/bin/env bash
# Read-only Tandoor metadata cache refresh. Pulls ALL foods/units/keywords
# (paginating past the server's 200-per-page cap) in one shot and writes each
# as a flat JSON array to the cache dir, so ingredient lookups can grep the
# cache locally instead of making a round of individual API calls per recipe.
# GET-only (fetch(), no method override possible) - safe to auto-approve.
#
# Usage: tandoor-refresh-cache.sh
# Creds: OpenBao kv/claude/tandoor-ro (fields url, token) via claude-secret.
# Cache dir: TANDOOR_CACHE_DIR in ../bin/claude-tools.env, default ~/.tandoor-cache.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/bin/claude-secret"
CONF="$ROOT/bin/claude-tools.env"
CACHE_DIR=$(grep -m1 '^TANDOOR_CACHE_DIR=' "$CONF" 2>/dev/null | cut -d= -f2- | tr -d '\r"' || true)
# Git Bash's $HOME can point at the wrong profile - use USERPROFILE
CACHE_DIR=${CACHE_DIR:-$(cygpath "$USERPROFILE")/.tandoor-cache}

if ! "$S" list | grep -qx 'tandoor-ro'; then
  echo "tandoor-refresh-cache: no kv/claude/tandoor-ro in OpenBao yet - a read-scope Tandoor token is needed (the rw one is gated)" >&2
  exit 2
fi
TANDOOR_URL=$("$S" get tandoor-ro url)

mkdir -p "$CACHE_DIR"

for resource in food unit keyword; do
  # token via the environment, not argv, so it never shows in a process list
  TANDOOR_TOKEN=$("$S" get tandoor-ro token) node -e '
    const [base, resource, outPath] = process.argv.slice(1);
    const token = process.env.TANDOOR_TOKEN;
    (async () => {
      let url = `${base}/api/${resource}/?page_size=200`;
      let results = [];
      while (url) {
        const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
        const data = await res.json();
        results = results.concat(data.results);
        url = data.next;
      }
      require("fs").writeFileSync(outPath, JSON.stringify(results));
      console.log(`wrote ${outPath} (${results.length} items)`);
    })();
  ' "$TANDOOR_URL" "$resource" "$CACHE_DIR/${resource}.json"
done

date +"%Y-%m-%dT%H:%M:%S%z" > "$CACHE_DIR/last_refreshed.txt"
echo "Cache refreshed at $(cat "$CACHE_DIR/last_refreshed.txt")"
