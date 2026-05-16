//
//  StreamQualityControl.swift
//  Screen Q
//

import SwiftUI

/// Embeddable variant for the Settings pane. Owns a `@AppStorage`-backed
/// quality value and a session-less stream profile so the existing
/// `StreamQualityPanel` UI can render as a stand-alone preference editor.
/// Default tuning is sourced from `StreamQualityPreference.defaultQuality`.
struct StreamQualityPanelDefaults: View {

    @AppStorage("ScreenQ.Defaults.StreamQuality")
    private var storedQuality: Double = StreamQualityPreference.defaultQuality
    @State private var profile: StreamProfile = StreamQualityPreference().nativeProfile
    @State private var didHydrateProfile = false

    var body: some View {
        StreamQualityPanel(
            quality: $storedQuality,
            streamProfile: $profile,
            stats: nil,
            protocolName: "default",
            detail: "Applies as the starting point for new sessions. Each active session keeps its own override while connected."
        )
        .onAppear {
            guard !didHydrateProfile else { return }
            didHydrateProfile = true
            profile = StreamQualityPreference(quality: storedQuality).nativeProfile
        }
    }
}

struct StreamQualityButton: View {
    @Binding private var quality: Double
    private var profile: Binding<StreamProfile>?
    private var stats: TransportStats?
    var protocolName: String
    var detail: String
    var compact: Bool = true

    @State private var isPresented = false

    init(
        quality: Binding<Double>,
        profile: Binding<StreamProfile>? = nil,
        stats: TransportStats? = nil,
        protocolName: String,
        detail: String,
        compact: Bool = true
    ) {
        self._quality = quality
        self.profile = profile
        self.stats = stats
        self.protocolName = protocolName
        self.detail = detail
        self.compact = compact
    }

    var body: some View {
        Button {
            #if os(iOS)
            SQHaptics.tap()
            #endif
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
                stats: stats,
                protocolName: protocolName,
                detail: detail
            )
            .frame(width: 360)
            .padding(16)
        }
    }
}

// MARK: - StreamQualityPanel

/// The shared quality / compression / advanced-parameters surface. Hosted
/// inside `StreamQualityButton`'s popover during a session and embedded in
/// the unified Settings pane (`SettingsScene.Tab.streamQuality`).
///
/// The original session-side initializer takes a `quality:` binding plus
/// optional `streamProfile`/`stats`/`protocolName`/`detail`. A second,
/// preference-based convenience init is provided for the Settings pane —
/// it owns an internal default-quality binding so the surface works as a
/// standalone preference editor with no live session attached.
struct StreamQualityPanel: View {
    @Binding var quality: Double
    var streamProfile: Binding<StreamProfile>?
    var stats: TransportStats?
    var protocolName: String
    var detail: String

    init(
        quality: Binding<Double>,
        streamProfile: Binding<StreamProfile>? = nil,
        stats: TransportStats? = nil,
        protocolName: String,
        detail: String
    ) {
        self._quality = quality
        self.streamProfile = streamProfile
        self.stats = stats
        self.protocolName = protocolName
        self.detail = detail
    }

    private var preference: StreamQualityPreference {
        StreamQualityPreference(quality: quality)
    }

    private var effectiveProfile: StreamProfile {
        streamProfile?.wrappedValue ?? preference.nativeProfile
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SQSectionHeader("Quality", subtitle: "\(preference.percent)% · \(preference.estimatedBitrateText(protocolName: protocolName))")

                Slider(value: qualityBinding, in: StreamQualityPreference.allowedRange)
                    .accentColor(ScreenQTheme.cosmicCyan)
                    .onChange(of: quality) { _ in
                        #if os(iOS)
                        SQHaptics.tap()
                        #endif
                    }

                summaryRows

                if let stats {
                    StreamLatencyDiagnostics(stats: stats) {
                        #if os(iOS)
                        SQHaptics.bump()
                        #endif
                        applyResponsivePreset()
                    }
                }

                Text(detail)
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                SQSectionHeader("Presets")
                presetButtons

                Divider()

                advancedControls
            }
        }
        .screenQCard(padding: 14)
    }

    private var summaryRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            profileRow("Mode", effectiveProfile.mode.label)
            profileRow("Scaling", effectiveProfile.scalePolicy.label)
            profileRow("Codec", effectiveProfile.codecPreference.label)
            profileRow("Detail", effectiveProfile.usesViewportAwareDetail ? "Viewport-aware" : "Full-frame")
            profileRow("Ceiling", "\(formatMbps(effectiveProfile.maxBitrate)) / \(effectiveProfile.targetFPS) fps")
        }
        .font(.sqCaption)
    }

    private var presetButtons: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ], spacing: 8) {
            responsivePresetButton
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
                Toggle("Viewport-Aware Detail", isOn: viewportAwareDetailBinding)
                Toggle("Prefer Hardware Encoder", isOn: profileBinding(\.prefersHardwareAcceleration, markCustom: false))

                Text("Native Screen Q applies bitrate, FPS, scaling, codec preference, keyframe interval, JPEG fallback quality, adaptive mode, viewport-aware detail, and hardware preference. VNC and RDP currently apply the viewer-side cadence and rendering limits they expose.")
                    .font(.sqCaption)
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
            .font(.sqCaption)
            Slider(value: value, in: range, step: step)
                .accentColor(ScreenQTheme.cosmicCyan)
        }
    }

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { quality },
            set: { applySliderQuality($0) }
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

    private var viewportAwareDetailBinding: Binding<Bool> {
        Binding(
            get: { effectiveProfile.usesViewportAwareDetail },
            set: { value in
                mutateProfile(markCustom: false) { next in
                    next.viewportAwareDetail = value
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

    private func applySliderQuality(_ value: Double) {
        applyPresetQuality(value, modeOverride: nil)
    }

    private func applyPresetQuality(_ value: Double, modeOverride: StreamOptimizationMode? = nil) {
        let preset = StreamQualityPreference(quality: value)
        quality = preset.quality
        guard let streamProfile else { return }
        let current = streamProfile.wrappedValue
        var next = preset.nativeProfile
        next.mode = modeOverride ?? current.mode
        next.scalePolicy = current.scalePolicy
        next.codecPreference = current.codecPreference
        next.keyframeInterval = current.keyframeInterval
        next.adaptive = current.adaptive
        next.prefersHardwareAcceleration = current.prefersHardwareAcceleration
        next.viewportAwareDetail = current.viewportAwareDetail
        streamProfile.wrappedValue = next
    }

    private func applyMode(_ mode: StreamOptimizationMode) {
        switch mode {
        case .lowData:
            applyPresetQuality(0.35, modeOverride: mode)
        case .balanced:
            applyPresetQuality(StreamQualityPreference.defaultQuality, modeOverride: mode)
        case .sharp:
            applyPresetQuality(0.85, modeOverride: mode)
        case .smooth:
            applyPresetQuality(0.95, modeOverride: mode)
        case .custom:
            mutateProfile(markCustom: false) { next in
                next.mode = .custom
            }
        }
    }

    private func applyResponsivePreset() {
        quality = 0.45
        streamProfile?.wrappedValue = StreamProfile(
            mode: .custom,
            scalePolicy: .balancedDownscale,
            codecPreference: .h264,
            maxBitrate: 4_000_000,
            targetFPS: 30,
            quality: 0.58,
            keyframeInterval: 1.0,
            adaptive: true,
            prefersHardwareAcceleration: true,
            viewportAwareDetail: true
        )
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
        let isSelected = abs(quality - value) < 0.02
        return Button {
            #if os(iOS)
            SQHaptics.tap()
            #endif
            applyPresetQuality(value, modeOverride: modeForPresetValue(value))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.sqCaption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .foregroundColor(isSelected ? .white : ScreenQTheme.cosmicCyan)
            .background(
                Capsule().fill(
                    isSelected
                        ? ScreenQTheme.cosmicCyan
                        : ScreenQTheme.cosmicCyan.opacity(0.15)
                )
            )
            .overlay(
                Capsule().stroke(ScreenQTheme.cosmicCyan.opacity(isSelected ? 0 : 0.45), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func modeForPresetValue(_ value: Double) -> StreamOptimizationMode {
        switch value {
        case ..<0.48:
            return .lowData
        case 0.48..<0.78:
            return .balanced
        case 0.78..<0.92:
            return .sharp
        default:
            return .smooth
        }
    }

    private var responsivePresetButton: some View {
        Button {
            #if os(iOS)
            SQHaptics.bump()
            #endif
            applyResponsivePreset()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
                Text("Responsive")
                    .font(.sqCaption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .foregroundColor(.white)
            .background(
                Capsule().fill(ScreenQTheme.accent(ScreenQTheme.cosmicAmber))
            )
        }
        .buttonStyle(.plain)
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

private struct StreamLatencyDiagnostics: View {
    @ObservedObject var stats: TransportStats
    let applyResponsivePreset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Live latency", systemImage: "timer")
                    .font(.sqCaption)
                Spacer()
                SQPill(text: statusText, status: statusKind, compact: true)
            }

            metricRow("Frame delay", formatMillis(stats.frameLatencyMillis))
            metricRow("Network RTT", formatMillis(stats.roundTripMillis))
            metricRow("Recent peak", formatMillis(stats.peakFrameLatencyMillis))

            if shouldSuggestResponsive {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Delay is elevated. Lower bitrate/FPS pressure for faster feedback.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        #if os(iOS)
                        SQHaptics.bump()
                        #endif
                        applyResponsivePreset()
                    } label: {
                        Text("Apply Responsive")
                            .font(.sqCaption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundColor(.white)
                            .background(Capsule().fill(ScreenQTheme.cosmicAmber))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .font(.sqCaption)
    }

    private var observedLatency: Double {
        max(stats.frameLatencyMillis, stats.roundTripMillis)
    }

    private var statusText: String {
        guard observedLatency > 0 else { return "Measuring" }
        if observedLatency < 80 { return "Low" }
        if observedLatency < 160 { return "Elevated" }
        return "High"
    }

    private var statusKind: SQStatus {
        guard observedLatency > 0 else { return .muted }
        if observedLatency < 80 { return .healthy }
        if observedLatency < 160 { return .attention }
        return .error
    }

    private var shouldSuggestResponsive: Bool {
        stats.frameLatencyMillis >= 120 ||
        stats.peakFrameLatencyMillis >= 180 ||
        stats.roundTripMillis >= 90
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.sqCaption.monospacedDigit())
        }
    }

    private func formatMillis(_ value: Double) -> String {
        guard value > 0 else { return "Measuring" }
        return String(format: "%.0f ms", value)
    }
}
