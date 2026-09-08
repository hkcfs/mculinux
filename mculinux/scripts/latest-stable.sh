#!/bin/bash
# Print the latest stable Linux kernel version (e.g. 7.2.4).
# Usage: ./scripts/latest-stable.sh [branch]
#   No arg  -> global latest stable (kernel.org homepage).
#   "7.1"   -> latest 7.1.x stable (releases.json backport lookup).
set -uo pipefail

BRANCH="${1:-}"

if [ -z "$BRANCH" ]; then
    curl -s --max-time 30 https://kernel.org \
        | grep -A 1 'stable:' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n 1
    exit 0
fi

LATEST_STABLE=$(curl -s --max-time 30 https://kernel.org \
    | grep -A 1 'stable:' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | head -n 1)
case "$LATEST_STABLE" in
    "$BRANCH".*) echo "$LATEST_STABLE" ;;
    *) curl -sL --max-time 30 https://www.kernel.org/releases.json \
        | grep -o "\"version\": \"$BRANCH\.[0-9]*\"" \
        | grep -oE '[0-9.]+' | sort -V | tail -1 ;;
esac
