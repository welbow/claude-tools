#!/bin/bash
# install.sh - install the bao-* admin commands on the OpenBao Docker host (as root).
#   ./install.sh [dest]        dest defaults to /root/bin
# Also how upgrades work: pull/copy the new version, review, run again.
# Refuses uncommitted changes when run from a git checkout; records the commit in
# <dest>/.bao-tools-version. Config: ./bao-tools -> /etc/default/bao-tools (0644).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")"
DEST=${1:-/root/bin}

if [ ! -f bao-tools ] && [ ! -f /etc/default/bao-tools ]; then
    echo "missing config: copy bao-tools.example to bao-tools and fill it in" >&2
    exit 1
fi

VERSION="unknown (not a git checkout)"
git() { command git -c safe.directory="$PWD" "$@"; }   # checkout may belong to another user
if git rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git status --porcelain -- .)" ]; then
        echo "uncommitted changes here - commit first:" >&2
        git status --short -- . >&2
        exit 1
    fi
    VERSION=$(git log -1 --format='%h %cs %s')
fi

install -d -m 0755 "$DEST"
install -m 0755 -o root -g root bao bao-login bao-logout bao-approve "$DEST/"
[ -f bao-tools ] && install -m 0644 -o root -g root bao-tools /etc/default/bao-tools
echo "$VERSION" > "$DEST/.bao-tools-version"
echo "installed $VERSION -> $DEST"
