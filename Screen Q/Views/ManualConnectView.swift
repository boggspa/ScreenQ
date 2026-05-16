//
//  ManualConnectView.swift
//  Screen Q
//

import SwiftUI
import UniformTypeIdentifiers

struct ManualConnectView: View {

    @State private var hostText: String = ""
    @State private var portText: String = String(ScreenQProtocol.defaultPort)
    @State private var selectedProtocol: RemoteConnectionProtocol = .screenQ
    @State private var probeResult: ProbeResult?
    @State private var isProbing = false
    @State private var isImportingRDP = false
    @State private var shouldLaunchRDPImporter = false
    @State private var importedRDPProfile: RDPConnectionProfile?
    @State private var importError: String?
    @State private var wakeMACText: String = ""
    var onConnect: (String, UInt16, RemoteConnectionProtocol, String?) -> Void
    var onImportRDP: (RDPConnectionProfile) -> Void

    init(
        initialProtocol: RemoteConnectionProtocol = .screenQ,
        launchRDPImporter: Bool = false,
        onConnect: @escaping (String, UInt16, RemoteConnectionProtocol) -> Void,
        onImportRDP: @escaping (RDPConnectionProfile) -> Void = { _ in }
    ) {
        self._selectedProtocol = State(initialValue: initialProtocol)
        self._portText = State(initialValue: String(initialProtocol.defaultPort))
        self._shouldLaunchRDPImporter = State(initialValue: launchRDPImporter)
        self.onConnect = { host, port, connectionProtocol, _ in
            onConnect(host, port, connectionProtocol)
        }
        self.onImportRDP = onImportRDP
    }

    init(
        initialProtocol: RemoteConnectionProtocol = .screenQ,
        launchRDPImporter: Bool = false,
        onConnectWithWake: @escaping (String, UInt16, RemoteConnectionProtocol, String?) -> Void,
        onImportRDP: @escaping (RDPConnectionProfile) -> Void = { _ in }
    ) {
        self._selectedProtocol = State(initialValue: initialProtocol)
        self._portText = State(initialValue: String(initialProtocol.defaultPort))
        self._shouldLaunchRDPImporter = State(initialValue: launchRDPImporter)
        self.onConnect = onConnectWithWake
        self.onImportRDP = onImportRDP
    }

    init(
        initialProtocol: RemoteConnectionProtocol = .screenQ,
        launchRDPImporter: Bool = false,
        onConnect: @escaping (String, UInt16) -> Void
    ) {
        self._selectedProtocol = State(initialValue: initialProtocol)
        self._portText = State(initialValue: String(initialProtocol.defaultPort))
        self._shouldLaunchRDPImporter = State(initialValue: launchRDPImporter)
        self.onConnect = { host, port, _, _ in onConnect(host, port) }
        self.onImportRDP = { _ in }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SQSectionHeader(
                "Manual / Tailscale connect",
                subtitle: "LAN, VPN, or Tailscale MagicDNS / private IP."
            )

            quickFillRow

            connectionFieldsRow

            protocolHint

            wakeMACField

            if let importError {
                SQErrorRecovery(
                    title: "Import error",
                    message: importError,
                    retryTitle: "Dismiss",
                    onRetry: { self.importError = nil }
                )
            }

            probeFeedback

            actionRow
        }
        .fileImporter(
            isPresented: $isImportingRDP,
            allowedContentTypes: [.rdpDocument],
            allowsMultipleSelection: false
        ) { result in
            importRDP(result)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenQCard(tint: protocolTint)
        .overlay(
            Group {
                if isProbing {
                    SQLoadingScrim(
                        title: "Checking host…",
                        subtitle: trimmedHost.isEmpty ? nil : trimmedHost,
                        tint: .white
                    )
                    .allowsHitTesting(false)
                }
            },
            alignment: .center
        )
        .onAppear {
            guard shouldLaunchRDPImporter else { return }
            shouldLaunchRDPImporter = false
            selectedProtocol = .rdp
            isImportingRDP = true
        }
    }

    // MARK: - Quick fill (this device's addresses)

    @ViewBuilder
    private var quickFillRow: some View {
        let addrs = NetworkInterfaces.connectableAddresses()
        if !addrs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("This device's addresses")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                CompatFlowLayout(spacing: 6) {
                    ForEach(addrs) { iface in
                        Button {
                            SQHaptics.tap()
                            hostText = iface.address
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: iface.kind == .tailscale ? "network" : "wifi")
                                    .font(.system(size: 11, weight: .semibold))
                                    .accessibilityHidden(true)
                                Text(iface.address)
                                    .font(.sqCaption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundColor(iface.kind == .tailscale ? ScreenQTheme.cosmicMint : ScreenQTheme.cosmicCyan)
                            .background(
                                Capsule().fill(
                                    (iface.kind == .tailscale ? ScreenQTheme.cosmicMint : ScreenQTheme.cosmicCyan)
                                        .opacity(0.18)
                                )
                            )
                            .overlay(
                                Capsule().stroke(
                                    (iface.kind == .tailscale ? ScreenQTheme.cosmicMint : ScreenQTheme.cosmicCyan)
                                        .opacity(0.45),
                                    lineWidth: 0.5
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Host / Port row

    private var connectionFieldsRow: some View {
        HStack(spacing: 10) {
            protocolPicker

            TextField("Hostname or IP", text: $hostText, onCommit: { probe() })
                .textFieldStyle(.roundedBorder)
                .font(.sqBody)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                #endif

            TextField("Port", text: $portText)
                .textFieldStyle(.roundedBorder)
                .font(.sqBody)
                .frame(width: 96)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        }
    }

    private var wakeMACField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Wake MAC address (optional)", text: $wakeMACText)
                .textFieldStyle(.roundedBorder)
                .font(.sqBody)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif

            Text("Saved with this endpoint for Wake-on-LAN. Requires a Mac/NIC that supports network wake and a LAN broadcast path.")
                .font(.sqCaption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Probe feedback

    @ViewBuilder
    private var probeFeedback: some View {
        if let result = probeResult {
            if result.succeeded {
                HStack(spacing: 6) {
                    SQPill(text: "Reachable", status: .healthy)
                    Text(result.friendlyMessage)
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                SQErrorRecovery(
                    title: "Couldn't reach \(trimmedHost.isEmpty ? "host" : trimmedHost)",
                    message: result.friendlyMessage,
                    onRetry: { probe() }
                )
            }
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                SQHaptics.tap()
                probe()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .accessibilityHidden(true)
                    Text("Test")
                }
                .font(.sqHeadline)
                .foregroundColor(protocolTint)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().strokeBorder(protocolTint.opacity(0.55), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .disabled(trimmedHost.isEmpty || isProbing)
            .opacity((trimmedHost.isEmpty || isProbing) ? 0.5 : 1.0)

            Spacer()

            Button {
                SQHaptics.success()
                connect()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .accessibilityHidden(true)
                    Text(connectButtonTitle)
                }
                .font(.sqHeadline)
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(
                        (trimmedHost.isEmpty || isProbing || !selectedProtocol.isAvailable)
                            ? Color.secondary.opacity(0.22)
                            : protocolTint
                    )
                )
            }
            .buttonStyle(.plain)
            .disabled(trimmedHost.isEmpty || isProbing || !selectedProtocol.isAvailable)
            .accessibilityLabel(connectButtonTitle)
        }
    }

    // MARK: - Computed helpers

    private var trimmedHost: String {
        hostText.trimmingCharacters(in: .whitespaces)
    }

    private var resolvedPort: UInt16 {
        UInt16(portText) ?? ScreenQProtocol.defaultPort
    }

    private var connectButtonTitle: String {
        switch selectedProtocol {
        case .screenQ: return "Connect"
        case .macScreenSharing: return "Connect to Mac"
        case .vnc: return "Connect via VNC"
        case .rdp: return "Connect via RDP"
        }
    }

    private var protocolTint: Color {
        switch selectedProtocol {
        case .screenQ: return ScreenQTheme.cosmicCyan
        case .macScreenSharing: return ScreenQTheme.cosmicViolet
        case .vnc: return ScreenQTheme.cosmicTeal
        case .rdp: return ScreenQTheme.cosmicAmber
        }
    }

    @ViewBuilder
    private var protocolHint: some View {
        switch selectedProtocol {
        case .screenQ:
            EmptyView()
        case .macScreenSharing:
            VStack(alignment: .leading, spacing: 5) {
                Label("Use this for a Mac with Screen Sharing or Remote Management enabled, without installing Screen Q on that Mac.", systemImage: "macwindow")
                Label("Screen Q will prefer macOS account login when the Mac offers Apple Screen Sharing authentication.", systemImage: "person.badge.key")
                Label("If the Mac only offers legacy VNC auth, Screen Q will ask for the separate VNC password and label that weaker fallback clearly.", systemImage: "exclamationmark.shield")
                Label(vncSecurityHint, systemImage: vncSecurityIcon)
                    .foregroundColor(vncSecurityTint)
            }
            .font(.sqCaption)
            .foregroundColor(.secondary)
        case .vnc:
            VStack(alignment: .leading, spacing: 5) {
                Label("Generic VNC compatibility: use this for non-Apple VNC servers that require a VNC password.", systemImage: "rectangle.connected.to.line.below")
                Label("This is not macOS admin/user login. Never reuse your Mac login password as a legacy VNC password.", systemImage: "info.circle")
                Label(vncSecurityHint, systemImage: vncSecurityIcon)
                    .foregroundColor(vncSecurityTint)
            }
            .font(.sqCaption)
            .foregroundColor(.secondary)
        case .rdp:
            VStack(alignment: .leading, spacing: 6) {
                Label("RDP: use the Windows PC's Tailscale IP or MagicDNS name with port 3389.", systemImage: "pc")
                Label("Screen Q imports .rdp profiles, stores credentials in Keychain, reviews certificates, and uses the bundled FreeRDP bridge for live sessions.", systemImage: "puzzlepiece.extension")
                Label(rdpSecurityHint, systemImage: rdpSecurityIcon)
                    .foregroundColor(rdpSecurityTint)
                Button {
                    SQHaptics.tap()
                    isImportingRDP = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .accessibilityHidden(true)
                        Text("Import .rdp File")
                    }
                    .font(.sqCaption)
                    .foregroundColor(ScreenQTheme.cosmicAmber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().strokeBorder(ScreenQTheme.cosmicAmber.opacity(0.55), lineWidth: 0.6))
                }
                .buttonStyle(.plain)
            }
            .font(.sqCaption)
            .foregroundColor(.secondary)
        }
    }

    private var protocolPicker: some View {
        Menu {
            Button {
                SQHaptics.tap()
                selectProtocol(.screenQ)
            } label: {
                Label("Screen Q", systemImage: selectedProtocol == .screenQ ? "checkmark" : "display")
            }

            Button {
                SQHaptics.tap()
                selectProtocol(.macScreenSharing)
            } label: {
                Label("Mac Screen Sharing", systemImage: selectedProtocol == .macScreenSharing ? "checkmark" : "macwindow")
            }

            Button {
                SQHaptics.tap()
                selectProtocol(.vnc)
            } label: {
                Label("Generic VNC", systemImage: selectedProtocol == .vnc ? "checkmark" : "rectangle.connected.to.line.below")
            }

            Button {
                SQHaptics.tap()
                selectProtocol(.rdp)
            } label: {
                Label("RDP / Windows", systemImage: selectedProtocol == .rdp ? "checkmark" : "pc")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedProtocol.systemImage)
                    .accessibilityHidden(true)
                Text(selectedProtocol.displayName)
            }
            .font(.sqCallout)
            .foregroundColor(protocolTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 138)
            .background(Capsule().fill(protocolTint.opacity(0.14)))
            .overlay(Capsule().stroke(protocolTint.opacity(0.45), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Protocol: \(selectedProtocol.displayName)")
    }

    private var vncSecurityScope: NetworkTrustScope {
        NetworkTrustScope.classify(host: trimmedHost)
    }

    private var vncSecurityHint: String {
        if trimmedHost.isEmpty {
            return "VNC is not encrypted by Screen Q; use it over Tailscale, VPN, or a private LAN."
        }
        if let warning = vncSecurityScope.publicNetworkWarning {
            return warning
        }
        return "VNC will use the surrounding private network/Tailscale path for transport protection."
    }

    private var vncSecurityIcon: String {
        vncSecurityScope.publicNetworkWarning == nil ? "network.badge.shield.half.filled" : "exclamationmark.shield"
    }

    private var vncSecurityTint: Color {
        vncSecurityScope.publicNetworkWarning == nil ? Color.secondary : ScreenQTheme.cosmicAmber
    }

    private var rdpSecurityScope: NetworkTrustScope {
        NetworkTrustScope.classify(host: trimmedHost)
    }

    private var rdpSecurityHint: String {
        if trimmedHost.isEmpty {
            return "RDP should be used over Tailscale, VPN, or a private LAN unless you intentionally expose it."
        }
        if let warning = rdpSecurityScope.publicNetworkWarning {
            return warning
        }
        return "RDP will still need to negotiate TLS/NLA after the engine is linked; this preflight only checks TCP reachability."
    }

    private var rdpSecurityIcon: String {
        rdpSecurityScope.publicNetworkWarning == nil ? "network.badge.shield.half.filled" : "exclamationmark.shield"
    }

    private var rdpSecurityTint: Color {
        rdpSecurityScope.publicNetworkWarning == nil ? Color.secondary : ScreenQTheme.cosmicAmber
    }

    private func selectProtocol(_ connectionProtocol: RemoteConnectionProtocol) {
        let currentDefault = String(selectedProtocol.defaultPort)
        selectedProtocol = connectionProtocol
        if portText.trimmingCharacters(in: .whitespaces).isEmpty || portText == currentDefault {
            portText = String(connectionProtocol.defaultPort)
        }
        probeResult = nil
        importError = nil
    }

    private func probe() {
        let host = trimmedHost
        guard !host.isEmpty else { return }
        isProbing = true
        probeResult = nil
        Task {
            let result = await ConnectivityProbe.probe(host: host, port: resolvedPort)
            await MainActor.run {
                probeResult = result
                isProbing = false
                if result.succeeded {
                    SQHaptics.success()
                } else {
                    SQHaptics.warning()
                }
            }
        }
    }

    private func connect() {
        let host = trimmedHost
        let port = resolvedPort
        let connectionProtocol = selectedProtocol

        guard !host.isEmpty else { return }
        guard validateWakeMAC() else { return }
        let wakeMAC = WakeOnLAN.normalizedMACString(wakeMACText)

        if connectionProtocol.requiresManualConnectProbe {
            isProbing = true
            probeResult = nil
            Task {
                let result = await ConnectivityProbe.probe(
                    host: host,
                    port: port,
                    timeoutSeconds: ConnectivityProbe.manualVNCProbeTimeoutSeconds(for: host)
                )
                await MainActor.run {
                    isProbing = false
                    guard result.succeeded else {
                        probeResult = result
                        SQHaptics.warning()
                        return
                    }
                    onConnect(host, port, connectionProtocol, wakeMAC)
                }
            }
            return
        }

        if selectedProtocol == .rdp,
           let importedRDPProfile,
           importedRDPProfile.host == host,
           importedRDPProfile.port == port {
            onImportRDP(importedRDPProfile)
            return
        }
        onConnect(host, port, connectionProtocol, wakeMAC)
    }

    private func validateWakeMAC() -> Bool {
        let raw = wakeMACText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            importError = nil
            return true
        }
        guard WakeOnLAN.normalizedMACString(raw) != nil else {
            importError = "Wake MAC must be 12 hex digits, e.g. AA:BB:CC:DD:EE:FF."
            SQHaptics.error()
            return false
        }
        importError = nil
        return true
    }

    private func importRDP(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let text = try String(contentsOf: url, encoding: .utf8)
            let profile = try RDPConnectionProfile(
                rdpFileText: text,
                fallbackDisplayName: url.deletingPathExtension().lastPathComponent
            )
            selectedProtocol = .rdp
            hostText = profile.host
            portText = String(profile.port)
            importedRDPProfile = profile
            importError = nil
            probeResult = nil
            SQHaptics.success()
        } catch {
            importError = error.localizedDescription
            SQHaptics.error()
        }
    }
}

private extension RemoteConnectionProtocol {
    var requiresManualConnectProbe: Bool {
        switch self {
        case .macScreenSharing, .vnc:
            return true
        case .screenQ, .rdp:
            return false
        }
    }
}

private extension UTType {
    static var rdpDocument: UTType {
        UTType(filenameExtension: "rdp") ?? .plainText
    }
}

/// Wrapper that uses FlowLayout on macOS 13+ / iOS 16+ and falls back to
/// a simple wrapping HStack on older versions.
private struct CompatFlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            FlowLayout(spacing: spacing) { content() }
        } else {
            // Simple fallback — wraps items in an HStack
            HStack(spacing: spacing) { content() }
        }
    }
}

/// Minimal horizontal flow layout for the quick-fill address buttons.
@available(macOS 13.0, iOS 16.0, *)
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, pos) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private struct LayoutResult {
        var positions: [CGPoint]
        var size: CGSize
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> LayoutResult {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return LayoutResult(positions: positions, size: CGSize(width: maxX, height: y + rowHeight))
    }
}
