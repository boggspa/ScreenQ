#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$repo_root/Screen Q.xcodeproj/project.pbxproj"
public_bundle_id="com.chrisizatt.Screen-Q"

fail() {
    echo "release guard failed: $*" >&2
    exit 1
}

require_file() {
    [[ -f "$repo_root/$1" ]] || fail "missing required file: $1"
}

require_executable() {
    [[ -x "$repo_root/$1" ]] || fail "missing executable bit: $1"
}

assert_not_matching() {
    local pattern="$1"
    local path="$2"
    if grep -Eq "$pattern" "$path"; then
        fail "$path matches forbidden pattern: $pattern"
    fi
}

assert_matching() {
    local pattern="$1"
    local path="$2"
    if ! grep -Eq "$pattern" "$path"; then
        fail "$path does not match required pattern: $pattern"
    fi
}

require_file "LICENSE"
require_file "NOTICE"
require_file "SECURITY.md"
require_file "THIRD-PARTY-NOTICES.md"
require_file "Docs/iOSAppStoreConnectReadiness.md"
require_file "Screen Q/Info.plist"
require_file "Screen Q/Info-macOS.plist"
require_file "Screen Q/PrivacyInfo.xcprivacy"
require_file "Screen Q/Entitlements/ScreenQ-iOS.entitlements"
require_file "Screen Q/Entitlements/ScreenQ-macOS-DeveloperID.entitlements"
require_file "Scripts/archive_ios_appstore.sh"
require_executable "Scripts/archive_ios_appstore.sh"

plutil -lint \
    "$repo_root/Screen Q/Info.plist" \
    "$repo_root/Screen Q/Info-macOS.plist" \
    "$repo_root/Screen Q/PrivacyInfo.xcprivacy" >/dev/null

assert_not_matching 'SUPPORTED_PLATFORMS = .*xros' "$project_file"
assert_not_matching 'SUPPORTED_PLATFORMS = .*xrsimulator' "$project_file"
assert_not_matching 'TARGETED_DEVICE_FAMILY = ".*7' "$project_file"
assert_not_matching 'Embed App Extensions|ScreenQBroadcastExtension\.appex in Embed' "$project_file"
assert_not_matching 'DEVELOPMENT_TEAM =|/Users/[^/" ]+' "$project_file"
assert_not_matching 'CODE_SIGN_ENTITLEMENTS = "Screen Q/Screen Q\.entitlements"' "$project_file"
assert_matching 'CODE_SIGN_ENTITLEMENTS\[sdk=iphoneos\*\].*ScreenQ-iOS\.entitlements' "$project_file"
assert_matching 'CODE_SIGN_ENTITLEMENTS\[sdk=iphonesimulator\*\].*ScreenQ-iOS\.entitlements' "$project_file"
assert_matching 'CODE_SIGN_ENTITLEMENTS\[sdk=macosx\*\].*ScreenQ-macOS-DeveloperID\.entitlements' "$project_file"
assert_matching 'INFOPLIST_FILE = "Screen Q/Info\.plist"' "$project_file"
assert_matching 'INFOPLIST_FILE\[sdk=macosx\*\].*Info-macOS\.plist' "$project_file"

if grep -E 'PRODUCT_BUNDLE_IDENTIFIER|SCREENQ_BUNDLE_ID' "$project_file" \
    | grep -E 'com\.' \
    | grep -Ev "${public_bundle_id//./\\.}" >/dev/null; then
    fail "$project_file contains an unexpected hard-coded bundle identifier"
fi

assert_matching "SCREENQ_BUNDLE_ID = \"${public_bundle_id}\";" "$project_file"
assert_not_matching 'com\.example\.Screen-Q' "$project_file"

assert_matching 'NSCameraUsageDescription' "$repo_root/Screen Q/Info.plist"
assert_not_matching 'LSUIElement' "$repo_root/Screen Q/Info.plist"
assert_matching 'LSUIElement' "$repo_root/Screen Q/Info-macOS.plist"
assert_matching 'NSPrivacyAccessedAPICategoryUserDefaults' "$repo_root/Screen Q/PrivacyInfo.xcprivacy"
assert_matching 'CA92\.1' "$repo_root/Screen Q/PrivacyInfo.xcprivacy"
assert_matching 'NSPrivacyAccessedAPICategoryFileTimestamp' "$repo_root/Screen Q/PrivacyInfo.xcprivacy"
assert_matching 'C617\.1' "$repo_root/Screen Q/PrivacyInfo.xcprivacy"
assert_matching '3B52\.1' "$repo_root/Screen Q/PrivacyInfo.xcprivacy"
assert_matching 'NSPrivacyTracking' "$repo_root/Screen Q/PrivacyInfo.xcprivacy"
assert_matching 'static var defaultRedirectClipboard' "$repo_root/Screen Q/RDP/RDPConnectionProfile.swift"
assert_matching '#if os\(iOS\)' "$repo_root/Screen Q/RDP/RDPConnectionProfile.swift"
assert_matching 'return false' "$repo_root/Screen Q/RDP/RDPConnectionProfile.swift"
assert_matching 'Share clipboard with RDP session' "$repo_root/Screen Q/Views/ManualConnectView.swift"
assert_matching 'profile\.redirectClipboard = rdpClipboardRedirection' "$repo_root/Screen Q/Views/ManualConnectView.swift"
assert_matching 'App Store Connect' "$repo_root/Docs/iOSAppStoreConnectReadiness.md"
assert_matching 'SCREENQ_BUNDLE_ID' "$repo_root/Scripts/archive_ios_appstore.sh"
assert_matching 'DEVELOPMENT_TEAM' "$repo_root/Scripts/archive_ios_appstore.sh"
assert_matching "$public_bundle_id" "$repo_root/Scripts/archive_ios_appstore.sh"
assert_matching 'com\.example\.\*' "$repo_root/Scripts/archive_ios_appstore.sh"
assert_matching 'MinimumOSVersion' "$repo_root/Scripts/embed_freerdp_ios_bridge.sh"
assert_matching 'ScreenQFreeRDPBridge\.framework\.dSYM' "$repo_root/Scripts/archive_ios_appstore.sh"
assert_matching 'ScreenQFreeRDPBridge\.framework\.dSYM' "$repo_root/Scripts/build_freerdp_ios_xcframework.sh"

assert_matching 'com\.apple\.developer\.ubiquity-kvstore-identifier' "$repo_root/Screen Q/Entitlements/ScreenQ-iOS.entitlements"
assert_not_matching 'com\.apple\.developer\.ubiquity-kvstore-identifier' "$repo_root/Screen Q/Entitlements/ScreenQ-macOS-DeveloperID.entitlements"
assert_not_matching 'com\.apple\.security\.network\.' "$repo_root/Screen Q/Entitlements/ScreenQ-iOS.entitlements"

assert_matching 'defaultBroadcastExtensionBundleID: String\? = nil' "$repo_root/Screen Q/IOSHost/ReplayKitBroadcastModel.swift"
assert_matching '#if DEBUG' "$repo_root/Screen Q/Models/PermissionSet.swift"
assert_matching '#if DEBUG' "$repo_root/Screen Q/MacHost/MacHostRuntime.swift"
assert_matching '#if DEBUG' "$repo_root/Screen Q/Views/RemoteScreenView.swift"
assert_matching 'case \.remoteCommand, \.systemAction, \.systemReportRequest, \.packageInstallReq:' "$repo_root/Screen Q/MacHost/MacHostRuntime.swift"
assert_matching 'case \.commandOutput, \.systemActionResult, \.systemReport, \.packageInstallResult:' "$repo_root/Screen Q/Views/RemoteScreenView.swift"

if git -C "$repo_root" ls-files | grep -Eq '(^|/)xcuserdata/|\.xcuserdatad/|\.xcuserstate$|xcschememanagement\.plist$'; then
    fail "Xcode user-specific state is tracked"
fi

while IFS= read -r -d '' icon_path; do
    if sips -g hasAlpha "$icon_path" 2>/dev/null | grep -q 'hasAlpha: yes'; then
        fail "$icon_path has an alpha channel"
    fi
done < <(find "$repo_root/Screen Q/Assets.xcassets/AppIcon.appiconset" -name '*.png' -print0)

check_app_bundle() {
    local app_path="$1"
    local label="$2"
    [[ -d "$app_path" ]] || return 0

    if find "$app_path" -maxdepth 5 -name "ScreenQBroadcastExtension.appex" -print -quit | grep -q .; then
        fail "$label embeds ScreenQBroadcastExtension.appex"
    fi

    if [[ "$label" == "iOS app" ]]; then
        [[ -f "$app_path/PrivacyInfo.xcprivacy" ]] || fail "$label is missing PrivacyInfo.xcprivacy"
        /usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$app_path/Info.plist" >/dev/null \
            || fail "$label is missing NSCameraUsageDescription"
        if /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$app_path/Info.plist" >/dev/null 2>&1; then
            fail "$label contains macOS-only LSUIElement"
        fi

        local bridge_plist="$app_path/Frameworks/ScreenQFreeRDPBridge.framework/Info.plist"
        if [[ -f "$bridge_plist" ]]; then
            local bridge_minimum_os
            bridge_minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$bridge_plist" 2>/dev/null || true)"
            [[ -n "$bridge_minimum_os" ]] || fail "$label ScreenQFreeRDPBridge.framework is missing MinimumOSVersion"
        fi
    fi

    if [[ "$label" == "macOS app" ]]; then
        /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$app_path/Contents/Info.plist" >/dev/null \
            || fail "$label is missing LSUIElement"
    fi
}

check_app_bundle "${SCREENQ_IOS_APP_PATH:-}" "iOS app"
check_app_bundle "${SCREENQ_MAC_APP_PATH:-}" "macOS app"

if [[ -n "${SCREENQ_IOS_ARCHIVE_PATH:-}" && -d "${SCREENQ_IOS_ARCHIVE_PATH:-}" ]]; then
    archive_app="${SCREENQ_IOS_ARCHIVE_PATH}/Products/Applications/Screen Q.app"
    archive_bridge="${archive_app}/Frameworks/ScreenQFreeRDPBridge.framework/ScreenQFreeRDPBridge"
    archive_bridge_dsym="${SCREENQ_IOS_ARCHIVE_PATH}/dSYMs/ScreenQFreeRDPBridge.framework.dSYM"
    if [[ -f "$archive_bridge" ]]; then
        [[ -d "$archive_bridge_dsym" ]] || fail "iOS archive is missing ScreenQFreeRDPBridge.framework.dSYM"
        archive_bridge_uuid="$(dwarfdump --uuid "$archive_bridge" | awk 'NR == 1 { print $2 }')"
        archive_dsym_uuid="$(dwarfdump --uuid "$archive_bridge_dsym" | awk 'NR == 1 { print $2 }')"
        [[ -n "$archive_bridge_uuid" && "$archive_bridge_uuid" == "$archive_dsym_uuid" ]] \
            || fail "iOS archive ScreenQFreeRDPBridge.framework.dSYM UUID does not match embedded framework"
    fi
fi

echo "Public release guards passed."
