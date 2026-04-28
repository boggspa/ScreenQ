//
//  WakeOnLAN.swift
//  Screen Q
//
//  Sends a Wake-on-LAN magic packet to wake a sleeping Mac on the local
//  network. Requires the target's MAC address. The magic packet is a UDP
//  broadcast: 6 bytes of 0xFF followed by 16 repetitions of the MAC.
//

import Foundation
import Network

enum WakeOnLAN {

    struct MACAddress {
        let bytes: [UInt8]  // 6 bytes

        init?(_ string: String) {
            let parts = string.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard parts.count == 6 else { return nil }
            bytes = parts
        }
    }

    /// Send a WOL magic packet to the given MAC address.
    /// Broadcasts on UDP port 9 to 255.255.255.255.
    static func wake(mac: MACAddress, completion: @escaping (Error?) -> Void) {
        // Build magic packet: FF FF FF FF FF FF + MAC × 16
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: mac.bytes)
        }

        let connection = NWConnection(
            host: NWEndpoint.Host("255.255.255.255"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .udp
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: packet, completion: .contentProcessed { error in
                    completion(error)
                    connection.cancel()
                })
            case .failed(let error):
                completion(error)
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))
    }

    /// Convenience async wrapper.
    static func wake(macString: String) async throws {
        guard let mac = MACAddress(macString) else {
            throw NSError(domain: "WOL", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid MAC address format. Use XX:XX:XX:XX:XX:XX"])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            wake(mac: mac) { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
    }
}
