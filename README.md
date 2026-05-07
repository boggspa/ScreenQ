# Screen Q

A local-first, Apple-native screen sharing and remote-control app built
on Swift, SwiftUI, and Apple frameworks. Screen Q is aimed at prosumers,
creators, developers, and small teams who want fast direct control of
their own Macs across Apple devices without routing sessions through a
cloud relay.

Screen Q is not positioned as a fleet-management replacement for Apple
Remote Desktop, TeamViewer, AnyDesk, or an enterprise RMM suite. It
focuses on consent-based personal and studio workflows, local network
discovery, Tailscale/VPN reachability, and platform behavior that stays
inside public Apple APIs.

## Capabilities

### Shipping

- **Mac host**: turn this Mac into a controllable host. Screen Recording
  via [`ScreenCaptureKit`](https://developer.apple.com/documentation/screencapturekit),
  remote pointer + keyboard injection via Accessibility +
  [`CGEvent`](https://developer.apple.com/documentation/coregraphics/cgevent).
  Pairing-code consent + explicit host approval gate every session.
- **Viewer** (macOS, iOS, iPadOS): discover Mac hosts via
  Bonjour `_screenq._tcp`, or connect manually by hostname/IP/port (works
  with LAN, VPN, or Tailscale).
- **Apple-native alternatives** help screen explaining FaceTime SharePlay
  Remote Control, iPhone Mirroring, Universal Control, Switch Control,
  and the built-in Mac Screen Sharing flow. Screen Q does not market
  iPhone/iPad ReplayKit sharing as a commercial remote-control path.
- **Pairing flow**: 6-digit code shown on host, viewer enters it, host
  must explicitly approve the request before any video frame or input
  event can flow.
- **Native Screen Q security**: native sessions negotiate X25519 keys,
  seal post-handshake frame bodies with ChaChaPoly, pin a long-lived
  device identity for trusted reconnect, and fail closed instead of
  falling back to plaintext.
- **Diagnostics screen** with deterministic in-app self-tests covering
  protocol framing round-trip and viewer coordinate mapping.
- **Security & Trust view**: local inventory for saved connections,
  pinned Screen Q identities, credential boundaries, and recent audit
  entries, including reviewed RDP certificate pins.
- **RDP / Windows route**: `.rdp` import, Keychain-backed credentials,
  certificate review/pinning, live frame/input bridge integration, and an
  explicit packaging error when the FreeRDP bridge is not bundled.
- **URL schemes / Quick Connect**: app-level handling for `screenq://`,
  `screens://`, `vnc://`, `rdp://`, and `ms-rd://` links. `ssh://` links
  are recognized and reported as unsupported until SSH sessions exist.
- **First-run onboarding**: one-time setup router for hosting this Mac,
  connecting to a Mac, Tailnet setup, Apple Screen Sharing, and RDP import.
- **iCloud sync**: saved connection metadata, groups, and viewer-control
  preferences sync through iCloud key-value storage. Passwords remain in
  Keychain/iCloud Keychain and thumbnails/trust decisions stay local.
- **File transfer**: permission-gated chunked transfers with safe
  filename handling, size/order enforcement, streamed temp files, and
  progress UI.
- **Multi-observe**: a live tile overview for active Screen Q, VNC, and
  RDP sessions.
- **Session recording**: viewer-side `.mov` recording from decoded
  Screen Q, VNC, and RDP frames.

### Beta

- **Mac Screen Sharing and VNC / RFB compatibility**: Screen Q discovers
  `_rfb._tcp` services and treats Apple Screen Sharing / Remote
  Management separately from generic VNC. Mac Screen Sharing prefers
  macOS account credentials through Apple's RFB authentication extension
  when offered; generic VNC remains a legacy password-only compatibility
  route. Screen Q's native protocol remains separate on port `38745`.
- **Advanced Mac-session features**: clipboard sync, audio forwarding,
  saved connections, multi-display switching, adaptive bitrate, cursor
  overlay, and reconnection are being developed around the native Screen Q
  protocol.

### Planned

- **Windows access, stage 2**: a dedicated Windows host agent that speaks
  Screen Q's native protocol.
- **Supportability workflows**: exportable diagnostics, guided connection
  tests, redacted logs, and richer permission presets.

### Demoted / not marketed

- **Vision Pro** remains a compile target experiment only until it can be
  tested as a first-class viewer surface.
- **iPhone / iPad screen sharing** remains Apple-native guidance rather
  than a Screen Q product path.
- **Curtain mode** and **fleet/RMM management** are not commercial claims
  for this product direction.

## What is intentionally not possible (and never will be in a
well-behaved third-party app)

- **No remote control of iOS / iPadOS.** Apple does not expose any
  public, App Store-safe API for synthesising touches on iPhone or iPad
  from a third-party app. Screen Q won't pretend otherwise. Use
  **FaceTime SharePlay Remote Control**, **iPhone Mirroring**, **Switch
  Control / platform switching**, or another Apple-managed flow when you
  need true control.
- **No private API usage**, no jailbreak assumptions, no MDM-only tricks.
- **No public-internet exposure.** Screen Q is LAN-first and is designed
  to ride on top of Tailscale (or any other VPN you already have) for
  cross-network reach.

## Project layout

```
Screen Q.xcodeproj          // multiplatform target (macOS, iOS, iPadOS; visionOS experimental)
Screen Q/
  Screen_QApp.swift         // app entry point
  AppState.swift            // top-level observable state
  Screen Q.entitlements
  Models/
    DeviceRole.swift
    PeerDevice.swift
    SessionState.swift
    Capabilities.swift
    RemoteInputEvent.swift
    VideoFrame.swift
    PermissionSet.swift
    ComputerList.swift
  Networking/
    ScreenQProtocol.swift
    FrameCodec.swift
    BonjourAdvertiser.swift
    BonjourBrowser.swift
    ConnectionManager.swift
    PairingManager.swift
    SecureSession.swift
    TransportStats.swift
    AdaptiveBitrateController.swift
    ReconnectionManager.swift
    FileTransferService.swift
    ConnectivityProbe.swift
  MacHost/                  // #if os(macOS)
    MacScreenCaptureService.swift
    MacInputInjectionService.swift
    MacPermissionsService.swift
    DisplaySelectionService.swift
    H264FrameEncoder.swift
    CursorTracker.swift
    ClipboardSyncService.swift
    AudioCaptureService.swift
    CurtainMode.swift
    RemoteCommandService.swift
    SystemActionService.swift
    SystemReportCollector.swift
    PackageInstallService.swift
  Viewer/
    RemoteScreenRenderer.swift
    InputMappingService.swift
    KeyboardMapping.swift
    CursorOverlayView.swift
    AudioPlayerService.swift
    TrackpadInputView.swift
    MacKeyboardCapture.swift
    SessionRecorder.swift
  IOSHost/                  // #if os(iOS)
    ReplayKitBroadcastModel.swift
    BroadcastInstructions.swift
  Views/
    HomeView.swift
    HostMacView.swift
    ViewerView.swift
    DiscoveryView.swift
    ManualConnectView.swift
    RemoteScreenView.swift
    PermissionsView.swift
    IOSScreenShareView.swift
    AppleNativeAlternativesView.swift
    DiagnosticsView.swift
    PerformanceGraphView.swift
    FileTransferOverlay.swift
    RemoteTerminalView.swift
    SystemReportView.swift
    FleetSidebarView.swift
    MultiObserveView.swift
  Utilities/
    Logger.swift
    DeviceName.swift
    ByteFormatting.swift
    MainActorHelpers.swift
    SavedConnectionsStore.swift
    WakeOnLAN.swift
    AuditLog.swift
  Tests/
    SelfTests.swift          // deterministic, runnable from DiagnosticsView
ScreenQBroadcastExtension/   // scaffolding for the Broadcast Upload Extension
                             // target (NOT part of the main target; see below)
```

## Wire format

A small length-prefixed binary frame protocol over `NWConnection`. See
`Networking/ScreenQProtocol.swift` for the full spec.

```
Header (24 bytes, big-endian):
  UInt32 magic       0x53513031 ("SQ01")
  UInt16 version     1
  UInt16 type        MessageType raw value
  UInt16 flags       bit 0 = encrypted body
  UInt16 reserved    0
  UInt64 sequence    monotonically increasing per direction
  UInt32 bodyLength  bytes that follow this header

Body:
  - Control messages: UTF-8 JSON
  - videoFrame:       UInt32 metaLen + JSON(VideoFrameMeta) + raw payload
```

Default port: **38745** (random-ish; not 5900, that's Apple/VNC).

Native Screen Q encrypts frame bodies after `hello` / `helloAck`.
`hello` and `helloAck` stay cleartext so both sides can exchange
ephemeral keys and device-identity proofs. VNC, Apple Screen Sharing, and
RDP are external protocol adapters and keep their own security models;
Screen Q does not claim E2EE for those routes.

## Security posture

- Prefer **Screen Q Native** when you control both endpoints: encrypted
  transport, explicit host approval, per-session permissions, and pinned
  device identities.
- Use **Mac Screen Sharing** for Macs that do not run Screen Q but have
  Apple Screen Sharing or Remote Management enabled. Screen Q will try
  macOS account credentials first when the Mac offers Apple authentication.
- Use **Generic VNC** only as a compatibility fallback over Tailscale,
  VPN, or a private LAN. The VNC password is a separate legacy password,
  not a Mac admin/user login.
- Use **RDP** for Windows on port `3389`; Screen Q pins reviewed RDP
  certificates and stores remembered credentials in Keychain. Remembered
  RDP, Mac Screen Sharing, and VNC credentials can require Touch ID,
  Face ID, or device passcode before reuse.
- Distribution builds should be Developer ID signed, hardened-runtime
  enabled, notarized, and ship signed/pinned FreeRDP/OpenSSL bridge
  dependencies with an SBOM and documented update process. See
  `Docs/ReleaseHardening.md`.

## Required macOS permissions

Screen Q needs three TCC / privacy permissions on the host Mac:

- **Screen Recording** — to call ScreenCaptureKit.
- **Accessibility** — to post `CGEvent`s for remote pointer/keyboard.
- **Local Network** — to advertise / browse Bonjour services.

The Host Mac screen contains a checklist with one-tap buttons to request
each permission and to open the relevant Privacy & Security pane.

> The macOS build disables App Sandbox via
> `ENABLE_APP_SANDBOX[sdk=macosx*] = NO` in the project's build settings.
> Sandboxed Mac apps cannot call `CGEvent.post` for system-wide event
> injection, which is fundamental to remote control. iOS and iPadOS
> sandboxing remains in effect (it's implicit on those platforms).

## How to test on LAN

1. Build the Mac target and run on Mac A.
2. Build the iOS / Mac target and run on device B (same Wi-Fi or
   wired LAN).
3. On Mac A: pick **Host this Mac**, grant the three permissions, click
   **Start Hosting**. Note the 6-digit pairing code.
4. On device B: pick **Connect to a remote host**. Mac A should appear
   under "Nearby Screen Q hosts". Tap it.
5. Enter the pairing code shown on Mac A.
6. On Mac A: click **Approve** in the incoming requests list.
7. Stream begins. Use the toolbar on the viewer to toggle fit/fill,
   send special keys, type into a text field, or disconnect.

## How to test with Tailscale

Screen Q does **not** vendor or modify Tailscale. Treat it as the
network layer.

1. Install Tailscale on both devices and sign in to the same tailnet.
2. On Mac A, look up its MagicDNS name in Tailscale (e.g.
   `mac-mini.tailnet.ts.net`) or its `100.x.y.z` address.
3. On device B → **Connect to a remote host** → **Manual / Tailscale
   connect** → enter the MagicDNS name (or `100.x.y.z`) and the Screen Q
   port `38745`.
4. Pairing flow proceeds as on LAN.

Bonjour is local-network only — across the tailnet, use the manual
connect form.

## How to test the native RDP bridge on macOS

RDP uses the Windows Remote Desktop port, normally **3389**. Do not use
Screen Q's native port `38745` for a Windows RDP target.

1. Build the self-contained macOS bridge:
   `Scripts/build_freerdp_bridge.sh`.
   This builds static OpenSSL, FreeRDP, and WinPR dependencies under
   `.build/macos-deps`, then links them into one bridge dylib.
   For distribution builds, use `Scripts/build_freerdp_bridge.sh --universal`
   to build and merge both `arm64` and `x86_64` slices.
2. Build Screen Q in Xcode. The **Embed Optional RDP Bridge** build phase
   copies `.build/ScreenQFreeRDPBridge/dist/libScreenQFreeRDPBridge.dylib`
   into `Screen Q.app/Contents/Frameworks`.
3. For a manual local debug run outside Xcode, either set
   `SCREENQ_FREERDP_BRIDGE_PATH=/Users/chrisizatt/Documents/Screen Q/.build/ScreenQFreeRDPBridge/dist/libScreenQFreeRDPBridge.dylib`
   or copy it into an app bundle:
   `Scripts/build_freerdp_bridge.sh --install-to-app "/path/to/Screen Q.app"`.
4. In Screen Q, connect to the Windows PC's Tailscale IP or MagicDNS name
   on port `3389`, with the Windows Remote Desktop credentials.

`Scripts/build_freerdp_bridge.sh --dynamic-homebrew` is available as a
developer fallback, but release/debug app bundles should use the default
self-contained static bridge so they do not depend on `/opt/homebrew`.

For release signing, notarization, and SBOM generation, use:

- `Scripts/generate_sbom.sh`
- `Scripts/notarize_release.sh`
- `Docs/ReleaseHardening.md`

For Apple Screen Sharing compatibility tests, use
`Scripts/probe_apple_screen_sharing.rb` with the matrix in
`Docs/AppleScreenSharingTestMatrix.md`.

## How to package the RDP bridge for iPhone and iPad

iOS cannot load the macOS/Homebrew bridge dylib. Build a signed iOS
framework that statically contains FreeRDP, WinPR, and OpenSSL, then
bundle that framework in the app.

1. Build the iOS dependencies and XCFramework:
   `Scripts/build_freerdp_ios_xcframework.sh`.
2. The output is:
   `.build/ScreenQFreeRDPBridge-iOS/dist/ScreenQFreeRDPBridge.xcframework`.
3. The app target includes an optional **Embed Optional RDP Bridge** run
   script phase. It embeds the matching `ScreenQFreeRDPBridge.framework`
   slice when the XCFramework exists and otherwise leaves the app
   buildable.
4. In Screen Q on iPhone or iPad, connect to the Windows PC's Tailscale
   IP or MagicDNS name on port `3389`.

The first iOS bridge build intentionally disables FreeRDP dynamic
channels and optional JSON/URI dependencies so the bundle is deterministic
and App Store-friendly. Clipboard, audio, drive redirection, and dynamic
channel features should be re-enabled one at a time with explicit iOS
dependency packaging and tests.

## iOS Broadcast Upload Extension (demoted)

The companion `ScreenQBroadcastExtension/` target remains in the repository as
a ReplayKit experiment and compatibility reference. It is not a marketed Screen
Q remote-control path because iOS and iPadOS do not expose public input
injection APIs to third-party apps.

The `ScreenQBroadcastExtension/` folder contains:

- `SampleHandler.swift` — your subclass of `RPBroadcastSampleHandler`.
- `BroadcastSetupViewController.swift` — optional ReplayKit setup UI.
- `Info.plist` — extension principal class declaration.
- `README-EXT.md` — implementation notes for the capture/upload transport.

If this code is enabled in a development build, Screen Q should treat nearby
iPhone and iPad entries as Apple-native guidance, not as connectable commercial
remote-control sessions.

## How to enable native Mac Screen Sharing as an alternative

If Screen Q's protocol doesn't suit your use case:

1. Apple menu → **System Settings → General → Sharing**.
2. Enable **Screen Sharing** (or **Remote Management**).
3. From another Mac: **Finder → Go → Connect to Server…** → enter
   `vnc://hostname` or use the **Screen Sharing** app directly.

This is Apple's first-party RFB-based protocol on port 5900. It is
distinct from Screen Q's native protocol on port 38745. Screen Q also
surfaces nearby `_rfb._tcp` services in its Bonjour browser and is using
VNC / RFB compatibility as the first interoperability path for Apple
Screen Sharing and Windows VNC hosts.

## Feature overview

### Shipping native core

- **Mac host + Apple-device viewer** — consent-based Mac hosting with
  Bonjour discovery, manual LAN/VPN/Tailscale connection, pairing codes,
  and explicit host approval.
- **Native Screen Q protocol** — length-prefixed binary frames over
  `NWConnection`, separate from VNC / RFB.
- **macOS public-API control path** — ScreenCaptureKit capture and
  Accessibility-backed `CGEvent` input injection.
- **Apple-native iPhone/iPad guidance** — Screen Q directs users to
  Apple-managed sharing/control flows instead of marketing ReplayKit as a
  remote-control product path.
- **Diagnostics** — deterministic self-tests for protocol framing and
  viewer coordinate mapping.

### Beta native session features

- **H.264 hardware encoding/decoding** via `VTCompressionSession` / `VTDecompressionSession`
- **End-to-end encryption** — X25519 key exchange + ChaChaPoly on every frame
- **Adaptive bitrate** — adjusts bitrate (500 kbps–16 Mbps) and FPS (5–60) from RTT + dropped-frame stats
- **120 Hz cursor overlay** — host tracks cursor separately, viewer renders with actual cursor bitmap
- **Bidirectional clipboard sync** — NSPasteboard polling + offer/request/data flow
- **Audio forwarding** — SCStream audio capture → AVAudioEngine playback on viewer
- **Saved connections / bookmarks** — local UserDefaults persistence with iCloud sync for non-secret metadata
- **Multi-display switching** — host sends display list; viewer can switch mid-session
- **Reconnection** — NWPathMonitor + exponential backoff with optional reconnect token
- **iOS trackpad mode** — two-finger scroll, long-press right-click, pinch-to-zoom, three-finger drag
- **macOS full keyboard capture** — intercepts all keys including system shortcuts
- **Retina-aware scaling** — native `backingScaleFactor` per display
- **File drag-and-drop** — chunked transfer with progress and hardened receive-side file handling
- **Session recording** — `AVAssetWriter` H.264 `.mov` from decoded frame streams
- **Multi-observe tile view** — simultaneous live thumbnails from active Screen Q, VNC, and RDP sessions

### Planned prosumer features

- **Wake-on-LAN** — UDP magic packet sender
- **Performance graphs** — real-time sparkline for bandwidth, FPS, and RTT

### Planned administrative features

- **Granular permission model** — 9 flags (observe, control, clipboard, file transfer, remote command, system actions, package install, audio, report) with presets (Full Access / Standard / View Only)
- **Remote Unix command execution** — shell via `Process`, streamed stdout/stderr in a terminal view
- **System report / audit** — hardware model, serial, CPU, RAM, disk, IP addresses, installed apps
- **Connection lists** — saved hosts, recents, groups, and detail sheets for personal/studio organization
- **Custom cursor bitmap** — actual `NSCursor.image` PNG sent to viewer
- **Restart / Sleep / Lock / Log Out / Shutdown** — system actions via AppleScript / pmset
- **Remote package install** — file transfer + `installer -pkg` CLI
- **Audit log** — persistent JSON-lines log at `~/Library/Logs/ScreenQ/audit.jsonl`

## Known limitations

- iOS / iPadOS host is view-only by Apple platform design.
- Screen Q cannot remotely synthesize taps, gestures, or keyboard input
  into another iPhone or iPad app. Apple-controlled options such as
  FaceTime SharePlay Remote Control, iPhone Mirroring, Switch Control, or
  MDM workflows are the appropriate paths when they fit the use case.
- Cursor exclusion of Screen Q's own window is best-effort via
  `excludingApplications`. If you need stricter exclusion, use the
  display picker to share a different display.
- The project currently builds with a small set of known Swift
  concurrency warnings in the networking layer under
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_VERSION = 5.0`.
  Wire-format types and pure-logic helpers are explicitly `nonisolated`
  so they cross actor boundaries cleanly.

## Self-tests

The Diagnostics screen (toolbar wrench icon on Home) runs deterministic
pure-Swift tests covering:

- Header round-trip encode/decode.
- JSON message round-trip via `FrameCodec`.
- Video frame round-trip with attached payload.
- Streaming decoder accepting byte-by-byte feeds.
- Streaming decoder rejecting bad magic.
- Coordinate mapping (fit + fill + out-of-bounds).
- `NormalisedPoint` clamping.
- `RemoteInputEvent` Codable round-trip.

These tests live in `Screen Q/Tests/SelfTests.swift` so they ride along
with the app target and don't require a separate XCTest target. Run
them on the device or simulator you actually deploy to.

## Troubleshooting connection issues

### "No Screen Q hosts found" on the viewer

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| 0 Screen Q hosts, but RFB hosts detected | The host Mac hasn't tapped **Start Hosting** yet | Open Screen Q on the host → Host this Mac → Start Hosting |
| 0 Screen Q hosts, 0 RFB hosts | Bonjour multicast blocked or devices on different VLANs/networks | Check Wi-Fi; ensure both devices are on the same subnet |
| iOS says "Screen Q would like to find and connect to devices on your local network" | First-time Local Network permission prompt | Tap **Allow**; if already denied, go to Settings → Privacy & Security → Local Network → Screen Q |

### "Connection refused" when using Manual Connect

This means the host IP is reachable (TCP RST received) but **nothing is
listening on port 38745**. Causes:

1. The host hasn't pressed **Start Hosting** yet.
2. The macOS firewall is blocking incoming connections on that port.
3. The listener failed to bind (check the host console for "Listener
   failed" logs).

Use the **Test Connection** button in the Manual Connect form — it runs a
TCP probe and tells you exactly what went wrong before you commit to the
full handshake.

### "Timed out" when connecting over Tailscale

- Both devices must be signed in to the **same tailnet**.
- Verify with `tailscale status` that you can see the other machine.
- Try `ping <tailscale-ip>` to confirm IP-level reachability.
- Screen Q's Manual Connect form accepts MagicDNS names
  (e.g. `mac-mini.tailnet.ts.net`) or Tailscale IPs (`100.x.y.z`).

### Host doesn't know its own addresses

After tapping **Start Hosting**, a new card appears listing the host's
LAN and Tailscale IPv4 addresses with copy-to-clipboard buttons. If the
card is empty, check that the host has an active network interface.

## Build commands used

```
xcodebuild -list
xcodebuild -scheme "Screen Q" -destination "platform=macOS" \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO
xcodebuild -scheme "Screen Q" -destination "generic/platform=iOS Simulator" \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Both succeed.
