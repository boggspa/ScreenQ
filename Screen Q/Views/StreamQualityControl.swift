//
//  StreamQualityControl.swift
//  Screen Q
//

import SwiftUI

struct StreamQualityButton: View {
    @Binding private var quality: Double
    private var profile: Binding<StreamProfile>?
    var protocolName: String
    var detail: String
    var compact: Bool = true

    @State private var isPresented = false

    init(
        quality: Binding<Double>,
        profile: Binding<StreamProfile>? = nil,
        protocolName: String,
        detail: String,
        compact: Bool = true
    ) {
        self._quality = quality
        self.profile = profile
        self.protocolName = protocolName
        self.detail = detail
        self.compact = compact
    }

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
                streamProfile: profile,
                protocolName: protocolName,
                detail: detail
            )
            .frame(width: 360)
            .padding(16)
        }
    }
}

private struct StreamQualityPanel: View {
    @Binding var quality: Double
    var streamProfile: Binding<StreamProfile>?
    var protocolName: String
    var detail: String

    private var preference: StreamQualityPreference {
        StreamQualityPreference(quality: quality)
    }

    private var effectiveProfile: StreamProfile {
        streamProfile?.wrappedValue ?? preference.nativeProfile
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                Slider(value: qualityBinding, in: StreamQualityPreference.allowedRange)

                HStack {
                    Text("Compression")
                    Spacer()
                    Text(preference.estimatedBitrateText(protocolName: protocolName))
                        .foregroundColor(.secondary)
                }
                .font(.caption)

                summaryRows

                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                presetButtons

                Divider()

                advancedControls
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Quality", systemImage: "slider.horizontal.3")
                .font(.headline)
            Spacer()
            Text("\(preference.percent)%")
                .font(.system(.body, design: .monospaced).bold())
        }
    }

    private var summaryRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            profileRow("Mode", effectiveProfile.mode.label)
            profileRow("Scaling", effectiveProfile.scalePolicy.label)
            profileRow("Codec", effectiveProfile.codecPreference.label)
            profileRow("Ceiling", "\(formatMbps(effectiveProfile.maxBitrate)) / \(effectiveProfile.targetFPS) fps")
        }
        .font(.caption)
    }

    private var presetButtons: some View {
        HStack(spacing: 8) {
            qualityPresetButton("Hotspot", value: 0.35)
            qualityPresetButton("Balanced", value: StreamQualityPreference.defaultQuality)
            qualityPresetButton("Max", value: 1.0)
        }
    }

    private var advancedControls: some View {
        DisclosureGroup("Advanced Parameters") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: modeBinding) {
                    ForEach(StreamOptimizationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Picker("Scaling", selection: profileBinding(\.scalePolicy)) {
                    ForEach(StreamScalePolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }

                Picker("Codec", selection: profileBinding(\.codecPreference)) {
                    ForEach(StreamCodecPreference.allCases) { codec in
                        Text(codec.label).tag(codec)
                    }
                }

                parameterSlider(
                    title: "Max Bitrate",
                    value: bitrateBinding,
                    range: 0.5...40,
                    step: 0.5,
                    valueText: "\(formatMbps(effectiveProfile.maxBitrate))"
                )

                parameterSlider(
                    title: "FPS",
                    value: fpsBinding,
                    range: 5...60,
                    step: 1,
                    valueText: "\(effectiveProfile.targetFPS)"
                )

                parameterSlider(
                    title: "Compression Quality",
                    value: compressionQualityBinding,
                    range: 0.2...1.0,
                    step: 0.01,
                    valueText: "\(Int((effectiveProfile.quality * 100).rounded()))%"
                )

                parameterSlider(
                    title: "Keyframes",
                    value: keyframeIntervalBinding,
                    range: 0.5...5.0,
                    step: 0.5,
                    valueText: "\(String(format: "%.1fs", effectiveProfile.keyframeInterval))"
                )

                Toggle("Adaptive Quality", isOn: profileBinding(\.adaptive, markCustom: false))
                Toggle("Prefer Hardware Encoder", isOn: profileBinding(\.prefersHardwareAcceleration, markCustom: false))

                Text("Native Screen Q applies bitrate, FPS, scaling, codec preference, keyframe interval, JPEG fallback quality, adaptive mode, and hardware preference. VNC and RDP currently apply the viewer-side cadence and rendering limits they expose.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .disabled(streamProfile == nil)
    }

    private func parameterSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range, step: step)
        }
    }

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { quality },
            set: { applyPresetQuality($0) }
        )
    }

    private var modeBinding: Binding<StreamOptimizationMode> {
        Binding(
            get: { effectiveProfile.mode },
            set: { applyMode($0) }
        )
    }

    private var bitrateBinding: Binding<Double> {
        Binding(
            get: { Double(effectiveProfile.maxBitrate) / 1_000_000.0 },
            set: { value in
                mutateProfile { next in
                    next.maxBitrate = Int((value * 1_000_000.0).rounded())
                }
            }
        )
    }

    private var fpsBinding: Binding<Double> {
        Binding(
            get: { Double(effectiveProfile.targetFPS) },
            set: { value in
                mutateProfile { next in
                    next.targetFPS = Int(value.rounded())
                }
            }
        )
    }

    private var compressionQualityBinding: Binding<Double> {
        Binding(
            get: { effectiveProfile.quality },
            set: { value in
                mutateProfile { next in
                    next.quality = min(max(value, 0.1), 1.0)
                }
            }
        )
    }

    private var keyframeIntervalBinding: Binding<Double> {
        Binding(
            get: { effectiveProfile.keyframeInterval },
            set: { value in
                mutateProfile { next in
                    next.keyframeInterval = min(max(value, 0.5), 10.0)
                }
            }
        )
    }

    private func profileBinding<Value>(_ keyPath: WritableKeyPath<StreamProfile, Value>, markCustom: Bool = true) -> Binding<Value> {
        Binding(
            get: { effectiveProfile[keyPath: keyPath] },
            set: { value in
                mutateProfile(markCustom: markCustom) { next in
                    next[keyPath: keyPath] = value
                }
            }
        )
    }

    private func applyPresetQuality(_ value: Double) {
        let preset = StreamQualityPreference(quality: value)
        quality = preset.quality
        streamProfile?.wrappedValue = preset.nativeProfile
    }

    private func applyMode(_ mode: StreamOptimizationMode) {
        switch mode {
        case .lowData:
            applyPresetQuality(0.35)
        case .balanced:
            applyPresetQuality(StreamQualityPreference.defaultQuality)
        case .sharp:
            applyPresetQuality(0.85)
        case .smooth:
            applyPresetQuality(0.95)
        case .custom:
            mutateProfile(markCustom: false) { next in
                next.mode = .custom
            }
        }
    }

    private func mutateProfile(markCustom: Bool = true, _ update: (inout StreamProfile) -> Void) {
        guard let streamProfile else { return }
        var next = streamProfile.wrappedValue
        update(&next)
        if markCustom {
            next.mode = .custom
        }
        streamProfile.wrappedValue = next
    }

    private func qualityPresetButton(_ title: String, value: Double) -> some View {
        Button(title) {
            applyPresetQuality(value)
        }
        .buttonStyle(.bordered)
    }

    private func profileRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    private func formatMbps(_ bitsPerSecond: Int) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000.0)
    }
}
