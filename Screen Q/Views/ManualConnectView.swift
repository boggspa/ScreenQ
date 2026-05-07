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
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual / Tailscale connect")
                .font(.title3).bold()
            Text("Works with LAN, VPN, or Tailscale MagicDNS / private IP (e.g. mac-mini.tailnet.ts.net or 100.65.4.12).")
                .font(.footnote)
                .foregroundColor(.secondary)

            // Quick-fill buttons for detected addresses
            let addrs = NetworkInterfaces.connectableAddresses()
            if !addrs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This device's addresses:")
                        .font(.caption).foregroundColor(.secondary)
                    CompatFlowLayout(spacing: 6) {
                        ForEach(addrs) { iface in
                            Button {
                                hostText = iface.address
                            } label: {
                                Label(iface.address, systemImage: iface.kind == .tailscale ? "network" : "wifi")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                protocolPicker

                TextField("Hostname or IP", text: $hostText, onCommit: { probe() })
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled(true)
                    #endif

                TextField("Port", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }

            protocolHint

            TextField("Wake MAC address (optional)", text: $wakeMACText)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif

            Text("Saved with this endpoint for Wake-on-LAN. It requires a Mac/NIC that supports network wake and a LAN broadcast path.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Probe result inline
            if let result = probeResult {
                HStack(spacing: 6) {
                    Image(systemName: result.systemImage)
                        .foregroundColor(result.succeeded ? .green : .red)
                    Text(result.friendlyMessage)
                        .font(.footnote)
                        .foregroundColor(result.succeeded ? Color.primary : Color.red)
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("Test Connection") { probe() }
                    .buttonStyle(.bordered)
                    .disabled(trimmedHost.isEmpty || isProbing)

                if isProbing {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button(connectButtonTitle) { connect() }
                    .buttonStyle(.bordered)
                    .disabled(trimmedHost.isEmpty || isProbing || !selectedProtocol.isAvailable)
            }
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gray.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .onAppear {
            guard shouldLaunchRDPImporter else { return }
            shouldLaunchRDPImporter = false
            selectedProtocol = .rdp
            isImportingRDP = true
        }
    }

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
            .font(.caption)
            .foregroundColor(.secondary)
        case .vnc:
            VStack(alignment: .leading, spacing: 5) {
                Label("Generic VNC compatibility: use this for non-Apple VNC servers that require a VNC password.", systemImage: "rectangle.connected.to.line.below")
                Label("This is not macOS admin/user login. Never reuse your Mac login password as a legacy VNC password.", systemImage: "info.circle")
                Label(vncSecurityHint, systemImage: vncSecurityIcon)
                    .foregroundColor(vncSecurityTint)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        case .rdp:
            VStack(alignment: .leading, spacing: 6) {
                Label("RDP: use the Windows PC's Tailscale IP or MagicDNS name with port 3389.", systemImage: "pc")
                Label("Screen Q imports .rdp profiles, stores credentials in Keychain, reviews certificates, and uses the bundled FreeRDP bridge for live sessions.", systemImage: "puzzlepiece.extension")
                Label(rdpSecurityHint, systemImage: rdpSecurityIcon)
                    .foregroundColor(rdpSecurityTint)
                Button {
                    isImportingRDP = true
                } label: {
                    Label("Import .rdp File", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var protocolPicker: some View {
        Menu {
            Button {
                selectProtocol(.screenQ)
            } label: {
                Label("Screen Q", systemImage: selectedProtocol == .screenQ ? "checkmark" : "display")
            }

            Button {
                selectProtocol(.macScreenSharing)
            } label: {
                Label("Mac Screen Sharing", systemImage: selectedProtocol == .macScreenSharing ? "checkmark" : "macwindow")
            }

            Button {
                selectProtocol(.vnc)
            } label: {
                Label("Generic VNC", systemImage: selectedProtocol == .vnc ? "checkmark" : "rectangle.connected.to.line.below")
            }

            Button {
                selectProtocol(.rdp)
            } label: {
                Label("RDP / Windows", systemImage: selectedProtocol == .rdp ? "checkmark" : "pc")
            }
        } label: {
            Label(selectedProtocol.displayName, systemImage: selectedProtocol.systemImage)
                .frame(minWidth: 112)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.bordered)
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
        vncSecurityScope.publicNetworkWarning == nil ? .secondary : .orange
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
        rdpSecurityScope.publicNetworkWarning == nil ? .secondary : .orange
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
        } catch {
            importError = error.localizedDescription
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
