#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat >&2 <<'USAGE'
Usage:
  Scripts/notarize_release.sh --app "/path/to/Screen Q.app" --keychain-profile PROFILE [--sbom path]

Runs the release hardening checks for a macOS app bundle:
  1. Verifies the app and embedded dependencies are signed.
  2. Generates a CycloneDX SBOM.
  3. Creates a notarization zip.
  4. Submits with xcrun notarytool using a stored keychain profile.
  5. Staples and assesses the notarized app.

Create the notary profile once with:
  xcrun notarytool store-credentials PROFILE --apple-id EMAIL --team-id TEAMID --password APP_SPECIFIC_PASSWORD
USAGE
    exit 64
}

app_path=""
keychain_profile=""
sbom_path=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            app_path="${2:-}"
            shift 2
            ;;
        --keychain-profile)
            keychain_profile="${2:-}"
            shift 2
            ;;
        --sbom)
            sbom_path="${2:-}"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$app_path" && -n "$keychain_profile" ]] || usage
[[ -d "$app_path" ]] || { echo "App bundle not found: $app_path" >&2; exit 66; }

app_name="$(basename "$app_path" .app)"
release_dir="$repo_root/dist/release"
mkdir -p "$release_dir"
sbom_path="${sbom_path:-"$release_dir/${app_name}-sbom.json"}"
archive_path="$release_dir/${app_name}-notary.zip"

echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$app_path"

frameworks_dir="$app_path/Contents/Frameworks"
if [[ -d "$frameworks_dir" ]]; then
    while IFS= read -r dependency; do
        echo "Verifying embedded dependency: $dependency"
        codesign --verify --strict --verbose=2 "$dependency"
    done < <(find "$frameworks_dir" \( -name "*.framework" -o -name "*.dylib" \) -print)
fi

"$repo_root/Scripts/generate_sbom.sh" "$sbom_path"

echo "Creating notarization archive..."
rm -f "$archive_path"
ditto -c -k --keepParent "$app_path" "$archive_path"

echo "Submitting to Apple notarization service..."
xcrun notarytool submit "$archive_path" --keychain-profile "$keychain_profile" --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$app_path"

echo "Assessing notarized app..."
spctl -a -vv -t exec "$app_path"

echo "Release hardening complete:"
echo "  App:  $app_path"
echo "  SBOM: $sbom_path"
echo "  Zip:  $archive_path"
