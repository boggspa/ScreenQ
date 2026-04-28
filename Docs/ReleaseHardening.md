# Release Hardening

This document covers the release controls that keep Screen Q self-contained and auditable.

## Required Release Artifacts

- Signed `Screen Q.app`
- Signed embedded RDP bridge dependencies
- Notarization archive and stapled notarized app
- CycloneDX SBOM
- Dependency version record for FreeRDP and OpenSSL
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
