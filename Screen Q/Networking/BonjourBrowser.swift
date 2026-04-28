//
//  BonjourBrowser.swift
//  Screen Q
//
//  Browses _screenq._tcp on the local network. Optionally browses _rfb._tcp
//  too (purely as a discovery hint so the UI can show "you also have a
//  native Mac Screen Sharing host nearby"; we do not implement RFB/VNC).
//

import Foundation
import Network

/// Observable snapshot of the browser's current state, published to the UI.
nonisolated struct BrowserStatus: Sendable, Equatable {
    var isBrowsing: Bool = false
    var screenQCount: Int = 0
    var rfbCount: Int = 0
    var browserError: String? = nil

    var bonjourHealthy: Bool { rfbCount > 0 || screenQCount > 0 }
    var summary: String {
        if let browserError { return browserError }
        if !isBrowsing { return "Not searching" }
        if screenQCount > 0 { return "Found \(screenQCount) Screen Q host\(screenQCount == 1 ? "" : "s")" }
        if rfbCount > 0 {
            return "No Screen Q hosts yet (\(rfbCount) native Screen Sharing host\(rfbCount == 1 ? "" : "s") detected — Bonjour is working)"
        }
        return "Searching for Screen Q hosts on your local network…"
    }
}

actor BonjourBrowser {

    private var screenQBrowser: NWBrowser?
    private var rfbBrowser: NWBrowser?
    private(set) var isBrowsing = false
    private(set) var rfbCount: Int = 0
    private(set) var lastBrowserError: String? = nil

    private var current: [String: DiscoveredHost] = [:]
    private var currentRFB: [String: DiscoveredHost] = [:]
    private var streamContinuation: AsyncStream<[DiscoveredHost]>.Continuation?
    private var rfbStreamContinuation: AsyncStream<[DiscoveredHost]>.Continuation?
    private var statusContinuation: AsyncStream<BrowserStatus>.Continuation?

    /// Stream of latest discovered host snapshots (replaces previous on update).
    func hostsStream() -> AsyncStream<[DiscoveredHost]> {
        AsyncStream { continuation in
            self.streamContinuation = continuation
            continuation.onTermination = { _ in
                Task { await self.handleStreamTermination() }
            }
            continuation.yield(Array(self.current.values))
        }
    }

    /// Stream of RFB/Apple Screen Sharing host snapshots.
    func rfbHostsStream() -> AsyncStream<[DiscoveredHost]> {
        AsyncStream { continuation in
            self.rfbStreamContinuation = continuation
            continuation.yield(Array(self.currentRFB.values))
        }
    }

    /// Stream of browser status snapshots for the UI.
    func statusStream() -> AsyncStream<BrowserStatus> {
        AsyncStream { continuation in
            self.statusContinuation = continuation
            continuation.yield(currentStatus())
        }
    }

    func currentStatus() -> BrowserStatus {
        BrowserStatus(
            isBrowsing: isBrowsing,
            screenQCount: current.count,
            rfbCount: rfbCount,
            browserError: lastBrowserError
        )
    }

    func start(includeRFBHint: Bool = true) {
        stop()
        isBrowsing = true
        lastBrowserError = nil

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: ScreenQProtocol.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.stateUpdateHandler = { [weak self] state in
            Logger.shared.debug("Screen Q browser state: \(String(describing: state))")
            Task { await self?.handleBrowserState(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Logger.shared.debug("Screen Q browse results updated: \(results.count) result(s)")
            Task { await self?.handleResults(results, kind: .screenQ) }
        }
        browser.start(queue: .global(qos: .userInitiated))
        self.screenQBrowser = browser

        if includeRFBHint {
            let rfb = NWBrowser(
                for: .bonjour(type: ScreenQProtocol.rfbServiceType, domain: nil),
                using: params
            )
            rfb.stateUpdateHandler = { [weak self] state in
                Logger.shared.debug("RFB browser state: \(String(describing: state))")
                Task { await self?.handleRFBBrowserState(state) }
            }
            rfb.browseResultsChangedHandler = { [weak self] results, _ in
                Logger.shared.debug("RFB browse results updated: \(results.count) result(s)")
                Task { await self?.handleResults(results, kind: .rfb) }
            }
            rfb.start(queue: .global(qos: .userInitiated))
            self.rfbBrowser = rfb
        }

        Logger.shared.info("Bonjour browser started (screenQ type: \(ScreenQProtocol.bonjourServiceType), RFB: \(includeRFBHint))")
    }

    func stop() {
        screenQBrowser?.cancel()
        screenQBrowser = nil
        rfbBrowser?.cancel()
        rfbBrowser = nil
        isBrowsing = false
        rfbCount = 0
        current.removeAll()
        currentRFB.removeAll()
        streamContinuation?.yield([])
        rfbStreamContinuation?.yield([])
        publishStatus()
        Logger.shared.info("Bonjour browser stopped")
    }

    /// Resolve a discovered host to an NWEndpoint suitable for NWConnection.
    func endpoint(for host: DiscoveredHost) -> NWEndpoint? {
        let pool = host.isRFB ? rfbResults : currentResults
        if let result = pool.first(where: { resultIdentity($0) == host.id }) {
            return result.endpoint
        }
        return nil
    }

    // MARK: - Internals

    private enum Kind { case screenQ, rfb }
    private var currentResults: [NWBrowser.Result] = []
    private var rfbResults: [NWBrowser.Result] = []

    private func handleResults(_ results: Set<NWBrowser.Result>, kind: Kind) {
        if kind == .screenQ {
            currentResults = Array(results)
            var next: [String: DiscoveredHost] = [:]
            for r in results {
                let id = resultIdentity(r)
                let displayName: String = {
                    if case .service(let name, _, _, _) = r.endpoint { return name }
                    return id
                }()
                let txt = txtDictionary(from: r.metadata)
                let host = DiscoveredHost(
                    id: id,
                    displayName: txt[ScreenQProtocol.TXT.deviceName] ?? displayName,
                    txtRecord: txt,
                    endpointDescription: String(describing: r.endpoint),
                    source: .screenQ
                )
                next[id] = host
            }
            current = next
            streamContinuation?.yield(Array(next.values).sorted { $0.displayName < $1.displayName })
        } else {
            rfbResults = Array(results)
            rfbCount = results.count
            var next: [String: DiscoveredHost] = [:]
            for r in results {
                let id = resultIdentity(r)
                let (displayName, serviceName): (String, String?) = {
                    if case .service(let name, _, _, _) = r.endpoint { return (name, name) }
                    return (id, nil)
                }()
                let host = DiscoveredHost(
                    id: id,
                    displayName: displayName,
                    txtRecord: txtDictionary(from: r.metadata),
                    endpointDescription: String(describing: r.endpoint),
                    source: .rfb,
                    serviceName: serviceName
                )
                next[id] = host
            }
            currentRFB = next
            rfbStreamContinuation?.yield(Array(next.values).sorted { $0.displayName < $1.displayName })
            Logger.shared.debug("Detected \(results.count) RFB/Screen Sharing hosts on LAN")
        }
        publishStatus()
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .failed(let err):
            lastBrowserError = Self.userFacingBrowserError(err)
            isBrowsing = false
        case .cancelled:
            isBrowsing = false
        case .ready:
            lastBrowserError = nil
        default:
            break
        }
        publishStatus()
    }

    private func handleRFBBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .failed(let err):
            let message = Self.userFacingBrowserError(err)
            if Self.isLocalNetworkAuthorizationError(err) || lastBrowserError == nil {
                lastBrowserError = message
            }
        case .ready:
            if lastBrowserError?.contains("Local Network") == true {
                lastBrowserError = nil
            }
        default:
            break
        }
        publishStatus()
    }

    private nonisolated static func userFacingBrowserError(_ error: NWError) -> String {
        if isLocalNetworkAuthorizationError(error) {
            return "Local Network discovery is blocked. Enable Local Network for Screen Q in Settings, and ensure the app bundle declares _screenq._tcp. and _rfb._tcp. Bonjour services."
        }
        return error.localizedDescription
    }

    private nonisolated static func isLocalNetworkAuthorizationError(_ error: NWError) -> Bool {
        let raw = String(describing: error)
        return raw.contains("NoAuth") || raw.contains("-65555")
    }

    private func publishStatus() {
        statusContinuation?.yield(currentStatus())
    }

    private func handleStreamTermination() {
        streamContinuation = nil
    }

    private func resultIdentity(_ r: NWBrowser.Result) -> String {
        switch r.endpoint {
        case .service(let name, let type, let domain, _):
            return "\(name).\(type).\(domain)"
        default:
            return String(describing: r.endpoint)
        }
    }

    private func txtDictionary(from meta: NWBrowser.Result.Metadata) -> [String: String] {
        guard case .bonjour(let txt) = meta else { return [:] }
        return txt.dictionary
    }
}
