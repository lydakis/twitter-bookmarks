#!/usr/bin/env bash
# Twitter Bookmarks Export Tool
# Usage: twitter-bookmarks-extract [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_DIR="${SCRIPT_DIR}/../cli"

cd "${CLI_DIR}"

# Build if needed
if [[ ! -f .build/debug/twitter-bookmarks ]]; then
    echo "Building Twitter Bookmarks CLI..."
    swift build
fi

# Run with all arguments passed through
exec swift run twitter-bookmarks "$@"
