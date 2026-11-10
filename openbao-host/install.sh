#!/bin/bash
# install.sh - install the bao-* admin commands on the OpenBao Docker host (as root).
#   ./install.sh [dest]        dest defaults to /root/bin
#
# Run it from a ROOT-OWNED clone (e.g. /root/src/claude-tools). It refuses a
# checkout any other user can write to, since that user could change what root
# installs (or plant git config that runs as root). Upgrade = as root:
#   git -C /root/src/claude-tools pull && /root/src/claude-tools/openbao-host/install.sh
# Shows the commits since the last install and asks before installing; records
# the commit in <dest>/.bao-tools-version. Config: ./bao-tools if present, else
# the existing /etc/default/bao-tools.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")"
TOP=$(cd .. && pwd)
DEST=${1:-/root/bin}
VERFILE="$DEST/.bao-tools-version"

die() { echo "$*" >&2; exit 1; }

[ -d "$TOP/.git" ] || die "$TOP is not a git checkout - install from a clone"
other=$(find "$TOP" ! -user root -print -quit)
[ -z "$other" ] || die "checkout is not root-owned ($other) - another user could change what root installs.
Clone as root instead, e.g.:  git clone <repo-url> /root/src/claude-tools"
[ -f bao-tools ] || [ -f /etc/default/bao-tools ] || die "missing config: copy bao-tools.example to bao-tools and fill it in"

git() { command git -C "$TOP" --no-pager "$@"; }
[ -z "$(git status --porcelain -- openbao-host)" ] || { git status --short -- openbao-host >&2; die "uncommitted changes - commit first"; }

NEW=$(git log -1 --format='%h %cs %s')
OLD=$(cut -d' ' -f1 "$VERFILE" 2>/dev/null || true)
echo "Installing: $NEW"
if [ -n "$OLD" ] && git cat-file -e "$OLD^{commit}" 2>/dev/null; then
    echo "Installed:  $(cat "$VERFILE")"
    echo "Changes to openbao-host/ since then:"
    git log --oneline "$OLD..HEAD" -- openbao-host | sed 's/^/  /'
    git diff --stat "$OLD" HEAD -- openbao-host | sed 's/^/  /'
else
    echo "Installed:  ${OLD:-nothing recorded} (no diff available)"
fi
read -rp "Install? [y/N] " a
case "$a" in y|Y|yes) ;; *) die "not installed" ;; esac

install -d -m 0755 "$DEST"
install -m 0755 -o root -g root bao bao-login bao-logout bao-approve "$DEST/"
[ -f bao-tools ] && install -m 0644 -o root -g root bao-tools /etc/default/bao-tools
echo "$NEW" > "$VERFILE"
echo "installed $NEW -> $DEST"
