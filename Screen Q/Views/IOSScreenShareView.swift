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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                disclaimerCard
                pickerCard
                stepsCard
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Share this iPhone or iPad")
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(BroadcastInstructions.viewOnlyTitle, systemImage: "exclamationmark.shield")
                .font(.title3.bold())
            Text(BroadcastInstructions.viewOnlyBody)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private var pickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a broadcast")
                .font(.title3).bold()
            HStack(alignment: .center, spacing: 16) {
                BroadcastPicker(
                    preferredExtensionBundleID: app.replayKitModel.broadcastExtensionBundleID
                )
                .frame(width: 60, height: 60)
                .background(
                    Circle().fill(.background.tertiary)
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.replayKitModel.hasExtensionConfigured
                         ? "Tap the broadcast button to choose a Screen Q extension."
                         : "No Screen Q broadcast extension is wired into this build yet. The picker still opens — choose any installed broadcast extension you trust to test the flow.")
                        .font(.subheadline)
                    Text("See README → 'iOS Broadcast Upload Extension' for how to add the companion target.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps").font(.title3).bold()
            ForEach(Array(BroadcastInstructions.broadcastSteps.enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(idx + 1).").bold().monospacedDigit()
                    Text(step)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}
#endif
