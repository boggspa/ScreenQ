//
//  FreeRDPEngine.swift
//  Screen Q
//
//  Runtime-loaded FreeRDP bridge. The app stays buildable without vendored
//  FreeRDP binaries, while production builds can bundle ScreenQFreeRDPBridge
//  and get a live RDPEngine implementation through this ABI.
//

import Foundation
import Darwin

@MainActor
final class FreeRDPEngine: RDPEngine {
    private let runtimeLoadResult: Result<FreeRDPBridgeRuntime, FreeRDPBridgeLoadFailure>
    private var runtime: FreeRDPBridgeRuntime? {
        try? runtimeLoadResult.get()
    }
    private var sessionHandle: UnsafeMutableRawPointer?
    private var streamContinuation: AsyncThrowingStream<RDPEngineEvent, Error>.Continuation?

    init() {
        runtimeLoadResult = FreeRDPBridgeRuntime.load()
    }

    var availability: RDPEngineAvailability {
        switch runtimeLoadResult {
        case .success:
            return .available
        case .failure(let failure):
            return .unavailable(detail: failure.detail)
        }
    }

    func connect(
        profile: RDPConnectionProfile,
        credentials: RDPCredentials,
        trustDecision: RDPCertificateTrustDecision?,
        trustedCertificateFingerprintSHA256: String?
    ) -> AsyncThrowingStream<RDPEngineEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let runtime else {
                let detail = availability.unavailableDetail ?? "The FreeRDP bridge is unavailable."
                continuation.finish(throwing: RDPEngineError.engineUnavailable(detail: detail))
                return
            }
            guard let handle = runtime.createSession() else {
                continuation.finish(throwing: RDPEngineError.engineUnavailable(detail: "The FreeRDP bridge failed to create an RDP session."))
                return
            }

            streamContinuation = continuation
            sessionHandle = handle
            runtime.setEventCallback(handle, FreeRDPBridgeCallbacks.eventCallback, Unmanaged.passUnretained(self).toOpaque())

            let result = withBridgeConfig(
                profile: profile,
                credentials: credentials,
                trustDecision: trustDecision,
                trustedCertificateFingerprintSHA256: trustedCertificateFingerprintSHA256
            ) { config in
                runtime.connect(handle, config)
            }

            if result != 0 {
                let detail = runtime.lastErrorMessage(handle) ?? "The FreeRDP bridge refused to start the RDP session."
                cleanupBridgeSession()
                continuation.finish(throwing: RDPEngineError.connectionFailed(detail))
            }

            let engine = self
            continuation.onTermination = { _ in
                Task { @MainActor [weak engine] in
                    engine?.cleanupBridgeSession()
                }
            }
        }
    }

    func disconnect() async {
        cleanupBridgeSession()
        streamContinuation?.finish()
        streamContinuation = nil
    }

    func sendInput(_ event: RemoteInputEvent) async throws {
        guard let runtime, let sessionHandle else {
            throw RDPEngineError.engineUnavailable(detail: availability.unavailableDetail ?? "The FreeRDP bridge is unavailable.")
        }

        let status = withBridgeInputEvent(event) { input in
            runtime.sendInput(sessionHandle, input)
        }

        if status != 0 {
            throw RDPEngineError.connectionFailed(runtime.lastErrorMessage(sessionHandle) ?? "The FreeRDP bridge rejected the input event.")
        }
    }

    func resize(width: Int, height: Int, scale: Double) async throws {
        guard let runtime, let sessionHandle else {
            throw RDPEngineError.engineUnavailable(detail: availability.unavailableDetail ?? "The FreeRDP bridge is unavailable.")
        }
        let status = runtime.resize(sessionHandle, Int32(width), Int32(height), scale)
        if status != 0 {
            throw RDPEngineError.connectionFailed(runtime.lastErrorMessage(sessionHandle) ?? "The FreeRDP bridge rejected the resize request.")
        }
    }

    fileprivate func receive(_ event: RDPEngineEvent) {
        streamContinuation?.yield(event)
        if case .disconnected = event {
            cleanupBridgeSession()
            streamContinuation?.finish()
            streamContinuation = nil
        }
    }

    fileprivate func fail(_ error: RDPEngineError) {
        cleanupBridgeSession()
        streamContinuation?.finish(throwing: error)
        streamContinuation = nil
    }

    private func cleanupBridgeSession() {
        guard let handle = sessionHandle else { return }
        runtime?.disconnect(handle)
        runtime?.destroySession(handle)
        sessionHandle = nil
    }
}

private func withBridgeConfig<T>(
    profile: RDPConnectionProfile,
    credentials: RDPCredentials,
    trustDecision: RDPCertificateTrustDecision?,
    trustedCertificateFingerprintSHA256: String?,
    body: (UnsafePointer<SQFreeRDPConfig>) -> T
) -> T {
    withOptionalCString(profile.host) { host in
        withOptionalCString(credentials.username) { username in
            withOptionalCString(credentials.password) { password in
                withOptionalCString(credentials.domain ?? profile.domain) { domain in
                    withOptionalCString(profile.gatewayHost) { gatewayHost in
                        withOptionalCString(profile.gatewayUsername) { gatewayUsername in
                            withOptionalCString(trustedCertificateFingerprintSHA256) { trustedFingerprint in
                                var config = SQFreeRDPConfig(
                                    host: host,
                                    port: profile.port,
                                    username: username,
                                    password: password,
                                    domain: domain,
                                    gatewayHost: gatewayHost,
                                    gatewayUsername: gatewayUsername,
                                    desktopWidth: Int32(profile.desktopWidth ?? 0),
                                    desktopHeight: Int32(profile.desktopHeight ?? 0),
                                    dynamicResolution: profile.dynamicResolution ? 1 : 0,
                                    administrativeSession: profile.administrativeSession ? 1 : 0,
                                    connectToConsole: profile.connectToConsole ? 1 : 0,
                                    redirectClipboard: profile.redirectClipboard ? 1 : 0,
                                    redirectAudio: profile.redirectAudio ? 1 : 0,
                                    allowFontSmoothing: profile.allowFontSmoothing ? 1 : 0,
                                    certificateTrust: trustDecision.bridgeValue,
                                    trustedCertificateFingerprintSHA256: trustedFingerprint
                                )
                                return withUnsafePointer(to: &config, body)
                            }
                        }
                    }
                }
            }
        }
    }
}

private func withBridgeInputEvent<T>(
    _ event: RemoteInputEvent,
    body: (UnsafePointer<SQFreeRDPInputEvent>) -> T
) -> T {
    func call(_ input: inout SQFreeRDPInputEvent) -> T {
        withUnsafePointer(to: &input, body)
    }

    switch event {
    case .pointerMove(let point, let modifiers):
        var input = SQFreeRDPInputEvent(kind: .pointerMove, point: point, modifiers: modifiers)
        return call(&input)

    case .pointerDown(let point, let button, let modifiers):
        var input = SQFreeRDPInputEvent(kind: .pointerDown, point: point, button: button, modifiers: modifiers)
        return call(&input)

    case .pointerUp(let point, let button, let modifiers):
        var input = SQFreeRDPInputEvent(kind: .pointerUp, point: point, button: button, modifiers: modifiers)
        return call(&input)

    case .scroll(let deltaX, let deltaY, let point, let modifiers):
        var input = SQFreeRDPInputEvent(kind: .scroll, point: point, deltaX: deltaX, deltaY: deltaY, modifiers: modifiers)
        return call(&input)

    case .keyDown(let key, let modifiers):
        return key.rawValue.withCString { keyName in
            var input = SQFreeRDPInputEvent(kind: .keyDown, keyName: keyName, modifiers: modifiers)
            return call(&input)
        }

    case .keyUp(let key, let modifiers):
        return key.rawValue.withCString { keyName in
            var input = SQFreeRDPInputEvent(kind: .keyUp, keyName: keyName, modifiers: modifiers)
            return call(&input)
        }

    case .textInput(let text):
        return text.withCString { text in
            var input = SQFreeRDPInputEvent(kind: .textInput, text: text)
            return call(&input)
        }
    }
}

private func withOptionalCString<T>(_ value: String?, body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let value, !value.isEmpty else {
        return body(nil)
    }
    return value.withCString(body)
}

private extension Optional where Wrapped == RDPCertificateTrustDecision {
    var bridgeValue: Int32 {
        switch self {
        case nil:
            return SQFreeRDPCertificateTrust.none.rawValue
        case .some(.trustOnce):
            return SQFreeRDPCertificateTrust.trustOnce.rawValue
        case .some(.trustAlways):
            return SQFreeRDPCertificateTrust.trustAlways.rawValue
        case .some(.reject):
            return SQFreeRDPCertificateTrust.reject.rawValue
        }
    }
}

private extension SQFreeRDPInputEvent {
    init(
        kind: SQFreeRDPInputKind,
        point: NormalisedPoint = .zero,
        button: PointerButton? = nil,
        deltaX: Double = 0,
        deltaY: Double = 0,
        keyName: UnsafePointer<CChar>? = nil,
        text: UnsafePointer<CChar>? = nil,
        modifiers: KeyModifiers = []
    ) {
        self.init(
            kind: kind.rawValue,
            x: point.x,
            y: point.y,
            button: button?.bridgeValue ?? 0,
            deltaX: deltaX,
            deltaY: deltaY,
            keyName: keyName,
            text: text,
            modifiers: UInt32(modifiers.rawValue)
        )
    }
}

private extension PointerButton {
    var bridgeValue: Int32 {
        switch self {
        case .left: return 1
        case .right: return 2
        case .middle: return 3
        }
    }
}

private enum FreeRDPBridgeCallbacks {
    static let eventCallback: SQFreeRDPEventCallback = { context, rawEvent in
        guard let context, let rawEvent else { return }
        let event = rawEvent.assumingMemoryBound(to: SQFreeRDPEvent.self).pointee
        let mapped = FreeRDPBridgeEventMapper.map(event)
        let engine = Unmanaged<FreeRDPEngine>.fromOpaque(context).takeUnretainedValue()

        Task { @MainActor in
            switch mapped {
            case .event(let event):
                engine.receive(event)
            case .failure(let error):
                engine.fail(error)
            }
        }
    }
}

private enum FreeRDPBridgeEventMapper {
    enum MappedEvent {
        case event(RDPEngineEvent)
        case failure(RDPEngineError)
    }

    static func map(_ event: SQFreeRDPEvent) -> MappedEvent {
        guard let kind = SQFreeRDPEventKind(rawValue: event.kind) else {
            return .failure(.connectionFailed(copyString(event.message) ?? "The FreeRDP bridge emitted an unknown event."))
        }

        switch kind {
        case .connecting:
            return .event(.connecting)

        case .credentialsRequired:
            return .event(.credentialsRequired(RDPCredentialPrompt(
                suggestedDomain: copyString(event.domain),
                suggestedUsername: copyString(event.username),
                message: copyString(event.message) ?? "Windows credentials are required."
            )))

        case .certificateTrustRequired:
            return .event(.certificateTrustRequired(certificate(from: event)))

        case .securityNegotiated:
            return .event(.securityNegotiated(RDPSecurityReport(
                tlsProtocol: copyString(event.tlsProtocol),
                nlaSucceeded: event.nlaSucceeded != 0,
                isTransportEncrypted: event.transportEncrypted != 0,
                isAuthenticated: event.authenticated != 0,
                certificate: event.certificateFingerprintSHA256 == nil ? nil : certificate(from: event),
                serverIdentityVerified: event.identityVerified != 0
            )))

        case .connected:
            return .event(.connected(width: Int(event.width), height: Int(event.height)))

        case .frame:
            guard let data = event.frameData,
                  event.frameDataLength > 0,
                  event.width > 0,
                  event.height > 0,
                  event.bytesPerRow > 0 else {
                return .failure(.connectionFailed("The FreeRDP bridge emitted an invalid frame."))
            }
            return .event(.frame(RDPEngineFrame(
                width: Int(event.width),
                height: Int(event.height),
                bytesPerRow: Int(event.bytesPerRow),
                pixelFormat: .bgra8888,
                data: Data(bytes: data, count: event.frameDataLength)
            )))

        case .disconnected:
            return .event(.disconnected(reason: copyString(event.message)))

        case .error:
            let message = copyString(event.message)
            if RDPFailureClassifier.isCredentialOrAccountFailure(statusCode: event.statusCode, message: message) {
                return .failure(.credentialsRejected(RDPFailureClassifier.credentialRetryMessage(
                    statusCode: event.statusCode,
                    message: message
                )))
            }
            return .failure(.connectionFailed(message ?? "The FreeRDP bridge reported a connection error."))
        }
    }

    private static func certificate(from event: SQFreeRDPEvent) -> RDPCertificateInfo {
        RDPCertificateInfo(
            subject: copyString(event.certificateSubject) ?? "Unknown subject",
            issuer: copyString(event.certificateIssuer) ?? "Unknown issuer",
            fingerprintSHA256: copyString(event.certificateFingerprintSHA256) ?? "",
            validFrom: event.certificateValidFromUnix > 0 ? Date(timeIntervalSince1970: event.certificateValidFromUnix) : nil,
            validUntil: event.certificateValidUntilUnix > 0 ? Date(timeIntervalSince1970: event.certificateValidUntilUnix) : nil,
            host: copyString(event.certificateHost) ?? copyString(event.host) ?? "Unknown host"
        )
    }

    private static func copyString(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }
}
