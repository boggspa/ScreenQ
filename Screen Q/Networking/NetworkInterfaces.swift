//
//  NetworkInterfaces.swift
//  Screen Q
//
//  Enumerates local network interfaces via getifaddrs(). Classifies each
//  address as LAN, Tailscale, loopback, cellular, or other so the host UI
//  can tell the user exactly what to type on the viewer side.
//

import Foundation

nonisolated enum InterfaceKind: String, Sendable {
    case loopback
    case lan          // en0, en1, bridge… with RFC-1918 or link-local
    case tailscale    // utun* with 100.64–127.x.x.x (CGNAT range)
    case cellular     // pdp_ip0
    case vpn          // utun* that isn't Tailscale
    case other
}

nonisolated struct LocalInterface: Identifiable, Sendable {
    let id: String          // "<name>-<address>"
    let name: String        // e.g. "en0"
    let address: String     // e.g. "192.168.1.42"
    let family: Int32       // AF_INET or AF_INET6
    let kind: InterfaceKind

    var isIPv4: Bool { family == AF_INET }
    var isIPv6: Bool { family == AF_INET6 }

    var humanLabel: String {
        switch kind {
        case .loopback:  return "Loopback"
        case .lan:       return "LAN (\(name))"
        case .tailscale: return "Tailscale"
        case .cellular:  return "Cellular"
        case .vpn:       return "VPN (\(name))"
        case .other:     return name
        }
    }
}

nonisolated enum NetworkInterfaces {

    /// Snapshot of all non-loopback IPv4/IPv6 addresses on this machine.
    static func list(includeIPv6: Bool = false, includeLoopback: Bool = false) -> [LocalInterface] {
        var results: [LocalInterface] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == AF_INET || (includeIPv6 && family == AF_INET6) else { continue }

            let name = String(cString: ifa.pointee.ifa_name)
            guard let address = addressString(sa, family: family) else { continue }

            let kind = classify(name: name, address: address, family: family)
            if !includeLoopback && kind == .loopback { continue }

            results.append(LocalInterface(
                id: "\(name)-\(address)",
                name: name,
                address: address,
                family: Int32(family),
                kind: kind
            ))
        }
        return results
    }

    /// Convenience: LAN + Tailscale IPv4 addresses, sorted LAN-first.
    static func connectableAddresses() -> [LocalInterface] {
        list()
            .filter { $0.kind == .lan || $0.kind == .tailscale }
            .sorted { lhs, rhs in
                if lhs.kind == .lan && rhs.kind != .lan { return true }
                if lhs.kind != .lan && rhs.kind == .lan { return false }
                return lhs.address < rhs.address
            }
    }

    // MARK: - Internals

    private static func addressString(_ sa: UnsafeMutablePointer<sockaddr>, family: UInt8) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len: socklen_t = (family == AF_INET)
            ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: host)
    }

    private static func classify(name: String, address: String, family: UInt8) -> InterfaceKind {
        if name == "lo0" { return .loopback }
        if name.hasPrefix("pdp_ip") { return .cellular }

        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("tun") {
            // Tailscale uses the CGNAT range 100.64.0.0/10
            if family == AF_INET, isTailscaleRange(address) {
                return .tailscale
            }
            // Tailscale IPv6: fd7a:115c:a1e0::/48
            if family == AF_INET6, address.hasPrefix("fd7a:115c:a1e0:") {
                return .tailscale
            }
            return .vpn
        }

        if name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap") {
            return .lan
        }

        return .other
    }

    /// 100.64.0.0/10 — the CGNAT block Tailscale uses.
    private static func isTailscaleRange(_ addr: String) -> Bool {
        let parts = addr.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        // 100.64.0.0/10 means first octet == 100, bits 2-3 of second octet are 01
        // i.e. second octet in 64...127
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
}
