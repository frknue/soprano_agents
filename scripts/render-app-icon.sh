#!/bin/bash
# Renders the Soprano Agents app icon (the `agents` glyph of scripts/render-app-icon.swift, this
# repo's own copy of Soprano's renderer) and writes Sources/SopranoAgents/Resources/AppIcon.icns.
# Usage: render-app-icon.sh [png-output]
# The optional argument keeps a copy of the 1024×1024 render at that path.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [png-output]" >&2
    exit 2
fi

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
icns_path="$repo_root/Sources/SopranoAgents/Resources/AppIcon.icns"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/soprano-agents-icon.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

iconset="$work_dir/AppIcon.iconset"
swift "$script_dir/render-app-icon.swift" agents "$iconset"

staged_icns="$work_dir/AppIcon.icns"
/usr/bin/iconutil -c icns -o "$staged_icns" "$iconset"
mv -f "$staged_icns" "$icns_path"
echo "Wrote $icns_path"

if [[ $# -eq 1 ]]; then
    mkdir -p "$(dirname "$1")"
    cp "$iconset/icon_512x512@2x.png" "$1"
    echo "Wrote $1"
fi
