# iOS App Store Connect Readiness

This checklist is for the first iOS/iPadOS TestFlight and App Store Connect path.
It intentionally keeps private Apple team IDs, provisioning profile names,
privacy-policy URLs, and App Store Connect credentials out of the public
repository.

Apple references:

- Upload builds: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- Manage app privacy: https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
- Export compliance overview: https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance
- TestFlight test information: https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information

## Release Position

- First iOS submission is a viewer/connectivity build for iPhone and iPad.
- Do not claim third-party remote control of iPhone or iPad.
- Do not embed `ScreenQBroadcastExtension.appex` until the ReplayKit upload
  transport, memory limits, consent flow, and review notes are ready.
- Keep RDP clipboard redirection off by default on iOS; users must enable it for
  a specific RDP launch.

## Local Preflight

Run these before creating a signed archive:

```sh
Scripts/check_public_release_guards.sh

xcodebuild -quiet -scheme "Screen Q" \
  -configuration Release \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "dist/derived-data/ios-hardening" \
  CODE_SIGNING_ALLOWED=NO build
```

Expected result:

- No Swift warnings under `-quiet`.
- `Screen Q/PrivacyInfo.xcprivacy` is copied into the app bundle.
- `NSCameraUsageDescription` is present in the iOS app `Info.plist`.
- `LSUIElement` is absent from the iOS app `Info.plist`.
- No `ScreenQBroadcastExtension.appex` is embedded.

## Bundle ID And Signing

App Store Connect requires a real registered App ID and an Apple Distribution
signing path. Screen Q's public App Store bundle ID is:

```text
com.chrisizatt.Screen-Q
```

Keep Apple team IDs, signing certificates, provisioning profile names, and
export options outside git.

```sh
DEVELOPMENT_TEAM=ABCDE12345 Scripts/archive_ios_appstore.sh
```

If automatic signing needs to create or update profiles:

```sh
DEVELOPMENT_TEAM=ABCDE12345 \
ALLOW_PROVISIONING_UPDATES=1 \
Scripts/archive_ios_appstore.sh
```

If exporting an `.ipa` locally, create a private `ExportOptions.plist` outside
the repo and pass:

```sh
EXPORT_OPTIONS_PLIST=/path/to/ExportOptions.plist \
DEVELOPMENT_TEAM=ABCDE12345 \
Scripts/archive_ios_appstore.sh
```

Do not commit `ExportOptions.plist` if it contains team IDs, signing
certificates, or provisioning profile names.

## App Store Connect App Record

Create or confirm:

- App name: Screen Q
- Platform: iOS
- Bundle ID: `com.chrisizatt.Screen-Q`
- SKU: any stable private SKU, for example `screenq-ios`
- Category: Utilities or Productivity
- Price/availability: decide before external testing
- Age rating: remote-access utility, no user-generated public content

## Privacy Policy And App Privacy

Apple requires a privacy policy URL for iOS apps and app-level privacy answers in
App Store Connect. Keep the product-page answer aligned with the final build and
with any third-party services enabled.

Candidate current-build position:

- No developer-operated analytics, ad tracking, crash reporting, or telemetry.
- QR scan frames are processed on device and are not sent to Screen Q.
- Saved hosts, thumbnails, preferences, and credential inventory are local app
  data; credentials are stored in Keychain.
- iCloud key-value storage may sync selected app preferences through the user's
  Apple account.
- Network traffic is user-initiated to the selected LAN/VPN/Tailscale/remote
  host.
- Tailscale API credentials and device lists are only used if the user configures
  Tailscale integration.
- Clipboard sharing is explicit: VNC uses a send button; iOS RDP redirection is
  off unless enabled for the launch.

Before publishing privacy answers, verify whether App Store Connect treats the
enabled Tailscale path or any future diagnostics as collected data. If no
developer or third-party analytics collection is present in the submitted build,
the likely answer is "No, we do not collect data from this app"; only use that
after confirming the exact submitted binary and privacy policy text.

## Export Compliance

Screen Q uses encryption and secure transport primitives, including Apple
CryptoKit, TLS/NLA-related RDP paths, OpenSSL-backed dependencies, and the native
Screen Q encrypted session protocol. Do not answer "no encryption".

Use App Store Connect's export compliance flow for the submitted build. The
expected path for Screen Q is standard/public encryption for authentication and
secure communications, not proprietary encryption and not "none of the
algorithms mentioned above". The final answer is a release/legal decision and
must match the countries where the app is distributed.

If App Store Connect asks whether the app will be distributed in France, answer
according to the release territory choice. Making the app available in France
can require separate encryption documentation approval. Excluding France for an
early TestFlight/App Store submission avoids that documentation step until the
release plan explicitly includes France.

If App Store Connect determines no documentation is required, follow Apple's
prompt to set the corresponding `ITSAppUsesNonExemptEncryption` value in the
shipping iOS `Info.plist` for future submissions. Do not add that key until the
export-compliance answer is known.

## TestFlight Test Information

Use this as a starting point for TestFlight App Review:

```text
Beta App Description:
Screen Q for iPhone and iPad is a viewer for connecting to Screen Q, Mac Screen
Sharing/VNC, and RDP hosts on a private LAN, VPN, or Tailscale network. This
build does not include a ReplayKit Broadcast Upload Extension and does not
provide remote control of iPhone or iPad.

Sign-in:
No Screen Q account is required. RDP/VNC credentials are only needed when testing
against a host the reviewer controls.

Review Notes:
1. Launch Screen Q and choose Viewer.
2. Use Quick Connect or Manual Connect to enter a reachable host on the same
   network, VPN, or Tailscale network.
3. To test QR scanning, use a screenq:// quick-connect QR code; camera frames are
   processed locally.
4. To test clipboard behavior on iOS, connect to VNC and use the toolbar button
   to send clipboard text, or enable the RDP clipboard toggle before launch.
5. The "Share this iPhone or iPad screen" path is informational/view-only
   guidance in this build. The Broadcast Upload Extension is intentionally not
   embedded.
```

Before external testing, provide Apple with a reachable demo host or precise
test-host instructions. A remote-access app that requires a private host is much
easier to review when the reviewer has a deterministic path.

## App Review Gate

Do not submit to App Review until:

- A physical iPhone and iPad have completed first-run, local-network prompt, QR
  scan, manual connect, saved connection, VNC, and RDP smoke tests.
- App Store screenshots exist for iPhone and iPad.
- The privacy policy URL is live.
- App privacy answers are filled in and published.
- Export compliance is answered for the build.
- TestFlight test information is complete.
- `Scripts/archive_ios_appstore.sh` creates a signed archive with the registered
  bundle ID.
