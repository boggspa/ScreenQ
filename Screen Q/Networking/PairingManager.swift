//
//  PairingManager.swift
//  Screen Q
//
//  Owns pairing-code generation, host approval, and trusted-peer storage.
//
//  Trust model:
//   - Host generates a 6-digit code and shows it on its UI.
//   - Viewer prompts the user to enter that code.
//   - Viewer sends the code via PairingRequestMessage.
//   - Host UI surfaces the inbound request; user must explicitly Approve.
//   - Only after approval do we send PairingApprovedMessage and start video.
//
//  We never auto-accept. Trusted peers can skip the pairing code after their
//  device identity key is pinned, but explicit host approval remains.
//

import Foundation
import Combine
import CryptoKit

@MainActor
final class PairingManager: ObservableObject {

    @Published private(set) var currentCode: String = ""
    @Published var pendingRequests: [PairingRequest] = []
    @Published var trustedPeers: [TrustedPeer] = []

    private var codeIssuedAt: Date?
    private let codeLifetime: TimeInterval = 5 * 60   // 5 minutes

    init() {
        load()
        regenerateCode()
    }

    // MARK: - Code

    func regenerateCode() {
        currentCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
        codeIssuedAt = Date()
    }

    func codeIsValid(_ code: String) -> Bool {
        guard let issuedAt = codeIssuedAt else { return false }
        guard Date().timeIntervalSince(issuedAt) < codeLifetime else { return false }
        return constantTimeEquals(currentCode, code)
    }

    // MARK: - Requests

    func enqueue(_ req: PairingRequest) {
        pendingRequests.append(req)
    }

    func remove(_ requestID: UUID) {
        pendingRequests.removeAll { $0.id == requestID }
    }

    // MARK: - Trust

    func isTrusted(peerID: UUID, fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        return trustedPeers.contains { $0.id == peerID && $0.fingerprint == fingerprint }
    }

    func trust(viewer peer: PeerDevice, fingerprint: String) {
        let trusted = TrustedPeer(
            id: peer.id,
            displayName: peer.displayName,
            fingerprint: fingerprint,
            lastSeen: Date()
        )
        if let idx = trustedPeers.firstIndex(where: { $0.id == peer.id }) {
            trustedPeers[idx] = trusted
        } else {
            trustedPeers.append(trusted)
        }
        save()
    }

    func updateLastSeen(peerID: UUID) {
        if let idx = trustedPeers.firstIndex(where: { $0.id == peerID }) {
            trustedPeers[idx].lastSeen = Date()
            save()
        }
    }

    func untrust(_ id: UUID) {
        trustedPeers.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence (UserDefaults; not Keychain because peer fingerprints aren't secret)

    private let storeKey = "ScreenQ.TrustedPeers"

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let peers = try? JSONDecoder().decode([TrustedPeer].self, from: data) {
            trustedPeers = peers
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(trustedPeers) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    // MARK: - Helpers

    /// Compare two short strings without leaking length-dependent timing.
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        if ab.count != bb.count { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }
}
