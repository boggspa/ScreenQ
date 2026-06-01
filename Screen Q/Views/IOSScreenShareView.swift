//
//  IOSScreenShareView.swift
//  Screen Q
//
//  iOS / iPadOS view-only host screen. We surface the system broadcast
//  picker plus very explicit copy: this device cannot accept input from a
//  third-party app, only share the screen view-only.
//

#if os(iOS)
import SwiftUI
import ReplayKit

struct IOSScreenShareView: View {

    @EnvironmentObject private var app: AppState

    var body: some View {
        ZStack {
            ScreenQTheme.heroBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard
                    disclaimerCard
                    visibilityCard
                    pickerCard
                    stepsCard
                    if !app.replayKitModel.hasExtensionConfigured {
                        broadcastExtensionEmptyState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Share this iPhone or iPad")
        .onAppear {
            Task { await app.startIOSPresenceAdvertising() }
        }
    }

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [ScreenQTheme.cosmicAmber, ScreenQTheme.cosmicRose],
                            startPoint: .topLeading,
                            endPoint:   .bottomTrailing
                        )
                    )
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: ScreenQTheme.cosmicAmber.opacity(0.45), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Broadcast this screen")
                    .font(.sqHeadline)
                Text(app.iosPresenceAdvertising
                     ? "Discoverable as \(app.localDeviceName) on this network."
                     : "Preparing local-network visibility…")
                    .font(.sqCallout)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .screenQCard()
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(BroadcastInstructions.viewOnlyTitle, systemImage: "exclamationmark.shield")
                .font(.sqHeadline)
                .foregroundColor(ScreenQTheme.cosmicAmber)
            Text(BroadcastInstructions.viewOnlyBody)
                .font(.sqCallout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .screenQCard(tint: ScreenQTheme.cosmicAmber)
    }

    private var visibilityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    "Nearby visibility",
                    systemImage: app.iosPresenceAdvertising ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right"
                )
                .font(.sqHeadline)
                .foregroundColor(app.iosPresenceAdvertising ? ScreenQTheme.cosmicMint : .secondary)
                Spacer()
                Button("Refresh") {
                    SQHaptics.tap()
                    Task { await app.startIOSPresenceAdvertising() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let error = app.iosPresenceError {
                Text(error)
                    .font(.sqCallout)
                    .foregroundColor(ScreenQTheme.cosmicRose)
            } else {
                Text(app.iosPresenceAdvertising
                     ? "\(app.localDeviceName) is visible to Screen Q viewers on this local network as a view-only ReplayKit-capable device."
                     : "Screen Q is preparing local-network visibility for this device.")
                    .font(.sqCallout)
                    .foregroundColor(.secondary)
            }

            Label("Remote control is unavailable on iOS and iPadOS; viewers can watch and guide.", systemImage: "eye")
                .font(.sqCaption)
                .foregroundColor(.secondary)
        }
        .screenQCard()
    }

    private var pickerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start a broadcast")
                .font(.sqHeadline)
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    ScreenQTheme.cosmicCyan.opacity(0.85),
                                    ScreenQTheme.cosmicViolet.opacity(0.55)
                                ],
                                startPoint: .topLeading,
                                endPoint:   .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                    BroadcastPicker(
                        preferredExtensionBundleID: app.replayKitModel.broadcastExtensionBundleID
                    )
                    .frame(width: 60, height: 60)
                    .simultaneousGesture(
                        TapGesture().onEnded { SQHaptics.bump() }
                    )
                }
                .frame(width: 72, height: 72)
                .screenQCard(tint: ScreenQTheme.cosmicCyan, padding: 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(app.replayKitModel.hasExtensionConfigured
                         ? "Tap the broadcast button and choose Screen Q Broadcast to start Apple's capture flow."
                         : "No Screen Q broadcast extension is wired into this build yet. The picker still opens — choose any installed broadcast extension you trust to test the flow.")
                        .font(.sqCallout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This path is view-only. Control stays unavailable on iOS and iPadOS.")
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .screenQCard()
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steps").font(.sqHeadline)
            ForEach(Array(BroadcastInstructions.broadcastSteps.enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(idx + 1)")
                        .font(.sqCaption)
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle().fill(ScreenQTheme.cosmicCyan)
                        )
                    Text(step)
                        .font(.sqCallout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .screenQCard()
    }

    private var broadcastExtensionEmptyState: some View {
        SQEmptyState(
            icon: "antenna.radiowaves.left.and.right.slash",
            title: "Broadcast extension unavailable",
            message: "This build does not include Screen Q's experimental ReplayKit uploader. Use Apple's built-in screen sharing options instead.",
            tint: ScreenQTheme.cosmicAmber
        )
        .screenQCard()
    }
}
#endif
