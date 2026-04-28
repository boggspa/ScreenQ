//
//  BonjourAdvertiser.swift
//  Screen Q
//
//  Advertises this device as a Screen Q host on the local network using
//  Bonjour (_screenq._tcp). The TXT record carries our friendly metadata so
//  viewers can prefilter hosts before connecting. The actual TCP listener
//  lives in ConnectionManager; we only own the discovery surface here.
//

import Foundation
import Network

actor BonjourAdvertiser {

    private var listener: NWListener?
    private var port: UInt16 = ScreenQProtocol.defaultPort
    private(set) var isAdvertising = false
    /// The port the listener is actually bound to (may differ from requested if .any was used).
    private(set) var boundPort: UInt16 = 0
    private var onAccept: (@Sendable (NWConnection) -> Void)?

    func start(
        port: UInt16 = ScreenQProtocol.defaultPort,
        deviceName: String,
        capabilities: Capabilities,
        onAccept: @escaping @Sendable (NWConnection) -> Void
    ) async throws {
        try? stop()
        self.port = port
        self.onAccept = onAccept

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true

        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: parameters, on: endpointPort)

        let txt = makeTXTRecord(deviceName: deviceName, capabilities: capabilities)
        listener.service = NWListener.Service(
            name: deviceName,
            type: ScreenQProtocol.bonjourServiceType,
            domain: nil,
            txtRecord: txt
        )

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNew(connection) }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        self.isAdvertising = true
        Logger.shared.info("Bonjour advertiser started on port \(port) as '\(deviceName)'")
    }

    func stop() throws {
        listener?.cancel()
        listener = nil
        isAdvertising = false
        Logger.shared.info("Bonjour advertiser stopped")
    }

    func updateCapabilities(deviceName: String, capabilities: Capabilities) {
        let txt = makeTXTRecord(deviceName: deviceName, capabilities: capabilities)
        listener?.service = NWListener.Service(
            name: deviceName,
            type: ScreenQProtocol.bonjourServiceType,
            domain: nil,
            txtRecord: txt
        )
    }

    // MARK: - Internals

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let actualPort = listener?.port?.rawValue {
                boundPort = actualPort
            }
            Logger.shared.info("Listener ready on port \(boundPort)")
        case .failed(let err):
            Logger.shared.error("Listener failed: \(err.localizedDescription)")
            isAdvertising = false
        case .cancelled:
            isAdvertising = false
        default:
            break
        }
    }

    /// Returns the set of connectable addresses and the bound port for the host UI.
    func listeningInfo() -> (port: UInt16, addresses: [LocalInterface]) {
        (boundPort == 0 ? port : boundPort, NetworkInterfaces.connectableAddresses())
    }

    private func handleNew(_ connection: NWConnection) {
        Logger.shared.info("Incoming connection from \(connection.endpoint)")
        onAccept?(connection)
    }

    private func makeTXTRecord(deviceName: String, capabilities: Capabilities) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt[ScreenQProtocol.TXT.app] = "ScreenQ"
        txt[ScreenQProtocol.TXT.version] = "1"
        txt[ScreenQProtocol.TXT.platform] = currentPlatformString()
        txt[ScreenQProtocol.TXT.supportsControl] = capabilities.supportsControl ? "true" : "false"
        txt[ScreenQProtocol.TXT.supportsVideo] = capabilities.supportsVideo ? "true" : "false"
        txt[ScreenQProtocol.TXT.deviceName] = String(deviceName.prefix(60))
        return txt
    }

    private func currentPlatformString() -> String {
        // Bonjour advertising is only used by macOS hosts in the MVP; the
        // iOS / iPadOS view-only flow uses ReplayKit, not advertising. We
        // therefore avoid touching the MainActor-only UIDevice from here.
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "unknown"
        #endif
    }
}
