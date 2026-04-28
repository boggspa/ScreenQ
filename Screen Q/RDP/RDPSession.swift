//
//  RDPSession.swift
//  Screen Q
//
//  RDP routing/preflight session. This is the boundary where the FreeRDP
//  engine will be linked; for now it verifies reachability and reports the
//  missing engine explicitly.
//

import Foundation
import Combine
import CoreGraphics

@MainActor
final class RDPSession: ObservableObject {

    enum Phase: Equatable {
        case preflighting
        case credentialsRequired(RDPCredentialPrompt)
        case connecting
        case certificateTrustRequired(RDPCertificateInfo)
        case connected
        case engineUnavailable(detail: String)
        case failed(reason: String)
        case ended(reason: String)
    }

    @Published private(set) var phase: Phase = .preflighting
    @Published private(set) var securityStatus: RemoteSecurityStatus
    @Published private(set) var currentImage: CGImage?
    @Published private(set) var remoteWidth: Int = 0
    @Published private(set) var remoteHeight: Int = 0
    @Published private(set) var hasSavedCredentials: Bool = false
    @Published private(set) var hasTrustedCertificate: Bool = false
    @Published var fitMode: Bool = true

    let remoteSessionID = UUID()
    let profile: RDPConnectionProfile
    let inputMapper = InputMappingService()
    let stats = TransportStats()

    private var engine: RDPEngine?
    private var eventTask: Task<Void, Never>?
    private var activeCredentials: RDPCredentials?
    private var pendingCertificateReview: RDPCertificateInfo?
    private var lastCertificateCommonName: String?

    init(profile: RDPConnectionProfile) {
        self.profile = profile
        self.securityStatus = .rdpPreflight(scope: profile.networkScope)
        self.hasTrustedCertificate = RDPCertificateTrustStore.load(host: profile.host, port: profile.port) != nil
        self.inputMapper.sendEvent = { [weak self] event in
            guard let self else { return }
            Task { await self.sendInput(event) }
        }
    }

    convenience init(host: String, port: UInt16 = RemoteConnectionProtocol.rdp.defaultPort, label: String? = nil) {
        self.init(profile: RDPConnectionProfile(
            displayName: label ?? host,
            host: host,
            port: port
        ))
    }

    func connect() async {
        eventTask?.cancel()
        inputMapper.isControlEnabled = false
        currentImage = nil
        stats.reset()
        phase = .preflighting
        securityStatus = .rdpPreflight(scope: profile.networkScope)
        refreshTrustedCertificateState()

        let probe = await ConnectivityProbe.probe(host: profile.host, port: profile.port, timeoutSeconds: 5)
        guard probe.succeeded else {
            phase = .failed(reason: rdpProbeMessage(for: probe))
            return
        }

        let engine = RDPEngineFactory.makeEngine()
        self.engine = engine

        guard engine.availability.isAvailable else {
            securityStatus = .rdpEngineMissing(scope: profile.networkScope)
            phase = .engineUnavailable(
                detail: engine.availability.unavailableDetail ?? "RDP is reachable at \(profile.address), but no native RDP engine is linked."
            )
            return
        }

        if let stored = RDPKeychainCredentialStore.load(
            host: profile.host,
            port: profile.port,
            operationPrompt: CredentialKeychainAccess.operationPrompt(protocolName: "RDP", host: profile.host)
        ) {
            hasSavedCredentials = true
            await connectEngine(credentials: stored, trustDecision: nil)
        } else {
            hasSavedCredentials = false
            phase = .credentialsRequired(.initial(for: profile))
        }
    }

    func submitCredentials(
        domain: String?,
        username: String,
        password: String,
        remember: Bool,
        requireLocalAuthentication: Bool
    ) async {
        let credentials = RDPCredentials.fromUserInput(
            domain: domain,
            username: username,
            password: password
        )
        guard !credentials.username.isEmpty, !credentials.password.isEmpty else {
            phase = .credentialsRequired(RDPCredentialPrompt(
                suggestedDomain: suggestedCredentialDomain(fallback: domain),
                suggestedUsername: username.trimmingCharacters(in: .whitespacesAndNewlines),
                message: "Windows username and password are required before Screen Q can start RDP."
            ))
            return
        }

        if remember {
            RDPKeychainCredentialStore.save(
                credentials,
                host: profile.host,
                port: profile.port,
                requireLocalAuthentication: requireLocalAuthentication
            )
            hasSavedCredentials = true
        } else {
            RDPKeychainCredentialStore.delete(host: profile.host, port: profile.port)
            hasSavedCredentials = false
        }
        await connectEngine(credentials: credentials, trustDecision: nil)
    }

    func forgetSavedCredentials(message: String? = nil) {
        RDPKeychainCredentialStore.delete(host: profile.host, port: profile.port)
        hasSavedCredentials = false
        activeCredentials = nil
        inputMapper.isControlEnabled = false
        phase = .credentialsRequired(RDPCredentialPrompt(
            suggestedDomain: suggestedCredentialDomain(),
            suggestedUsername: profile.username,
            message: message ?? "Saved Windows credentials for \(profile.host) were removed. Enter a Remote Desktop account allowed to sign in to this PC."
        ))
    }

    func trustCertificate(_ decision: RDPCertificateTrustDecision) async {
        guard decision != .reject else {
            if let pendingCertificateReview {
                securityStatus = .rdpCertificatePending(pendingCertificateReview, scope: profile.networkScope)
            }
            phase = .failed(reason: "RDP certificate rejected.")
            return
        }
        guard let activeCredentials else {
            phase = .credentialsRequired(.initial(for: profile))
            return
        }
        let reviewedCertificate = pendingCertificateReview
        lastCertificateCommonName = reviewedCertificate?.commonName ?? lastCertificateCommonName
        if decision == .trustAlways, let reviewedCertificate {
            RDPCertificateTrustStore.save(reviewedCertificate, host: profile.host, port: profile.port)
            refreshTrustedCertificateState()
        }
        pendingCertificateReview = nil
        await connectEngine(
            credentials: activeCredentials,
            trustDecision: decision,
            trustedFingerprintOverride: reviewedCertificate?.fingerprintSHA256
        )
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        inputMapper.isControlEnabled = false
        await engine?.disconnect()
        phase = .ended(reason: "Disconnected")
    }

    func forgetTrustedCertificate() {
        RDPCertificateTrustStore.delete(host: profile.host, port: profile.port)
        refreshTrustedCertificateState()
    }

    func updateCanvas(size: CGSize, fit: Bool? = nil, viewport: ViewportTransform = .identity) {
        let remoteSize = CGSize(
            width: remoteWidth > 0 ? remoteWidth : 1920,
            height: remoteHeight > 0 ? remoteHeight : 1080
        )
        inputMapper.canvas = CanvasGeometry(
            canvasSize: size,
            remotePixelSize: remoteSize,
            fit: fit ?? fitMode,
            viewport: viewport
        )
    }

    private func connectEngine(
        credentials: RDPCredentials,
        trustDecision: RDPCertificateTrustDecision?,
        trustedFingerprintOverride: String? = nil
    ) async {
        guard let engine else {
            phase = .failed(reason: "RDP engine was not prepared.")
            return
        }

        activeCredentials = credentials
        if trustDecision == nil {
            pendingCertificateReview = nil
        }
        phase = .connecting
        securityStatus = .rdpNegotiating(scope: profile.networkScope)
        let trustedFingerprint = trustedFingerprintOverride
            ?? pendingCertificateReview?.fingerprintSHA256
            ?? RDPCertificateTrustStore.load(host: profile.host, port: profile.port)?.fingerprintSHA256
        refreshTrustedCertificateState()

        let stream = engine.connect(
            profile: profile,
            credentials: credentials,
            trustDecision: trustDecision,
            trustedCertificateFingerprintSHA256: trustedFingerprint
        )

        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            do {
                for try await event in stream {
                    self?.handleEngineEvent(event)
                }
            } catch {
                self?.handleEngineError(error)
            }
        }
    }

    private func handleEngineEvent(_ event: RDPEngineEvent) {
        switch event {
        case .connecting:
            phase = .connecting

        case .credentialsRequired(let prompt):
            inputMapper.isControlEnabled = false
            phase = .credentialsRequired(RDPCredentialPrompt(
                suggestedDomain: prompt.suggestedDomain ?? suggestedCredentialDomain(),
                suggestedUsername: prompt.suggestedUsername ?? profile.username,
                message: prompt.message
            ))

        case .certificateTrustRequired(let certificate):
            inputMapper.isControlEnabled = false
            pendingCertificateReview = certificate
            lastCertificateCommonName = certificate.commonName ?? lastCertificateCommonName
            securityStatus = .rdpCertificatePending(certificate, scope: profile.networkScope)
            phase = .certificateTrustRequired(certificate)

        case .securityNegotiated(let report):
            securityStatus = .rdp(report: report, scope: profile.networkScope)

        case .connected(let width, let height):
            pendingCertificateReview = nil
            remoteWidth = width
            remoteHeight = height
            inputMapper.isControlEnabled = true
            phase = .connected

        case .frame(let frame):
            remoteWidth = frame.width
            remoteHeight = frame.height
            if let image = frame.makeCGImage() {
                currentImage = image
                stats.recordFrame(byteCount: frame.data.count)
            } else {
                stats.recordDropped()
            }

        case .disconnected(let reason):
            if let pendingCertificateReview {
                inputMapper.isControlEnabled = false
                securityStatus = .rdpCertificatePending(pendingCertificateReview, scope: profile.networkScope)
                phase = .certificateTrustRequired(pendingCertificateReview)
                return
            }
            inputMapper.isControlEnabled = false
            phase = .ended(reason: reason ?? "RDP session ended")
        }
    }

    private func handleEngineError(_ error: Error) {
        inputMapper.isControlEnabled = false
        if case RDPEngineError.engineUnavailable(let detail) = error {
            securityStatus = .rdpEngineMissing(scope: profile.networkScope)
            phase = .engineUnavailable(detail: detail)
        } else if let pendingCertificateReview {
            securityStatus = .rdpCertificatePending(pendingCertificateReview, scope: profile.networkScope)
            phase = .certificateTrustRequired(pendingCertificateReview)
        } else if case RDPEngineError.credentialsRejected(let detail) = error {
            RDPKeychainCredentialStore.delete(host: profile.host, port: profile.port)
            hasSavedCredentials = false
            let rejectedCredentials = activeCredentials
            activeCredentials = nil
            securityStatus = .rdpPreflight(scope: profile.networkScope)
            phase = .credentialsRequired(RDPCredentialPrompt(
                suggestedDomain: suggestedCredentialDomain(fallback: rejectedCredentials?.domain),
                suggestedUsername: rejectedCredentials?.username ?? profile.username,
                message: credentialRetryMessage(detail)
            ))
        } else {
            phase = .failed(reason: error.localizedDescription)
        }
    }

    private func sendInput(_ event: RemoteInputEvent) async {
        guard case .connected = phase else { return }
        do {
            try await engine?.sendInput(event)
        } catch {
            Logger.shared.error("RDP input failed: \(error.localizedDescription)")
        }
    }

    private func rdpProbeMessage(for result: ProbeResult) -> String {
        switch result {
        case .connectionRefused:
            return "Connection refused — no RDP service is listening on \(profile.address). Check that Remote Desktop is enabled and Windows Firewall allows TCP \(profile.port) on the Tailscale interface."
        case .timeout:
            return "Timed out reaching \(profile.address). Check that both devices are in the same tailnet and that Windows allows Remote Desktop over the Tailscale network."
        default:
            return result.friendlyMessage
        }
    }

    private func suggestedCredentialDomain(fallback: String? = nil) -> String? {
        if let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            return fallback
        }
        if let domain = profile.domain?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty {
            return domain
        }
        if let commonName = lastCertificateCommonName?.trimmingCharacters(in: .whitespacesAndNewlines), !commonName.isEmpty {
            return commonName
        }
        return nil
    }

    private func refreshTrustedCertificateState() {
        hasTrustedCertificate = RDPCertificateTrustStore.load(host: profile.host, port: profile.port) != nil
    }

    private func credentialRetryMessage(_ detail: String) -> String {
        var examples: [String] = []
        if let domain = suggestedCredentialDomain() {
            examples.append("\(domain)\\username")
        }
        examples.append(contentsOf: [
            ".\\username",
            "MicrosoftAccount\\email@example.com",
            "AzureAD\\email@example.com"
        ])
        return "\(detail) Try a Windows RDP sign-in name such as \(examples.joined(separator: ", "))."
    }
}

extension RDPSession: RemoteSession {
    var remoteSessionDescriptor: RemoteSessionDescriptor {
        RemoteSessionDescriptor(
            id: remoteSessionID,
            kind: .rdpReserved,
            label: profile.displayName,
            host: profile.host,
            port: profile.port,
            platform: .windows
        )
    }

    var remoteCapabilities: RemoteCapabilities {
        .rdpPreview
    }
}
