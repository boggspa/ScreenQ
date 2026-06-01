#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$repo_root/Screen Q.xcodeproj/project.pbxproj"

fail() {
    echo "release guard failed: $*" >&2
    exit 1
}

require_file() {
    [[ -f "$repo_root/$1" ]] || fail "missing required file: $1"
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
require_file "Screen Q/Entitlements/ScreenQ-iOS.entitlements"
require_file "Screen Q/Entitlements/ScreenQ-macOS-DeveloperID.entitlements"

assert_not_matching 'SUPPORTED_PLATFORMS = .*xros' "$project_file"
assert_not_matching 'SUPPORTED_PLATFORMS = .*xrsimulator' "$project_file"
assert_not_matching 'TARGETED_DEVICE_FAMILY = ".*7' "$project_file"
assert_not_matching 'Embed App Extensions|ScreenQBroadcastExtension\.appex in Embed' "$project_file"
assert_not_matching 'DEVELOPMENT_TEAM =|8CZML8FK2D|/Users/chrisizatt|com\.chrisizatt' "$project_file"
assert_not_matching 'CODE_SIGN_ENTITLEMENTS = "Screen Q/Screen Q\.entitlements"' "$project_file"
assert_matching 'CODE_SIGN_ENTITLEMENTS\[sdk=iphoneos\*\].*ScreenQ-iOS\.entitlements' "$project_file"
assert_matching 'CODE_SIGN_ENTITLEMENTS\[sdk=iphonesimulator\*\].*ScreenQ-iOS\.entitlements' "$project_file"
assert_matching 'CODE_SIGN_ENTITLEMENTS\[sdk=macosx\*\].*ScreenQ-macOS-DeveloperID\.entitlements' "$project_file"

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

check_app_bundle() {
    local app_path="$1"
    local label="$2"
    [[ -d "$app_path" ]] || return 0

    if find "$app_path" -maxdepth 5 -name "ScreenQBroadcastExtension.appex" -print -quit | grep -q .; then
        fail "$label embeds ScreenQBroadcastExtension.appex"
    fi
}

check_app_bundle "${SCREENQ_IOS_APP_PATH:-}" "iOS app"
check_app_bundle "${SCREENQ_MAC_APP_PATH:-}" "macOS app"

echo "Public release guards passed."
