#!/usr/bin/env bash
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
xcframework="${SCREENQ_FREERDP_XCFRAMEWORK:-$repo_root/.build/ScreenQFreeRDPBridge-iOS/dist/ScreenQFreeRDPBridge.xcframework}"
macos_dylib="${SCREENQ_FREERDP_MAC_DYLIB:-$repo_root/.build/ScreenQFreeRDPBridge/dist/libScreenQFreeRDPBridge.dylib}"

if [[ "${PLATFORM_NAME:-}" == macosx ]]; then
    destination_dir="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
    destination_dylib="$destination_dir/libScreenQFreeRDPBridge.dylib"
    mkdir -p "$destination_dir"
    rm -rf "$destination_dir/ScreenQFreeRDPBridge.framework"

    if [[ ! -f "$macos_dylib" ]]; then
        rm -f "$destination_dylib"
        echo "macOS libScreenQFreeRDPBridge.dylib not found; skipping optional RDP bridge embed. Run Scripts/build_freerdp_bridge.sh first."
        exit 0
    fi

    cp "$macos_dylib" "$destination_dylib"
    if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$destination_dylib"
    fi

    echo "Embedded $destination_dylib"
    exit 0
fi

if [[ ! -d "$xcframework" ]]; then
    echo "ScreenQFreeRDPBridge.xcframework not found; skipping optional RDP bridge embed."
    exit 0
fi

case "${PLATFORM_NAME:-}" in
    iphoneos)
        slice_dir="$xcframework/ios-arm64"
        ;;
    iphonesimulator)
        slice_dir="$xcframework/ios-arm64-simulator"
        ;;
    *)
        exit 0
        ;;
esac

source_framework="$slice_dir/ScreenQFreeRDPBridge.framework"
if [[ ! -d "$source_framework" ]]; then
    echo "No matching ScreenQFreeRDPBridge.framework slice for $PLATFORM_NAME at $source_framework" >&2
    exit 1
fi

destination_dir="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
destination_framework="$destination_dir/ScreenQFreeRDPBridge.framework"
mkdir -p "$destination_dir"
rm -rf "$destination_framework"
rm -f "$destination_dir/libScreenQFreeRDPBridge.dylib"
cp -R "$source_framework" "$destination_framework"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements "$destination_framework"
fi

echo "Embedded $destination_framework"
