# Roadmap

Screen Q is a local-first remote access app for Apple platforms. The public
roadmap keeps the first release focused on a small, testable surface rather
than broad remote-management claims.

## Preview Release

- Ship a notarized macOS Developer ID preview build.
- Keep iOS and iPadOS buildable while TestFlight readiness work continues.
- Keep the unfinished ReplayKit Broadcast Upload Extension out of public app
  artifacts.
- Publish release notes, checksum, SBOM, and third-party notices for each
  packaged preview.

## Near Term

- Expand the manual security test matrix for Screen Q Native, Mac Screen
  Sharing, Generic VNC, and RDP.
- Add a short demo video and updated screenshots for the role picker, host
  setup, pairing flow, viewer controls, and RDP certificate review.
- Package the macOS preview artifact with a repeatable release script and
  documented checksum verification.
- Prepare the iOS TestFlight checklist without enabling unfinished iOS screen
  broadcast features.
- Triage Swift 6 concurrency warnings and iOS 17 API deprecations.

## Later

- Harden and document file transfer recovery and large-transfer behavior.
- Expand RDP bridge packaging tests across Intel and Apple Silicon Macs.
- Add richer diagnostics export with redacted logs.
- Evaluate a dedicated Windows host agent that speaks Screen Q's native
  protocol.
- Revisit visionOS only after the viewer surface can be tested on real hardware.

## Non-Goals

- Public-internet relay hosting.
- Private iOS APIs, jailbreak assumptions, or MDM-only control paths.
- Fleet/RMM management claims.
- Mac App Store distribution for the macOS host while Accessibility-backed
  `CGEvent` input injection remains required.
