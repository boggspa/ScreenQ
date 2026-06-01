# Release Hardening

This document covers the release controls that keep Screen Q self-contained and auditable.

## Distribution Position

- macOS public releases are Developer ID + hardened runtime + notarization
  builds. They are not Mac App Store builds because the Mac host disables App
  Sandbox to perform Accessibility-backed `CGEvent` input injection.
- iOS and iPadOS releases can be App Store-oriented, but public builds must not
  embed the unfinished `ScreenQBroadcastExtension.appex`.
- visionOS is not in the public app target's supported platforms until the
  viewer surface is tested and reviewed.
- Screen Q's public bundle identifier is `com.chrisizatt.Screen-Q`. Forks and
  private builds should override `SCREENQ_BUNDLE_ID` with their own registered
  app identifier.

## Required Release Artifacts

- Signed `Screen Q.app`
- Signed embedded RDP bridge dependencies
- Notarization archive and stapled notarized app
- CycloneDX SBOM
- Apache-2.0 `LICENSE` and `NOTICE`
- Dependency version record for FreeRDP and OpenSSL
- Third-party license/notices archive matching the SBOM
- Manual security test results for Screen Q Native, Mac Screen Sharing, Generic VNC, and RDP

## Build Dependencies

The release app should use bundled/static dependency builds, not Homebrew runtime links.

```sh
Scripts/build_freerdp_bridge.sh --universal
Scripts/build_freerdp_ios_xcframework.sh
```

The scripts pin defaults through environment variables:

- `FREERDP_VERSION`, default `3.25.0`
- `OPENSSL_VERSION`, default `3.6.2`
- `MACOSX_DEPLOYMENT_TARGET`, default controlled by the build script
- `IOS_DEPLOYMENT_TARGET`, default controlled by the build script

## Generate SBOM

```sh
SCREENQ_VERSION=1.0.0 Scripts/generate_sbom.sh dist/release/ScreenQ-sbom.json
```

The generated SBOM records Screen Q, the embedded ScreenQFreeRDPBridge, FreeRDP, OpenSSL, and the git revision used for the build.

## CI Release Guard

Run the public-release guard locally before opening a release PR:

```sh
Scripts/check_public_release_guards.sh
```

After local Release builds, pass the built app paths to verify that public
artifacts do not embed unfinished app extensions:

```sh
SCREENQ_MAC_APP_PATH="/path/to/Screen Q.app" \
SCREENQ_IOS_APP_PATH="/path/to/Release-iphonesimulator/Screen Q.app" \
Scripts/check_public_release_guards.sh
```

The GitHub Actions workflow in `.github/workflows/release-guard.yml` runs the
same guard before and after unsigned macOS and iOS Simulator Release builds.

## Signing Prerequisites

Use a registered bundle identifier and Apple team for signed archives:

```sh
xcodebuild archive \
  -scheme "Screen Q" \
  -destination "generic/platform=macOS" \
  -configuration Release \
  -archivePath "dist/release/ScreenQ-macOS.xcarchive" \
  SCREENQ_BUNDLE_ID=com.chrisizatt.Screen-Q \
  DEVELOPMENT_TEAM=TEAMID
```

Entitlements are split by SDK. iOS and iPadOS builds use
`Screen Q/Entitlements/ScreenQ-iOS.entitlements`, which keeps iCloud key-value
storage available for TestFlight/App Store work. macOS Developer ID
builds use `Screen Q/Entitlements/ScreenQ-macOS-DeveloperID.entitlements`,
which intentionally omits iCloud so notarized public macOS releases do not
require a Developer ID provisioning profile for iCloud.

iOS, iPadOS, TestFlight, and App Store archives need an Apple Distribution
certificate plus matching distribution provisioning profiles. Keep
`SCREENQ_BUNDLE_ID` set to the registered App ID when archiving.

For the iOS App Store Connect path, use
`Docs/iOSAppStoreConnectReadiness.md` and the repo-safe archive helper:

```sh
DEVELOPMENT_TEAM=TEAMID Scripts/archive_ios_appstore.sh
```

## Notarize macOS App

Create the notary profile once:

```sh
xcrun notarytool store-credentials ScreenQNotary \
  --apple-id "developer@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Then run:

```sh
Scripts/notarize_release.sh \
  --app "/path/to/Screen Q.app" \
  --keychain-profile ScreenQNotary
```

The script verifies signatures, verifies embedded frameworks/dylibs, creates the SBOM, submits to notarization, staples the ticket, and runs Gatekeeper assessment.

## Dependency Update Process

1. Check FreeRDP and OpenSSL security advisories.
2. Update the pinned version environment variables or script defaults.
3. Rebuild macOS and iOS bridge artifacts.
4. Run RDP live tests against a known Windows host over LAN/Tailscale.
5. Generate a new SBOM.
6. Sign, notarize, staple, and assess.
7. Archive the SBOM and notarization log with the release.

## Release Gate

Do not ship a release build if:

- The app links to `/opt/homebrew` or another developer-local dependency path.
- `codesign --verify --deep --strict` fails for the app.
- RDP certificate pin change handling does not hard-stop.
- Native Screen Q sessions can exchange privileged messages before encryption is active.
- Saved admin-level credentials can be reused without either explicit fresh entry or local device-owner authentication when that option was enabled.
- `Screen Q.app/PlugIns/ScreenQBroadcastExtension.appex` is present in an iOS
  or iPadOS public build.
- The main app target includes `xros` or `xrsimulator` in `SUPPORTED_PLATFORMS`
  for a public release.
- A release build exposes or executes remote command, system action, system
  report, or package install protocol messages.
