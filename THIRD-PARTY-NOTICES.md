# Third-Party Notices

Screen Q is built on Apple platform SDKs and can optionally bundle native
bridge dependencies for RDP support.

Screen Q source code is licensed under Apache-2.0. See `LICENSE` and
`NOTICE` for project licensing and attribution terms.

## Apple SDKs

Screen Q uses public Apple frameworks including SwiftUI, Network,
ScreenCaptureKit, CoreGraphics, AVFoundation, ReplayKit, CryptoKit, and
Security. Apple framework terms are governed by the applicable Apple developer
agreements and SDK licenses.

## Optional RDP Bridge

Release builds that bundle RDP support should include notices for the exact
versions recorded in the generated SBOM:

- FreeRDP / WinPR, default build version `3.25.0`.
- OpenSSL, default build version `3.6.2`.

Generate the release SBOM with:

```sh
SCREENQ_VERSION=1.0.0 Scripts/generate_sbom.sh dist/release/ScreenQ-sbom.json
```

Archive the SBOM, notarization log, and upstream license texts with each
public release.

## Network Services

Screen Q can work over Tailscale or another user-managed VPN, but it does not
vendor, modify, or redistribute Tailscale.
