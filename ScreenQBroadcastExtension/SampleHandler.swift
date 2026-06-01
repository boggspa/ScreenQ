//
//  SampleHandler.swift
//  ScreenQBroadcastExtension
//
//  Scaffolding for the iOS / iPadOS Broadcast Upload Extension target.
//  This file is intentionally NOT part of the main "Screen Q" app target —
//  it lives in a sibling folder so the project keeps building without it.
//
//  To turn this into a working extension:
//
//    1. In Xcode, File → New → Target → Broadcast Upload Extension.
//       Name it "ScreenQBroadcastExtension". Pick the same team and a bundle
//       id of the form <your-app-bundle-id>.ScreenQBroadcastExtension.
//
//    2. Replace Xcode's auto-generated SampleHandler.swift with this file.
//       Keep Xcode's Info.plist / entitlements unless you have a reason
//       to override them.
//
//    3. (Optional) Add an App Group shared between the host app and the
//       extension so the host app can pass connection details (host name,
//       port, session token) to the extension via UserDefaults(suiteName:).
//
//    4. In the host app, set
//         appState.replayKitModel.broadcastExtensionBundleID =
//             "<your-app-bundle-id>.ScreenQBroadcastExtension"
//       before presenting BroadcastPicker.
//
//  Touch / keyboard injection from the broadcast extension is NOT possible
//  — it is a one-way capture pipeline. Screen Q's iOS host is therefore
//  always view-only.
//

#if canImport(ReplayKit)
import ReplayKit
import AVFoundation

final class SampleHandler: RPBroadcastSampleHandler {

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // setupInfo can be populated by BroadcastSetupViewController. Use
        // App Group UserDefaults to pull host:port + session token from the
        // host app, then connect via your transport.
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        // Tear down your transport here.
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            // TODO: encode + ship sampleBuffer to the connected viewer using
            // the same FrameCodec as the main target. Be mindful of the
            // ~50 MB memory limit imposed on broadcast extensions: use the
            // hardware encoder via VTCompressionSession and avoid retaining
            // pixel buffers.
            break
        case .audioApp, .audioMic:
            // Audio is intentionally ignored in the MVP.
            break
        @unknown default:
            break
        }
    }
}
#endif
