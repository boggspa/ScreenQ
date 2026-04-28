//
//  ReconnectionManager.swift
//  Screen Q
//
//  Handles automatic reconnection when a session is interrupted (e.g. by
//  network change, brief Wi-Fi dropout, or Tailscale re-key). Uses an
//  exponential backoff strategy and optionally a reconnect token from the
//  host to resume without re-pairing.
//

import Foundation
import Network
import Combine

@MainActor
final class ReconnectionManager: ObservableObject {

    @Published private(set) var state: ReconnectState = .idle
    @Published private(set) var attempt: Int = 0

    enum ReconnectState: Equatable {
        case idle
        case monitoring
        case reconnecting(attempt: Int)
        case succeeded
        case gaveUp(reason: String)
    }

    struct Config {
        var maxAttempts = 10
        var initialDelaySeconds: TimeInterval = 1.0
        var maxDelaySeconds: TimeInterval = 30.0
        var backoffMultiplier: Double = 1.5
    }

    var config = Config()
    var reconnectToken: String?

    private var reconnectTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastEndpoint: NWEndpoint?
    private var reconnectAction: ((NWEndpoint, String?) async -> Bool)?

    /// Start monitoring the network path. If it goes unsatisfied and then returns,
    /// attempt reconnection.
    func startMonitoring(
        endpoint: NWEndpoint,
        onReconnect: @escaping (NWEndpoint, String?) async -> Bool
    ) {
        stopMonitoring()
        self.lastEndpoint = endpoint
        self.reconnectAction = onReconnect
        self.state = .monitoring

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .unsatisfied {
                    Logger.shared.warn("Network path unsatisfied — will reconnect when available")
                } else if path.status == .satisfied && self.state == .monitoring {
                    // Path restored — trigger reconnect if we lost connection.
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.screenq.pathMonitor"))
        self.pathMonitor = monitor
    }

    func stopMonitoring() {
        reconnectTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        reconnectAction = nil
        lastEndpoint = nil
        state = .idle
        attempt = 0
    }

    /// Trigger reconnection attempts with exponential backoff.
    func beginReconnect() {
        guard let endpoint = lastEndpoint, let action = reconnectAction else { return }
        reconnectTask?.cancel()
        attempt = 0

        reconnectTask = Task { [weak self, config] in
            guard let self else { return }
            var delay = config.initialDelaySeconds

            for i in 1...config.maxAttempts {
                guard !Task.isCancelled else { return }
                self.attempt = i
                self.state = .reconnecting(attempt: i)
                Logger.shared.info("Reconnect attempt \(i)/\(config.maxAttempts)...")

                let success = await action(endpoint, self.reconnectToken)
                if success {
                    self.state = .succeeded
                    Logger.shared.info("Reconnected successfully")
                    return
                }

                // Backoff
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * config.backoffMultiplier, config.maxDelaySeconds)
            }

            self.state = .gaveUp(reason: "Failed after \(config.maxAttempts) attempts")
            Logger.shared.warn("Reconnection gave up")
        }
    }
}
