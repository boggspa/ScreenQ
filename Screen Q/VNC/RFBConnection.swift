//
//  RFBConnection.swift
//  Screen Q
//
//  Manages a TCP connection to a VNC/RFB server. Handles the version
//  handshake, security negotiation (None + VNC Auth), initialization,
//  and the bidirectional message pump.
//

import Foundation
import Network
import CommonCrypto
import CryptoKit
import Security

actor RFBConnection {

    nonisolated static let preferredClientEncodings: [RFBEncoding] = [
        .tight,
        .tightPNG,
        .copyRect,
        .hextile,
        .raw,
        .lastRect,
        .desktopSize,
        .extendedDesktopSize,
        .cursor,
        .qemuExtendedKeyEvent
    ]

    private(set) var serverSupportsQemuExtendedKey = false
    private(set) var serverSupportsExtendedDesktopSize = false

    private let connection: NWConnection
    private var buffer = Data()
    private(set) var isOpen = false
    private let tightDecodeState = RFBEncodingDecoder.TightDecodeState()
    private let zrleDecodeState = RFBEncodingDecoder.ZRLEDecodeState()
    private(set) var pendingCursorShape: CursorShape?

    func consumePendingCursorShape() -> CursorShape? {
        defer { pendingCursorShape = nil }
        return pendingCursorShape
    }
    private var offeredSecurityTypes: [UInt8] = []
    private var selectedSecurityType: UInt8?
    private var selectedAppleWrappedSecurityType: UInt8?
    private var activeReadDeadline: ReadDeadline?

    private struct ReadDeadline {
        let stage: String
        let deadline: Date
    }

    private final class OneShotContinuation<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private let continuation: CheckedContinuation<Value, Error>

        init(_ continuation: CheckedContinuation<Value, Error>) {
            self.continuation = continuation
        }

        @discardableResult
        func resume(returning value: Value) -> Bool {
            complete(.success(value))
        }

        @discardableResult
        func resume(throwing error: Error) -> Bool {
            complete(.failure(error))
        }

        private func complete(_ result: Result<Value, Error>) -> Bool {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return false
            }
            didResume = true
            lock.unlock()
            continuation.resume(with: result)
            return true
        }
    }

    // MARK: - Init

    init(host: String, port: UInt16 = 5900) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        self.connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
    }

    init(endpoint: NWEndpoint) {
        self.connection = NWConnection(to: endpoint, using: .tcp)
    }

    // MARK: - Lifecycle

    func connect(
        username: String?,
        password: String?,
        securityPreference: RFBSecurityPreference = .vncPasswordFirst,
        timeouts: RFBConnectionTimeouts = .default
    ) async throws -> RFBServerInit {
        try await startTCP(timeout: timeouts.tcpConnect)
        isOpen = true

        // 1. Version handshake
        let version = try await withReadTimeout(
            stage: "RFB version handshake",
            timeout: timeouts.versionHandshake
        ) {
            try await negotiateVersion()
        }

        // 2. Security
        try await withReadTimeout(
            stage: "RFB security negotiation",
            timeout: timeouts.securityNegotiation
        ) {
            try await negotiateSecurity(version: version, username: username, password: password, securityPreference: securityPreference)
        }

        // 3. ClientInit (shared = true)
        try await write(Data([1]))

        // 4. ServerInit
        let serverInit = try await withReadTimeout(
            stage: "RFB server initialization",
            timeout: timeouts.serverInitialization
        ) {
            try await readServerInit()
        }

        // 5. Set our preferred pixel format
        try await sendSetPixelFormat(.xrgb32)

        // 6. Set encodings we support
        try await sendSetEncodings(Self.preferredClientEncodings)

        return serverInit
    }

    func disconnect() {
        connection.cancel()
        tightDecodeState.resetAll()
        isOpen = false
    }

    func securityReport() -> RFBSecurityReport {
        RFBSecurityReport(
            mode: RFBSecurityMode(type: selectedAppleWrappedSecurityType ?? selectedSecurityType),
            offeredModes: offeredSecurityTypes.map { RFBSecurityMode(type: $0) }
        )
    }

    // MARK: - Client → Server messages

    func sendFramebufferUpdateRequest(incremental: Bool, x: UInt16, y: UInt16, w: UInt16, h: UInt16) async throws {
        var d = Data(count: 10)
        d[0] = RFBClientMessageType.framebufferUpdateRequest.rawValue
        d[1] = incremental ? 1 : 0
        d.replaceSubrange(2..<4, with: x.bigEndianBytes)
        d.replaceSubrange(4..<6, with: y.bigEndianBytes)
        d.replaceSubrange(6..<8, with: w.bigEndianBytes)
        d.replaceSubrange(8..<10, with: h.bigEndianBytes)
        try await write(d)
    }

    func sendKeyEvent(down: Bool, key: UInt32) async throws {
        var d = Data(count: 8)
        d[0] = RFBClientMessageType.keyEvent.rawValue
        d[1] = down ? 1 : 0
        d[2] = 0; d[3] = 0 // padding
        d.replaceSubrange(4..<8, with: key.bigEndianBytes)
        try await write(d)
    }

    func sendPointerEvent(buttons: UInt8, x: UInt16, y: UInt16) async throws {
        var d = Data(count: 6)
        d[0] = RFBClientMessageType.pointerEvent.rawValue
        d[1] = buttons
        d.replaceSubrange(2..<4, with: x.bigEndianBytes)
        d.replaceSubrange(4..<6, with: y.bigEndianBytes)
        try await write(d)
    }

    /// QEMU Extended Key Event. `keysym` is X11 keysym; `keycode` is the XT scan code (PS/2 set 1).
    /// The server only accepts these if it sent the qemuExtendedKeyEvent pseudo-encoding back.
    func sendQemuExtendedKeyEvent(down: Bool, keysym: UInt32, keycode: UInt32) async throws {
        var d = Data(count: 12)
        d[0] = RFBClientMessageType.qemuClientMessage.rawValue
        d[1] = RFBQemuSubMessage.extendedKeyEvent.rawValue
        d.replaceSubrange(2..<4, with: UInt16(down ? 1 : 0).bigEndianBytes)
        d.replaceSubrange(4..<8, with: keysym.bigEndianBytes)
        d.replaceSubrange(8..<12, with: keycode.bigEndianBytes)
        try await write(d)
    }

    /// SetDesktopSize: ask the server to switch the framebuffer to a new size.
    /// Single-screen layout (most common). `screenId` is arbitrary if the server doesn't track it.
    func sendSetDesktopSize(width: UInt16, height: UInt16, screenId: UInt32 = 1) async throws {
        var d = Data(count: 24)
        d[0] = RFBClientMessageType.setDesktopSize.rawValue
        d[1] = 0 // padding
        d.replaceSubrange(2..<4, with: width.bigEndianBytes)
        d.replaceSubrange(4..<6, with: height.bigEndianBytes)
        d[6] = 1 // number-of-screens
        d[7] = 0 // padding
        // Screen entry (16 bytes): id u32, x u16, y u16, w u16, h u16, flags u32
        d.replaceSubrange(8..<12, with: screenId.bigEndianBytes)
        // x, y = 0
        d.replaceSubrange(16..<18, with: width.bigEndianBytes)
        d.replaceSubrange(18..<20, with: height.bigEndianBytes)
        // flags = 0
        try await write(d)
    }

    func sendClientCutText(_ text: String) async throws {
        let utf8 = Data(text.utf8)
        var d = Data(count: 8)
        d[0] = RFBClientMessageType.clientCutText.rawValue
        d[1] = 0; d[2] = 0; d[3] = 0
        d.replaceSubrange(4..<8, with: UInt32(utf8.count).bigEndianBytes)
        d.append(utf8)
        try await write(d)
    }

    // MARK: - Server → Client message reading

    /// Read the next server message. Returns nil on disconnect.
    func readServerMessage() async throws -> ServerMessage? {
        guard isOpen else { return nil }
        let msgType = try await readUInt8()
        switch msgType {
        case RFBServerMessageType.framebufferUpdate.rawValue:
            return try await readFramebufferUpdate()
        case RFBServerMessageType.setColourMapEntries.rawValue:
            try await skipColourMapEntries()
            return nil
        case RFBServerMessageType.bell.rawValue:
            return .bell
        case RFBServerMessageType.serverCutText.rawValue:
            return try await readServerCutText()
        default:
            throw RFBError.protocolError("Unknown server message type: \(msgType)")
        }
    }

    nonisolated enum ServerMessage: Sendable {
        case framebufferUpdate([RFBRect])
        case bell
        case serverCutText(String)
        case desktopResize(width: UInt16, height: UInt16)
        case cursorShape(CursorShape)
    }

    nonisolated struct CursorShape: Sendable {
        let hotspotX: UInt16
        let hotspotY: UInt16
        let width: UInt16
        let height: UInt16
        let pixels: Data   // BGRA, width*height*4
        let mask: Data     // 1-bit MSB-first, ceil(width/8)*height
    }

    // MARK: - Private: TCP

    private func startTCP(timeout: TimeInterval?) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = OneShotContinuation(cont)
            let timeoutItem = timeout.map { timeout in
                DispatchWorkItem { [connection] in
                    if gate.resume(throwing: RFBError.timeout(stage: "TCP connect")) {
                        connection.cancel()
                    }
                }
            }
            if let timeoutItem, let timeout {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(returning: ())
                case .failed(let err):
                    gate.resume(throwing: RFBError.connectionFailed(err.localizedDescription))
                case .cancelled:
                    gate.resume(throwing: RFBError.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    // MARK: - Private: Version handshake

    /// Returns major minor version as Int (33, 37, or 38).
    private func negotiateVersion() async throws -> Int {
        let versionData = try await readExact(12)
        guard let versionStr = String(data: versionData, encoding: .ascii),
              versionStr.hasPrefix("RFB ") else {
            throw RFBError.protocolError("Invalid version string")
        }
        // Parse "RFB 003.008\n"
        let parts = versionStr.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        let major = Int(parts.first ?? "0") ?? 0
        let minor = Int(parts.last ?? "0") ?? 0
        // Reply with the same version (clamped to 3.8)
        let replyMinor = min(minor, 8)
        let reply = String(format: "RFB %03d.%03d\n", major, replyMinor)
        try await write(Data(reply.utf8))

        Logger.shared.info("VNC version: \(major).\(minor) (using 3.\(replyMinor))")
        return major * 10 + replyMinor
    }

    // MARK: - Private: Security

    private func negotiateSecurity(version: Int, username: String?, password: String?, securityPreference: RFBSecurityPreference) async throws {
        let chosenType: UInt8

        if version >= 37 {
            let count = Int(try await readUInt8())
            if count == 0 {
                let len = try await readUInt32()
                let reason = try await readString(Int(len))
                throw RFBError.authFailed(reason)
            }
            let types = try await readExact(count)
            offeredSecurityTypes = Array(types)
            Logger.shared.debug("VNC security types offered: \(Array(types).map { String($0) }.joined(separator: ", "))")
            let hasUsername = username != nil && !username!.isEmpty
            chosenType = chooseSecType(Array(types), hasUsername: hasUsername, preference: securityPreference)
            Logger.shared.info("VNC chose security type \(chosenType)")
            try await write(Data([chosenType]))
        } else {
            let t = try await readUInt32()
            chosenType = UInt8(t & 0xFF)
            offeredSecurityTypes = [chosenType]
        }
        selectedSecurityType = chosenType

        try await performAuth(type: chosenType, username: username, password: password, securityPreference: securityPreference)

        // SecurityResult — not sent for type None pre-3.8
        if version >= 38 || chosenType != RFBSecurityType.none.rawValue {
            let result = try await readUInt32()
            if result != 0 {
                if version >= 38 {
                    let len = try await readUInt32()
                    let reason = try await readString(Int(len))
                    throw RFBError.authFailed(reason)
                }
                throw RFBError.authFailed("Authentication failed (code \(result))")
            }
        }
    }

    private func chooseSecType(_ types: [UInt8], hasUsername: Bool, preference: RFBSecurityPreference) -> UInt8 {
        RFBSecurityNegotiationPolicy.chooseSecurityType(
            offered: types,
            hasUsername: hasUsername,
            preference: preference
        )
    }

    private func performAuth(type: UInt8, username: String?, password: String?, securityPreference: RFBSecurityPreference) async throws {
        switch type {
        case RFBSecurityType.none.rawValue:
            break
        case RFBSecurityType.vncAuth.rawValue:
            try await performVNCAuth(password: password)
        case RFBSecurityType.appleDH.rawValue:
            guard let username = username, !username.isEmpty,
                  let password = password, !password.isEmpty else {
                throw RFBError.credentialsRequired
            }
            try await performAppleDHAuth(username: username, password: password)
        case RFBSecurityType.appleScreenSharing.rawValue:
            try await performAppleWrappedAuth(username: username, password: password, securityPreference: securityPreference)
        case RFBSecurityType.appleModern35.rawValue, RFBSecurityType.appleModern36.rawValue:
            throw RFBError.unsupportedSecurity(type)
        default:
            throw RFBError.unsupportedSecurity(type)
        }
    }

    private func performAppleWrappedAuth(username: String?, password: String?, securityPreference: RFBSecurityPreference) async throws {
        let hasUsername = username != nil && !username!.isEmpty
        let innerType = RFBSecurityNegotiationPolicy.chooseAppleWrappedSecurityType(
            offered: offeredSecurityTypes,
            hasUsername: hasUsername,
            preference: securityPreference
        )

        guard innerType != RFBSecurityType.invalid.rawValue else {
            throw RFBError.unsupportedSecurity(RFBSecurityType.appleScreenSharing.rawValue)
        }

        selectedAppleWrappedSecurityType = innerType
        Logger.shared.info("VNC chose Apple Screen Sharing inner authentication type \(innerType)")
        try await write(Data([innerType]))

        switch innerType {
        case RFBSecurityType.none.rawValue:
            break
        case RFBSecurityType.vncAuth.rawValue:
            try await performVNCAuth(password: password)
        case RFBSecurityType.appleDH.rawValue:
            guard let username = username, !username.isEmpty,
                  let password = password, !password.isEmpty else {
                throw RFBError.credentialsRequired
            }
            try await performAppleDHAuth(username: username, password: password)
        case RFBSecurityType.appleModern35.rawValue, RFBSecurityType.appleModern36.rawValue:
            throw RFBError.unsupportedSecurity(innerType)
        default:
            throw RFBError.unsupportedSecurity(innerType)
        }
    }

    private func performVNCAuth(password: String?) async throws {
        guard let password = password, !password.isEmpty else {
            throw RFBError.authRequired
        }
        let challenge = try await readExact(16)
        let response = vncAuthResponse(password: password, challenge: challenge)
        try await write(response)
    }

    // MARK: - Apple DH Authentication (type 30)

    private func performAppleDHAuth(username: String, password: String) async throws {
        // Server sends: generator (2), keyLength (2), prime (keyLength), serverPublicKey (keyLength)
        let generator = try await readUInt16()
        let keyLength = Int(try await readUInt16())
        let primeData = try await readExact(keyLength)
        let serverPubData = try await readExact(keyLength)

        let prime = BigUInt(data: primeData)
        let serverPub = BigUInt(data: serverPubData)
        let gen = BigUInt(UInt64(generator))

        // Generate random private key
        var privKeyData = Data(count: keyLength)
        let randomStatus = privKeyData.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, ptr.count, ptr.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw RFBError.authFailed("Unable to generate Apple DH private key")
        }
        let clientPrivate = BigUInt(data: privKeyData)

        // Client public key: gen^private mod prime
        let clientPub = BigUInt.modpow(gen, clientPrivate, prime)
        let clientPubData = clientPub.toData(size: keyLength)

        // Shared secret: serverPub^private mod prime
        let sharedSecret = BigUInt.modpow(serverPub, clientPrivate, prime)
        let sharedSecretData = sharedSecret.toData(size: keyLength)

        // AES key = MD5(sharedSecret) — hash full keyLength-padded bytes
        let md5 = Insecure.MD5.hash(data: sharedSecretData)
        let aesKey = Data(md5)

        // Credential block: [username][password], each null-terminated in a
        // 64-byte slot. Apple ARD fills unused bytes with random data and uses
        // AES-128-ECB for this fixed-size block.
        var credentials = Data(count: 128)
        let randomCredentialStatus = credentials.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, ptr.count, ptr.baseAddress!)
        }
        guard randomCredentialStatus == errSecSuccess else {
            throw RFBError.authFailed("Unable to generate Apple DH credential padding")
        }
        var uBytes = Data(username.utf8.prefix(63))
        var pBytes = Data(password.utf8.prefix(63))
        uBytes.append(0)
        pBytes.append(0)
        credentials.replaceSubrange(0..<uBytes.count, with: uBytes)
        credentials.replaceSubrange(64..<(64 + pBytes.count), with: pBytes)

        // AES-128-ECB with no padding.
        let encBufferSize = 128
        var encBuffer = Data(count: encBufferSize)
        var encryptedLen = 0
        let status: CCCryptorStatus = aesKey.withUnsafeBytes { keyPtr in
            credentials.withUnsafeBytes { inPtr in
                encBuffer.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, kCCKeySizeAES128,
                        nil,
                        inPtr.baseAddress, 128,
                        outPtr.baseAddress, encBufferSize,
                        &encryptedLen
                    )
                }
            }
        }
        guard status == kCCSuccess, encryptedLen == 128 else {
            throw RFBError.authFailed("AES encryption failed (\(status))")
        }

        // Apple ARD expects ciphertext first, then the generated DH public key.
        try await write(encBuffer)
        try await write(clientPubData)

        Logger.shared.info("Apple DH auth exchange complete (keyLength=\(keyLength))")
    }

    // MARK: - VNC DES Authentication

    private func vncAuthResponse(password: String, challenge: Data) -> Data {
        let key = vncDESKey(password)
        var response = Data(count: 16)
        key.withUnsafeBytes { keyPtr in
            challenge.withUnsafeBytes { chalPtr in
                response.withUnsafeMutableBytes { outPtr in
                    var outLen = 0
                    // Encrypt first 8 bytes
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, 8,
                            nil,
                            chalPtr.baseAddress, 8,
                            outPtr.baseAddress, 8, &outLen)
                    // Encrypt second 8 bytes
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, 8,
                            nil,
                            chalPtr.baseAddress! + 8, 8,
                            outPtr.baseAddress! + 8, 8, &outLen)
                }
            }
        }
        return response
    }

    /// VNC uses DES with bits reversed in each key byte.
    private func vncDESKey(_ password: String) -> Data {
        var key = Data(count: 8)
        let bytes = Array(password.utf8.prefix(8))
        for i in 0..<bytes.count {
            key[i] = reverseBits(bytes[i])
        }
        return key
    }

    private func reverseBits(_ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var input = b
        for _ in 0..<8 {
            result = (result << 1) | (input & 1)
            input >>= 1
        }
        return result
    }

    // MARK: - Private: ServerInit

    private func readServerInit() async throws -> RFBServerInit {
        let width = try await readUInt16()
        let height = try await readUInt16()
        let pfData = try await readExact(16)
        let nameLen = try await readUInt32()
        let name = try await readString(Int(nameLen))
        return RFBServerInit(
            width: width, height: height,
            pixelFormat: RFBPixelFormat.decode(from: pfData),
            name: name
        )
    }

    // MARK: - Private: SetPixelFormat / SetEncodings

    private func sendSetPixelFormat(_ pf: RFBPixelFormat) async throws {
        var d = Data(count: 4 + 16)
        d[0] = RFBClientMessageType.setPixelFormat.rawValue
        d[1] = 0; d[2] = 0; d[3] = 0
        d.replaceSubrange(4..<20, with: pf.encode())
        try await write(d)
    }

    private func sendSetEncodings(_ encodings: [RFBEncoding]) async throws {
        var d = Data(count: 4 + encodings.count * 4)
        d[0] = RFBClientMessageType.setEncodings.rawValue
        d[1] = 0 // padding
        d.replaceSubrange(2..<4, with: UInt16(encodings.count).bigEndianBytes)
        for (i, enc) in encodings.enumerated() {
            d.replaceSubrange((4 + i * 4)..<(4 + i * 4 + 4), with: enc.rawValue.bigEndianBytes)
        }
        try await write(d)
    }

    // MARK: - Private: Read server messages

    private func readFramebufferUpdate() async throws -> ServerMessage {
        _ = try await readUInt8() // padding
        let numRects = Int(try await readUInt16())
        var rects: [RFBRect] = []
        var resizeWidth: UInt16 = 0
        var resizeHeight: UInt16 = 0
        var didResize = false
        var cursorUpdate: CursorShape?

        rectLoop: for _ in 0..<numRects {
            let x = try await readUInt16()
            let y = try await readUInt16()
            let w = try await readUInt16()
            let h = try await readUInt16()
            let enc = try await readInt32()

            switch enc {
            case RFBEncoding.raw.rawValue:
                let byteCount = try RFBEncodingDecoder.decodedByteCount(width: w, height: h)
                let data = try await readExact(byteCount)
                rects.append(RFBRect(x: x, y: y, width: w, height: h, encoding: enc, data: data))

            case RFBEncoding.copyRect.rawValue:
                let srcX = try await readUInt16()
                let srcY = try await readUInt16()
                var copyData = Data(count: 4)
                copyData.replaceSubrange(0..<2, with: srcX.bigEndianBytes)
                copyData.replaceSubrange(2..<4, with: srcY.bigEndianBytes)
                rects.append(RFBRect(x: x, y: y, width: w, height: h, encoding: enc, data: copyData))

            case RFBEncoding.hextile.rawValue:
                let data = try await RFBEncodingDecoder.decodeHextile(width: w, height: h) { count in
                    try await self.readExact(count)
                }
                rects.append(RFBRect(x: x, y: y, width: w, height: h, encoding: RFBEncoding.raw.rawValue, data: data))

            case RFBEncoding.zrle.rawValue:
                let compressedLength = try await readUInt32()
                guard compressedLength <= UInt32(RFBEncodingDecoder.maxDecodedRectBytes) else {
                    throw RFBError.protocolError("ZRLE rectangle compressed payload too large: \(compressedLength) bytes")
                }
                let compressed = try await readExact(Int(compressedLength))
                let data = try RFBEncodingDecoder.decodeZRLE(width: w, height: h, compressed: compressed, state: zrleDecodeState)
                rects.append(RFBRect(x: x, y: y, width: w, height: h, encoding: RFBEncoding.raw.rawValue, data: data))

            case RFBEncoding.tight.rawValue, RFBEncoding.tightPNG.rawValue:
                let data = try await RFBEncodingDecoder.decodeTight(
                    width: w,
                    height: h,
                    encoding: enc,
                    state: tightDecodeState
                ) { count in
                    try await self.readExact(count)
                }
                rects.append(RFBRect(x: x, y: y, width: w, height: h, encoding: RFBEncoding.raw.rawValue, data: data))

            case RFBEncoding.qemuExtendedKeyEvent.rawValue:
                serverSupportsQemuExtendedKey = true

            case RFBEncoding.lastRect.rawValue:
                break rectLoop

            case RFBEncoding.extendedDesktopSize.rawValue:
                // Payload: number-of-screens (u8), 3 bytes padding, then per-screen 16 bytes.
                serverSupportsExtendedDesktopSize = true
                let numScreens = Int(try await readUInt8())
                _ = try await readExact(3) // padding
                if numScreens > 0 {
                    _ = try await readExact(numScreens * 16)
                }
                resizeWidth = w
                resizeHeight = h
                didResize = true

            case RFBEncoding.cursor.rawValue:
                let pixelBytes = Int(w) * Int(h) * 4
                let maskBytes = ((Int(w) + 7) / 8) * Int(h)
                let pixels = pixelBytes > 0 ? try await readExact(pixelBytes) : Data()
                let mask = maskBytes > 0 ? try await readExact(maskBytes) : Data()
                cursorUpdate = CursorShape(
                    hotspotX: x, hotspotY: y,
                    width: w, height: h,
                    pixels: pixels, mask: mask
                )

            case RFBEncoding.desktopSize.rawValue:
                resizeWidth = w
                resizeHeight = h
                didResize = true

            default:
                throw RFBError.unsupportedEncoding(enc)
            }
        }

        if didResize {
            return .desktopResize(width: resizeWidth, height: resizeHeight)
        }
        if let cursorUpdate, rects.isEmpty {
            return .cursorShape(cursorUpdate)
        }
        // If cursor arrived alongside framebuffer rects, stash it for later.
        // The session layer will pick it up via a dedicated property.
        if let cursorUpdate {
            pendingCursorShape = cursorUpdate
        }
        return .framebufferUpdate(rects)
    }

    private func skipColourMapEntries() async throws {
        _ = try await readUInt8() // padding
        _ = try await readUInt16() // firstColour
        let numColours = Int(try await readUInt16())
        _ = try await readExact(numColours * 6) // r, g, b × 2 bytes each
    }

    private func readServerCutText() async throws -> ServerMessage {
        _ = try await readExact(3) // padding
        let len = try await readUInt32()
        let text = try await readString(Int(len))
        return .serverCutText(text)
    }

    // MARK: - Buffered binary I/O

    private func withReadTimeout<T>(
        stage: String,
        timeout: TimeInterval?,
        operation: () async throws -> T
    ) async throws -> T {
        guard let timeout else {
            return try await operation()
        }
        let previousDeadline = activeReadDeadline
        activeReadDeadline = ReadDeadline(stage: stage, deadline: Date().addingTimeInterval(timeout))
        defer { activeReadDeadline = previousDeadline }
        return try await operation()
    }

    private func readExact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk = try await receiveChunk(timeout: currentReadTimeout())
            if chunk.isEmpty { throw RFBError.disconnected }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }

    private func currentReadTimeout() throws -> (stage: String, seconds: TimeInterval)? {
        guard let activeReadDeadline else { return nil }
        let seconds = activeReadDeadline.deadline.timeIntervalSinceNow
        guard seconds > 0 else {
            connection.cancel()
            throw RFBError.timeout(stage: activeReadDeadline.stage)
        }
        return (activeReadDeadline.stage, seconds)
    }

    private func readUInt8() async throws -> UInt8 {
        let d = try await readExact(1)
        return d[0]
    }

    private func readUInt16() async throws -> UInt16 {
        let d = try await readExact(2)
        return UInt16(d[0]) << 8 | UInt16(d[1])
    }

    private func readUInt32() async throws -> UInt32 {
        let d = try await readExact(4)
        return UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])
    }

    private func readInt32() async throws -> Int32 {
        Int32(bitPattern: try await readUInt32())
    }

    private func readString(_ count: Int) async throws -> String {
        let d = try await readExact(count)
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .ascii) ?? ""
    }

    private func write(_ data: Data) async throws {
        guard isOpen else { throw RFBError.disconnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private func receiveChunk(timeout: (stage: String, seconds: TimeInterval)?) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let gate = OneShotContinuation(cont)
            let timeoutItem = timeout.map { timeout in
                DispatchWorkItem { [connection] in
                    if gate.resume(throwing: RFBError.timeout(stage: timeout.stage)) {
                        connection.cancel()
                    }
                }
            }
            if let timeoutItem, let timeout {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout.seconds, execute: timeoutItem)
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, isComplete, error in
                if let error = error {
                    gate.resume(throwing: error)
                } else if let data = data {
                    gate.resume(returning: data)
                } else if isComplete {
                    gate.resume(returning: Data())
                } else {
                    gate.resume(returning: Data())
                }
            }
        }
    }
}

// MARK: - Big-endian helpers

extension UInt16 {
    nonisolated var bigEndianBytes: Data {
        var v = self.bigEndian
        return Data(bytes: &v, count: 2)
    }
}

extension UInt32 {
    nonisolated var bigEndianBytes: Data {
        var v = self.bigEndian
        return Data(bytes: &v, count: 4)
    }
}

extension Int32 {
    nonisolated var bigEndianBytes: Data {
        var v = self.bigEndian
        return Data(bytes: &v, count: 4)
    }
}
