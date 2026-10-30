#!/bin/bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <debug|release> <absolute output.app> <bundle-id> <bundle-name>" >&2
    exit 2
fi

configuration="$1"
output_app="$2"
bundle_identifier="$3"
bundle_name="$4"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Unsupported build configuration: $configuration" >&2
    exit 2
fi

if [[ "$output_app" != /* || "$output_app" != *.app ]]; then
    echo "The output must be an absolute .app path: $output_app" >&2
    exit 2
fi

if [[ -z "$bundle_identifier" || -z "$bundle_name" ]]; then
    echo "The bundle identifier and bundle name must not be empty." >&2
    exit 2
fi

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_dir="$repo_root/.build/$configuration"
output_parent="$(dirname "$output_app")"

binary_path="$build_dir/SopranoAgents"
resource_bundle="$build_dir/SopranoAgents_SopranoAgents.bundle"
info_plist="$repo_root/Support/Info.plist"
app_icon="$repo_root/Sources/SopranoAgents/Resources/AppIcon.icns"
app_license="$repo_root/LICENSE"

for required_path in "$binary_path" "$resource_bundle" "$info_plist" "$app_icon" "$app_license"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Missing packaging input: $required_path" >&2
        exit 1
    fi
done

mkdir -p "$output_parent"
stage_dir="$(mktemp -d "$output_parent/.soprano-agents-package.XXXXXX")"
staged_app="$stage_dir/$(basename "$output_app")"
previous_app="$stage_dir/previous.app"

cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_path" "$staged_app/Contents/MacOS/SopranoAgents"
cp "$info_plist" "$staged_app/Contents/Info.plist"
cp "$app_icon" "$staged_app/Contents/Resources/AppIcon.icns"
cp "$app_license" "$staged_app/Contents/Resources/LICENSE"
cp -R "$resource_bundle" "$staged_app/Contents/Resources/SopranoAgents_SopranoAgents.bundle"

# One Info.plist serves every flavour; the caller picks the identity of this build.
staged_plist="$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$staged_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $bundle_name" "$staged_plist"
if /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$staged_plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $bundle_name" "$staged_plist"
else
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $bundle_name" "$staged_plist"
fi

"$script_dir/sign-app.sh" "$staged_app"

# Swap the signed app in; if that fails, put the previous app back.
if [[ -e "$output_app" ]]; then
    mv "$output_app" "$previous_app"
fi

if ! mv "$staged_app" "$output_app"; then
    if [[ -e "$previous_app" ]]; then
        mv "$previous_app" "$output_app"
    fi
    exit 1
fi
