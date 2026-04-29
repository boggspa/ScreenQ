//
//  StreamQualityControl.swift
//  Screen Q
//

import SwiftUI

struct StreamQualityButton: View {
    @Binding var quality: Double
    var protocolName: String
    var detail: String
    var compact: Bool = true

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: compact ? 38 : nil, height: compact ? 38 : nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quality and compression")
        .popover(isPresented: $isPresented) {
            StreamQualityPanel(
                quality: $quality,
                protocolName: protocolName,
                detail: detail
            )
            .frame(width: 320)
            .padding(16)
        }
    }
}

private struct StreamQualityPanel: View {
    @Binding var quality: Double
    var protocolName: String
    var detail: String

    private var preference: StreamQualityPreference {
        StreamQualityPreference(quality: quality)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Quality", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Text("\(preference.percent)%")
                    .font(.system(.body, design: .monospaced).bold())
            }

            Slider(value: $quality, in: StreamQualityPreference.allowedRange)

            HStack {
                Text("Compression")
                Spacer()
                Text(preference.estimatedBitrateText(protocolName: protocolName))
                    .foregroundColor(.secondary)
            }
            .font(.caption)

            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 8) {
                qualityPresetButton("Hotspot", value: 0.35)
                qualityPresetButton("Balanced", value: StreamQualityPreference.defaultQuality)
                qualityPresetButton("Max", value: 1.0)
            }
        }
    }

    private func qualityPresetButton(_ title: String, value: Double) -> some View {
        Button(title) {
            quality = value
        }
        .buttonStyle(.bordered)
    }
}
