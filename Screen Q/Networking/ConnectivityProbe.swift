//
//  ConnectivityProbe.swift
//  Screen Q
//
//  Lightweight TCP-only probe to check whether a Screen Q listener is
//  reachable at a given host:port before committing to the full protocol
//  handshake. Returns a human-friendly diagnostic string on failure.
//

import Foundation
import Network

nonisolated enum ProbeResult: Sendable, Equatable {
    case reachable
    case connectionRefused
    case timeout
    case dnsFailure(String)
    case networkUnreachable
    case otherError(String)

    var succeeded: Bool { self == .reachable }

    var friendlyMessage: String {
        switch self {
        case .reachable:
            return "Host is reachable."
        case .connectionRefused:
            return "Connection refused — nothing is listening on that port. On the host Mac, tap \"Start Hosting\" in Screen Q."
        case .timeout:
            return "Timed out — the host may be offline, behind a firewall, or on a different network. If using Tailscale, check both devices are signed in to the same tailnet."
        case .dnsFailure(let name):
            return "Could not resolve \"\(name)\". Check the hostname or try a numeric IP address instead."
        case .networkUnreachable:
            return "Network unreachable — check that Wi-Fi or Ethernet is connected."
        case .otherError(let detail):
            return "Connection failed: \(detail)"
        }
    }

    var systemImage: String {
        switch self {
        case .reachable:          return "checkmark.circle.fill"
        case .connectionRefused:  return "xmark.circle"
        case .timeout:            return "clock.badge.exclamationmark"
        case .dnsFailure:         return "questionmark.circle"
        case .networkUnreachable: return "wifi.slash"
        case .otherError:         return "exclamationmark.triangle"
        }
    }
}

nonisolated enum ConnectivityProbe {
    static let fastTimeoutSeconds: TimeInterval = 2
    static let trustedVNCProbeTimeoutSeconds: TimeInterval = 3
    static let routedVNCProbeTimeoutSeconds: TimeInterval = 7

    static func manualVNCProbeTimeoutSeconds(for host: String) -> TimeInterval {
        NetworkTrustScope.classify(host: host).isTrustedPrivateScope
            ? trustedVNCProbeTimeoutSeconds
            : routedVNCProbeTimeoutSeconds
    }

    /// Attempt a bare TCP connect to `host:port` with a timeout.
    /// Resolves to `.reachable` if the TCP handshake completes, or a
    /// diagnostic `ProbeResult` explaining exactly what went wrong.
    static func probe(host: String, port: UInt16, timeoutSeconds: TimeInterval = 5) async -> ProbeResult {
        Logger.shared.info("ConnectivityProbe.probe entry host=\(host):\(port) timeout=\(timeoutSeconds)s")
        // Race the inner NWConnection probe against an outer Task.sleep
        // timeout. This guards against cases where NWConnection sits in
        // .waiting indefinitely (e.g. Tailscale/VPN-routed CGNAT addresses
        // on iOS where the path never becomes viable) and the internal
        // DispatchSource timer never fires.
        let result = await withTaskGroup(of: ProbeResult.self) { group in
            group.addTask {
                Logger.shared.info("ConnectivityProbe: inner probe task starting")
                let r = await probeInner(host: host, port: port, timeoutSeconds: timeoutSeconds)
                Logger.shared.info("ConnectivityProbe: inner probe returned \(r)")
                return r
            }
            group.addTask {
                let nanos = UInt64(max(0, timeoutSeconds + 0.5) * 1_000_000_000)
                Logger.shared.info("ConnectivityProbe: timeout task armed for \(Double(nanos)/1e9)s")
                try? await Task.sleep(nanoseconds: nanos)
                Logger.shared.info("ConnectivityProbe: timeout task firing")
                return .timeout
            }
            let first = await group.next() ?? .timeout
            Logger.shared.info("ConnectivityProbe: first task completed with \(first); cancelling remainder")
            group.cancelAll()
            return first
        }
        Logger.shared.info("ConnectivityProbe.probe exit result=\(result)")
        return result
    }

    private static func probeInner(host: String, port: UInt16, timeoutSeconds: TimeInterval) async -> ProbeResult {
        let continuationBox = ProbeContinuationBox()
        let connBox = NWConnectionBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuationBox.set(continuation)
                let nwHost = NWEndpoint.Host(host)
                let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: ScreenQProtocol.defaultPort)!
                let params = NWParameters.tcp
                let conn = NWConnection(host: nwHost, port: nwPort, using: params)
                connBox.connection = conn

                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + timeoutSeconds)
                timer.setEventHandler {
                    conn.cancel()
                    continuationBox.resume(with: .timeout)
                }
                timer.activate()

                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        timer.cancel()
                        conn.cancel()
                        continuationBox.resume(with: .reachable)

                    case .failed(let error):
                        timer.cancel()
                        conn.cancel()
                        continuationBox.resume(with: classify(error, host: host))

                    case .waiting(let error):
                        let result = classify(error, host: host)
                        if case .dnsFailure = result {
                            timer.cancel()
                            conn.cancel()
                            continuationBox.resume(with: result)
                        } else if case .networkUnreachable = result {
                            timer.cancel()
                            conn.cancel()
                            continuationBox.resume(with: result)
                        }

                    case .cancelled:
                        timer.cancel()
                        continuationBox.resume(with: .otherError("Cancelled"))

                    default:
                        break
                    }
                }

                conn.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connBox.connection?.cancel()
            continuationBox.resume(with: .timeout)
        }
    }

    // MARK: - Error classification

    private static func classify(_ error: NWError, host: String) -> ProbeResult {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:   return .connectionRefused
            case .ETIMEDOUT:      return .timeout
            case .ENETUNREACH,
                 .EHOSTUNREACH:   return .networkUnreachable
            default:              return .otherError(error.localizedDescription)
            }
        case .dns(let dnsCode):
            // Common DNS error codes: -65554 (no such name), etc.
            _ = dnsCode
            return .dnsFailure(host)
        default:
            return .otherError(error.localizedDescription)
        }
    }
}

/// Thread-safe holder that resumes a CheckedContinuation exactly once.
nonisolated private final class ProbeContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<ProbeResult, Never>?
    private let lock = NSLock()

    func set(_ continuation: CheckedContinuation<ProbeResult, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(with result: ProbeResult) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

/// Thread-safe holder for an NWConnection so cancellation handlers can reach it.
nonisolated private final class NWConnectionBox: @unchecked Sendable {
    private var _connection: NWConnection?
    private let lock = NSLock()

    var connection: NWConnection? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _connection
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _connection = newValue
        }
    }
}
