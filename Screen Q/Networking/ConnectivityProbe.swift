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
        await withCheckedContinuation { continuation in
            let nwHost = NWEndpoint.Host(host)
            let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: ScreenQProtocol.defaultPort)!
            let params = NWParameters.tcp
            let conn = NWConnection(host: nwHost, port: nwPort, using: params)

            let done = LockedFlag()

            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                guard done.setIfFirst() else { return }
                conn.cancel()
                continuation.resume(returning: .timeout)
            }
            timer.activate()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard done.setIfFirst() else { return }
                    timer.cancel()
                    conn.cancel()
                    continuation.resume(returning: .reachable)

                case .failed(let error):
                    guard done.setIfFirst() else { return }
                    timer.cancel()
                    conn.cancel()
                    continuation.resume(returning: classify(error, host: host))

                case .waiting(let error):
                    // .waiting typically means path not satisfied yet;
                    // if it's a DNS or unreachable error, bail early.
                    let result = classify(error, host: host)
                    if case .dnsFailure = result {
                        guard done.setIfFirst() else { return }
                        timer.cancel()
                        conn.cancel()
                        continuation.resume(returning: result)
                    }
                    if case .networkUnreachable = result {
                        guard done.setIfFirst() else { return }
                        timer.cancel()
                        conn.cancel()
                        continuation.resume(returning: result)
                    }

                case .cancelled:
                    // Only fire if nobody else claimed the continuation.
                    guard done.setIfFirst() else { return }
                    timer.cancel()
                    continuation.resume(returning: .otherError("Cancelled"))

                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInitiated))
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

/// Thread-safe one-shot flag to ensure a continuation is resumed exactly once.
nonisolated private final class LockedFlag: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()

    /// Returns `true` the first time it's called; `false` thereafter.
    func setIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
