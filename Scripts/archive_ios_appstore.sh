#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scheme="${SCHEME:-Screen Q}"
configuration="${CONFIGURATION:-Release}"
archive_path="${ARCHIVE_PATH:-$repo_root/dist/release/ScreenQ-iOS.xcarchive}"
export_path="${EXPORT_PATH:-$repo_root/dist/release/ios-export}"

usage() {
    cat <<'USAGE'
Archive Screen Q for iOS App Store Connect/TestFlight.

Required environment:
  DEVELOPMENT_TEAM    Apple Developer Team ID

Optional environment:
  SCREENQ_BUNDLE_ID        Registered iOS App ID, defaults to com.chrisizatt.Screen-Q
  ARCHIVE_PATH             Output .xcarchive path
  EXPORT_OPTIONS_PLIST     ExportOptions.plist for App Store export
  EXPORT_PATH              Export destination when EXPORT_OPTIONS_PLIST is set
  ALLOW_PROVISIONING_UPDATES=1  Pass -allowProvisioningUpdates to xcodebuild

Example:
  DEVELOPMENT_TEAM=ABCDE12345 Scripts/archive_ios_appstore.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required environment variable: $name" >&2
        usage >&2
        exit 64
    fi
}

require_env DEVELOPMENT_TEAM

screenq_bundle_id="${SCREENQ_BUNDLE_ID:-com.chrisizatt.Screen-Q}"

if [[ "$screenq_bundle_id" == com.example.* ]]; then
    echo "SCREENQ_BUNDLE_ID must be a registered App Store Connect App ID, not a placeholder." >&2
    exit 64
fi

provisioning_args=()
if [[ "${ALLOW_PROVISIONING_UPDATES:-}" == "1" ]]; then
    provisioning_args+=("-allowProvisioningUpdates")
fi

cd "$repo_root"
Scripts/check_public_release_guards.sh

if [[ -n "${EXPORT_OPTIONS_PLIST:-}" ]]; then
    [[ -f "$EXPORT_OPTIONS_PLIST" ]] || {
        echo "EXPORT_OPTIONS_PLIST does not exist: $EXPORT_OPTIONS_PLIST" >&2
        exit 66
    }
    export_options_dir="$(cd "$(dirname "$EXPORT_OPTIONS_PLIST")" && pwd -P)"
    if [[ "$export_options_dir" == "$repo_root" || "$export_options_dir" == "$repo_root"/* ]]; then
        echo "Keep EXPORT_OPTIONS_PLIST outside the repo because it can contain private signing metadata." >&2
        exit 64
    fi
fi

mkdir -p "$(dirname "$archive_path")"

xcodebuild archive \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -destination "generic/platform=iOS" \
    -archivePath "$archive_path" \
    "${provisioning_args[@]}" \
    SCREENQ_BUNDLE_ID="$screenq_bundle_id" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

SCREENQ_IOS_APP_PATH="$archive_path/Products/Applications/Screen Q.app" \
    Scripts/check_public_release_guards.sh

bridge_binary="$archive_path/Products/Applications/Screen Q.app/Frameworks/ScreenQFreeRDPBridge.framework/ScreenQFreeRDPBridge"
if [[ -f "$bridge_binary" ]]; then
    mkdir -p "$archive_path/dSYMs"
    rm -rf "$archive_path/dSYMs/ScreenQFreeRDPBridge.framework.dSYM"
    /usr/bin/dsymutil "$bridge_binary" -o "$archive_path/dSYMs/ScreenQFreeRDPBridge.framework.dSYM"
fi

SCREENQ_IOS_ARCHIVE_PATH="$archive_path" \
SCREENQ_IOS_APP_PATH="$archive_path/Products/Applications/Screen Q.app" \
    Scripts/check_public_release_guards.sh

if [[ -n "${EXPORT_OPTIONS_PLIST:-}" ]]; then
    mkdir -p "$export_path"
    xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportPath "$export_path" \
        -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
        "${provisioning_args[@]}"
fi

echo "iOS archive ready: $archive_path"
if [[ -n "${EXPORT_OPTIONS_PLIST:-}" ]]; then
    echo "Export output: $export_path"
fi
