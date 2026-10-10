#!/bin/bash
set -euo pipefail

# macOS/AppKit only; no Homebrew, Python image library, or network dependency.
script_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="${TMPDIR:-/tmp}/vektor-app-store-tools-${UID}"
mkdir -p "$build_dir/module-cache"
source_file="$script_dir/RenderScreenshots.swift"
binary_file="$build_dir/render-screenshots"
if [[ ! -x "$binary_file" || "$source_file" -nt "$binary_file" ]]; then
    xcrun swiftc -O -module-cache-path "$build_dir/module-cache" \
        "$source_file" -o "$binary_file"
fi
exec "$binary_file" "$@"
