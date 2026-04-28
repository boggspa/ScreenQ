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
        // ZRLE uses a persistent zlib stream across rectangles. Keep it out of
        // negotiation until the decoder owns connection-lifetime inflate state.
        .tight,
        .tightPNG,
        .hextile,
        .raw,
        .copyRect,
        .desktopSize
    ]

    private let connection: NWConnection
    private var buffer = Data()
    private(set) var isOpen = false
    private let tightDecodeState = RFBEncodingDecoder.TightDecodeState()
    private var offeredSecurityTypes: [UInt8] = []
    private var selectedSecurityType: UInt8?

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

    func connect(username: String?, password: String?, securityPreference: RFBSecurityPreference = .vncPasswordFirst) async throws -> RFBServerInit {
        try await startTCP()

        // 1. Version handshake
        let version = try await negotiateVersion()

        // 2. Security
        try await negotiateSecurity(version: version, username: username, password: password, securityPreference: securityPreference)

        // 3. ClientInit (shared = true)
        try await write(Data([1]))

        // 4. ServerInit
        let serverInit = try await readServerInit()

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
            mode: RFBSecurityMode(type: selectedSecurityType),
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
    }

    // MARK: - Private: TCP

    private func startTCP() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var didResume = false
            connection.stateUpdateHandler = { [weak self] state in
                guard !didResume else { return }
                switch state {
                case .ready:
                    didResume = true
                    Task { await self?.markOpen() }
                    cont.resume()
                case .failed(let err):
                    didResume = true
                    cont.resume(throwing: RFBError.connectionFailed(err.localizedDescription))
                case .cancelled:
                    didResume = true
                    cont.resume(throwing: RFBError.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func markOpen() { isOpen = true }

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
        let version = major * 10 + minor // 33, 37, 38

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

        try await performAuth(type: chosenType, username: username, password: password)

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

    private func performAuth(type: UInt8, username: String?, password: String?) async throws {
        switch type {
        case RFBSecurityType.none.rawValue:
            break
        case RFBSecurityType.vncAuth.rawValue:
            guard let password = password, !password.isEmpty else {
                throw RFBError.authRequired
            }
            let challenge = try await readExact(16)
            let response = vncAuthResponse(password: password, challenge: challenge)
            try await write(response)
        case RFBSecurityType.appleDH.rawValue:
            guard let username = username, !username.isEmpty,
                  let password = password, !password.isEmpty else {
                throw RFBError.credentialsRequired
            }
            try await performAppleDHAuth(username: username, password: password)
        default:
            throw RFBError.unsupportedSecurity(type)
        }
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

        for _ in 0..<numRects {
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
                let data = try RFBEncodingDecoder.decodeZRLE(width: w, height: h, compressed: compressed)
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

    private func readExact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk = try await receiveChunk()
            if chunk.isEmpty { throw RFBError.disconnected }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
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

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: Data())
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
