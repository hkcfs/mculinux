#!/bin/bash
# Print the latest stable busybox version (e.g. 1.38.0).
# Resolves via git tags across several remotes (busybox.net downloads are
# unreliable); takes the max over ALL remotes (some mirrors go stale).
# Falls back to the last known-good version so builds never hard-fail
# on resolution alone.
# Usage: ./scripts/latest-busybox.sh
set -uo pipefail

FALLBACK="1.38.0"
REMOTES=(
  "git://git.busybox.net/busybox"
  "https://git.busybox.net/busybox"
  "https://github.com/mirror/busybox"
)

ALL_TAGS=""
for remote in "${REMOTES[@]}"; do
    tags="$(timeout 20 git ls-remote --tags "$remote" 2>/dev/null \
        | grep -oE 'refs/tags/[0-9]+_[0-9]+_[0-9]+$' \
        | sed 's|refs/tags/||; s|_|.|g' || true)"
    ALL_TAGS="$ALL_TAGS $tags"
done

LATEST="$(echo "$ALL_TAGS" | tr ' ' '\n' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -uV | tail -1 || true)"

if [ -n "$LATEST" ]; then
    echo "$LATEST"
else
    echo "WARN: could not resolve latest busybox from git, using $FALLBACK" >&2
    echo "$FALLBACK"
fi
