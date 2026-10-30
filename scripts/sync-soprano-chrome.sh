#!/bin/bash
set -euo pipefail

# Copies Soprano's design system and shared infrastructure into this repo.
# Soprano is the source of truth: never edit the files under
# Sources/SopranoAgents/Vendored/ here. Change them in Soprano, commit there, then
# re-run this script.
#
# Usage: scripts/sync-soprano-chrome.sh [soprano-checkout] [ref]
#   soprano-checkout  absolute path; defaults to $SOPRANO_DIR or ~/git/private/soprano
#   ref               commit-ish; defaults to HEAD. Files come from that commit,
#                     so uncommitted work in the Soprano checkout is never copied.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
soprano_dir="${1:-${SOPRANO_DIR:-$HOME/git/private/soprano}}"
ref="${2:-HEAD}"

if [[ "$soprano_dir" != /* ]]; then
    echo "The Soprano checkout must be an absolute path: $soprano_dir" >&2
    exit 1
fi
if ! git -C "$soprano_dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "No commit '$ref' in Soprano checkout $soprano_dir" >&2
    exit 1
fi
commit="$(git -C "$soprano_dir" rev-parse "$ref^{commit}")"

# source path in Soprano  →  destination path in this repo
files=(
    "Sources/Soprano/Views/Chrome.swift|Sources/SopranoAgents/Vendored/Chrome.swift"
    "Sources/Soprano/Config/Theme.swift|Sources/SopranoAgents/Vendored/Theme.swift"
    "Sources/Soprano/Utilities/NSColor+Hex.swift|Sources/SopranoAgents/Vendored/NSColor+Hex.swift"
    "Sources/Soprano/Controllers/ThemeManager.swift|Sources/SopranoAgents/Vendored/ThemeManager.swift"
    "Sources/Soprano/Models/KeyBinding.swift|Sources/SopranoAgents/Vendored/KeyBinding.swift"
    "Sources/Soprano/Config/KeyChord.swift|Sources/SopranoAgents/Vendored/KeyChord.swift"
    "Sources/Soprano/Config/JSONCText.swift|Sources/SopranoAgents/Vendored/JSONCText.swift"
    "Sources/Soprano/Views/CommandPalettePanel.swift|Sources/SopranoAgents/Vendored/CommandPalettePanel.swift"
    "Sources/Soprano/Controllers/FileSystemWatcher.swift|Sources/SopranoAgents/Vendored/FileSystemWatcher.swift"
    "Sources/Soprano/Utilities/AppVersion.swift|Sources/SopranoAgents/Vendored/AppVersion.swift"
    "Sources/Soprano/Views/CodeSyntaxHighlighter.swift|Sources/SopranoAgents/Vendored/CodeSyntaxHighlighter.swift"
    "Sources/Soprano/App/MainWindowSizing.swift|Sources/SopranoAgents/Vendored/MainWindowSizing.swift"
)

staging="$(mktemp -d)"
cleanup() { rm -rf "$staging"; }
trap cleanup EXIT

# Stage everything first so a missing file leaves the repo untouched.
for entry in "${files[@]}"; do
    source_path="${entry%%|*}"
    staged="$staging/${entry##*|}"
    mkdir -p "$(dirname "$staged")"
    if ! git -C "$soprano_dir" show "$commit:$source_path" >"$staged"; then
        echo "Soprano $commit has no $source_path" >&2
        exit 1
    fi
done

for entry in "${files[@]}"; do
    destination="$root/${entry##*|}"
    mkdir -p "$(dirname "$destination")"
    mv "$staging/${entry##*|}" "$destination"
done

printf '%s\n' "$commit" >"$root/Sources/SopranoAgents/Vendored/SOPRANO_COMMIT"
printf 'Synced %d files from Soprano %s\n' "${#files[@]}" "$commit"
