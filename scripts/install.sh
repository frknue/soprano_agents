#!/bin/bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
install_root="${SOPRANO_AGENTS_INSTALL_DIR:-/Applications}"

if [[ "$install_root" != /* || "$install_root" == "/" ]]; then
    echo "SOPRANO_AGENTS_INSTALL_DIR must be an absolute directory other than /." >&2
    exit 2
fi

echo "Building Soprano Agents for release..."
cd "$repo_root"
swift build -c release

installed_app="$install_root/Soprano Agents.app"
"$script_dir/package-app.sh" \
    release \
    "$installed_app" \
    "com.soprano.agents" \
    "Soprano Agents"

echo "Installed Soprano Agents at $installed_app"
echo "The running app was not restarted; the update takes effect on its next launch."
