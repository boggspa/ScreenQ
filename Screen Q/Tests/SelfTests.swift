//
//  SelfTests.swift
//  Screen Q
//
//  Deterministic, pure-Swift tests runnable from DiagnosticsView. We avoid
//  XCTest here so we don't have to wire a separate test target into the
//  filesystem-synchronized project group. These cover protocol framing
//  (round-trip encode/decode) and viewer-side coordinate mapping.
//

import Foundation
import CoreGraphics
import Compression
import ImageIO

enum SelfTests {

    struct Result: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let passed: Bool
        let detail: String?
    }

    static func runAll() -> [Result] {
        var results: [Result] = []
        results.append(testJSONFrameRoundTrip())
        results.append(testVideoFrameRoundTrip())
        results.append(testStreamDecoderPartialFeed())
        results.append(testStreamDecoderRejectsBadMagic())
        results.append(testCoordinateMappingFitLetterbox())
        results.append(testCoordinateMappingFill())
        results.append(testCoordinateMappingOutsideRect())
        results.append(testCoordinateMappingWithViewportZoom())
        results.append(testViewportZoomKeepsAnchorStable())
        results.append(testNormalisedClamping())
        results.append(testRemoteInputEventCodableRoundTrip())
        results.append(testRemoteConnectionProtocolDefaults())
        results.append(testRDPProfileParser())
        results.append(testRDPFrameConversion())
        results.append(testRDPSecurityStatus())
        results.append(testRDPCredentialNormalisation())
        results.append(testRDPAuthFailureClassifier())
        results.append(testSavedConnectionProtocolResolution())
        results.append(testSessionStateRoutingFlags())
        results.append(testNetworkTrustScopeClassification())
        results.append(testVNCRemoteSecurityStatus())
        results.append(testRFBSecurityNegotiationPolicy())
        results.append(testZRLEDecoderRawTile())
        results.append(testZRLEDecoderSolidTile())
        results.append(testZRLEDecoderPackedPaletteTile())
        results.append(testZRLEDecoderRejectsTruncatedTile())
        results.append(testTightFillDecoder())
        results.append(testTightCopySmallDecoder())
        results.append(testTightPaletteMonoDecoder())
        results.append(testTightGradientDecoder())
        results.append(testTightCompressedCopyDecoder())
        results.append(testTightNoZlibDecoder())
        results.append(testTightPNGDecoder())
        return results
    }

    // MARK: - Helpers

    private static func ok(_ name: String) -> Result {
        Result(name: name, passed: true, detail: nil)
    }
    private static func fail(_ name: String, _ detail: String) -> Result {
        Result(name: name, passed: false, detail: detail)
    }

    // MARK: - Protocol framing

    private static func testJSONFrameRoundTrip() -> Result {
        do {
            let hello = HelloMessage(
                peerID: UUID(),
                displayName: "TestViewer",
                platform: .iOS,
                appVersion: "1.0",
                capabilities: .viewerOnly,
                ephemeralPublicKey: nil
            )
            let bytes = try FrameCodec.encodeJSONMessage(type: .hello, sequence: 7, message: hello)
            let decoder = FrameStreamDecoder()
            decoder.feed(bytes)
            guard let decoded = try decoder.nextFrame() else { return fail("JSON round-trip", "no frame produced") }
            guard decoded.header.type == .hello else { return fail("JSON round-trip", "wrong type") }
            guard decoded.header.sequence == 7 else { return fail("JSON round-trip", "wrong sequence") }
            let restored = try JSONDecoder().decode(HelloMessage.self, from: decoded.body)
            guard restored.displayName == "TestViewer" else { return fail("JSON round-trip", "wrong displayName") }
            guard try decoder.nextFrame() == nil else { return fail("JSON round-trip", "extra frame produced") }
            return ok("JSON frame round-trip")
        } catch {
            return fail("JSON frame round-trip", "\(error)")
        }
    }

    private static func testVideoFrameRoundTrip() -> Result {
        do {
            let payload = Data((0..<2048).map { UInt8($0 % 256) })
            let meta = VideoFrameMeta(
                sequence: 42,
                captureTimestamp: 1_700_000_000.5,
                pixelWidth: 1920,
                pixelHeight: 1080,
                displayID: 1,
                encoding: .jpeg,
                isKeyFrame: true,
                payloadSize: payload.count
            )
            let bytes = try FrameCodec.encodeVideoFrame(sequence: 42, meta: meta, payload: payload)
            let decoder = FrameStreamDecoder()
            decoder.feed(bytes)
            guard let frame = try decoder.nextFrame() else { return fail("Video round-trip", "no frame") }
            let (restoredMeta, restoredPayload) = try FrameCodec.decodeVideoFrame(body: frame.body)
            guard restoredMeta == meta else { return fail("Video round-trip", "meta differs") }
            guard restoredPayload == payload else { return fail("Video round-trip", "payload differs") }
            return ok("Video frame round-trip")
        } catch {
            return fail("Video round-trip", "\(error)")
        }
    }

    private static func testStreamDecoderPartialFeed() -> Result {
        do {
            let msg = PingMessage(clientTimestamp: 123.456)
            let bytes = try FrameCodec.encodeJSONMessage(type: .ping, sequence: 1, message: msg)
            let decoder = FrameStreamDecoder()
            // Feed one byte at a time.
            for b in bytes {
                decoder.feed(Data([b]))
            }
            guard let frame = try decoder.nextFrame() else { return fail("Partial feed", "no frame") }
            guard frame.header.type == .ping else { return fail("Partial feed", "wrong type") }
            return ok("Stream decoder accepts byte-by-byte feed")
        } catch {
            return fail("Partial feed", "\(error)")
        }
    }

    private static func testStreamDecoderRejectsBadMagic() -> Result {
        let decoder = FrameStreamDecoder()
        var garbage = Data(count: ScreenQProtocol.headerSize)
        for i in 0..<garbage.count { garbage[i] = 0xFF }
        decoder.feed(garbage)
        do {
            _ = try decoder.nextFrame()
            return fail("Reject bad magic", "decoder accepted bad header")
        } catch FrameCodecError.badMagic {
            return ok("Decoder rejects bad magic")
        } catch {
            return fail("Reject bad magic", "wrong error: \(error)")
        }
    }

    // MARK: - Coordinate mapping

    private static func testCoordinateMappingFitLetterbox() -> Result {
        // Canvas 1000x1000, remote 1920x1080 (16:9 wider than 1:1).
        // In fit mode the remote should letterbox top/bottom.
        let g = CanvasGeometry(
            canvasSize: CGSize(width: 1000, height: 1000),
            remotePixelSize: CGSize(width: 1920, height: 1080),
            fit: true
        )
        // Drawn rect height = 1000 / (1920/1080) = 562.5 -> y in [218.75, 781.25]
        let drawnHeight = 1000.0 / (1920.0 / 1080.0)
        let yOff = (1000.0 - drawnHeight) / 2.0
        let center = CGPoint(x: 500, y: yOff + drawnHeight / 2)
        guard let n = g.normalised(localPoint: center) else {
            return fail("Coord mapping fit", "center should be inside drawn rect")
        }
        guard abs(n.x - 0.5) < 0.001, abs(n.y - 0.5) < 0.001 else {
            return fail("Coord mapping fit", "center not normalised: \(n)")
        }
        // A point above the letterbox should be rejected.
        if g.normalised(localPoint: CGPoint(x: 500, y: 10)) != nil {
            return fail("Coord mapping fit", "letterbox bar should be ignored")
        }
        return ok("Coord mapping fit (letterbox)")
    }

    private static func testCoordinateMappingFill() -> Result {
        let g = CanvasGeometry(
            canvasSize: CGSize(width: 1000, height: 1000),
            remotePixelSize: CGSize(width: 1920, height: 1080),
            fit: false
        )
        // Fill mode crops; the canvas centre should still map to remote centre.
        guard let n = g.normalised(localPoint: CGPoint(x: 500, y: 500)) else {
            return fail("Coord mapping fill", "centre should be inside drawn rect")
        }
        guard abs(n.x - 0.5) < 0.001 else {
            return fail("Coord mapping fill", "x centre off: \(n.x)")
        }
        return ok("Coord mapping fill")
    }

    private static func testCoordinateMappingOutsideRect() -> Result {
        let g = CanvasGeometry(
            canvasSize: CGSize(width: 100, height: 100),
            remotePixelSize: CGSize(width: 200, height: 100),
            fit: true
        )
        // A negative point cannot map.
        if g.normalised(localPoint: CGPoint(x: -10, y: 50)) != nil {
            return fail("Coord mapping outside", "out-of-bounds accepted")
        }
        return ok("Coord mapping ignores out-of-bounds")
    }

    private static func testCoordinateMappingWithViewportZoom() -> Result {
        let g = CanvasGeometry(
            canvasSize: CGSize(width: 1000, height: 1000),
            remotePixelSize: CGSize(width: 1000, height: 1000),
            fit: true,
            viewport: ViewportTransform(scale: 2, offset: .zero)
        )
        guard let n = g.normalised(localPoint: CGPoint(x: 250, y: 500)) else {
            return fail("Coord mapping viewport zoom", "point should be inside zoomed viewport")
        }
        guard abs(n.x - 0.375) < 0.001, abs(n.y - 0.5) < 0.001 else {
            return fail("Coord mapping viewport zoom", "unexpected normalised point: \(n)")
        }
        return ok("Coord mapping includes viewport zoom")
    }

    private static func testViewportZoomKeepsAnchorStable() -> Result {
        let geometry = CanvasGeometry(
            canvasSize: CGSize(width: 1000, height: 1000),
            remotePixelSize: CGSize(width: 1000, height: 1000),
            fit: true
        )
        let anchor = CGPoint(x: 250, y: 500)
        guard let before = geometry.normalised(localPoint: anchor) else {
            return fail("Viewport zoom anchor", "anchor should be inside base geometry")
        }

        let viewport = ViewportTransform.identity.applyingMagnification(2, around: anchor, in: geometry)
        let zoomed = CanvasGeometry(
            canvasSize: geometry.canvasSize,
            remotePixelSize: geometry.remotePixelSize,
            fit: geometry.fit,
            viewport: viewport
        )
        guard let after = zoomed.normalised(localPoint: anchor) else {
            return fail("Viewport zoom anchor", "anchor should remain inside zoomed geometry")
        }
        guard abs(before.x - after.x) < 0.001, abs(before.y - after.y) < 0.001 else {
            return fail("Viewport zoom anchor", "anchor shifted from \(before) to \(after)")
        }
        return ok("Viewport zoom keeps pinch anchor stable")
    }

    private static func testNormalisedClamping() -> Result {
        let p = NormalisedPoint(x: -1, y: 5)
        if p.x != 0 || p.y != 1 {
            return fail("Normalised clamp", "got (\(p.x), \(p.y))")
        }
        return ok("NormalisedPoint clamps to 0...1")
    }

    private static func testRemoteInputEventCodableRoundTrip() -> Result {
        let cases: [RemoteInputEvent] = [
            .pointerMove(NormalisedPoint(x: 0.25, y: 0.75), modifiers: []),
            .pointerDown(NormalisedPoint(x: 0.5, y: 0.5), button: .right, modifiers: []),
            .scroll(deltaX: 0, deltaY: -10, at: NormalisedPoint(x: 0.4, y: 0.4), modifiers: []),
            .keyDown(.returnKey, modifiers: [.command]),
            .keyUp(.tab, modifiers: []),
            .textInput("Hello, Screen Q")
        ]
        do {
            for original in cases {
                let data = try JSONEncoder().encode(original)
                let restored = try JSONDecoder().decode(RemoteInputEvent.self, from: data)
                if restored != original {
                    return fail("InputEvent round-trip", "differs: \(original) vs \(restored)")
                }
            }
            return ok("RemoteInputEvent codable round-trip")
        } catch {
            return fail("InputEvent round-trip", "\(error)")
        }
    }

    // MARK: - Mode / route helpers

    private static func testRemoteConnectionProtocolDefaults() -> Result {
        guard RemoteConnectionProtocol.screenQ.defaultPort == ScreenQProtocol.defaultPort else {
            return fail("Protocol defaults", "Screen Q default port changed unexpectedly")
        }
        guard RemoteConnectionProtocol.vnc.defaultPort == 5900 else {
            return fail("Protocol defaults", "VNC default port should route to 5900")
        }
        guard RemoteConnectionProtocol.macScreenSharing.defaultPort == 5900 else {
            return fail("Protocol defaults", "Mac Screen Sharing should use the RFB port")
        }
        guard RemoteConnectionProtocol.rdp.defaultPort == 3389 else {
            return fail("Protocol defaults", "RDP default port should be 3389")
        }
        guard RemoteConnectionProtocol.screenQ.isAvailable else {
            return fail("Protocol defaults", "Screen Q should be selectable")
        }
        guard RemoteConnectionProtocol.vnc.isAvailable else {
            return fail("Protocol defaults", "VNC should be selectable")
        }
        guard RemoteConnectionProtocol.macScreenSharing.isAvailable else {
            return fail("Protocol defaults", "Mac Screen Sharing should be selectable")
        }
        guard RemoteConnectionProtocol.rdp.isAvailable else {
            return fail("Protocol defaults", "RDP preview route should be selectable")
        }
        guard RemoteConnectionProtocol.screenQ.connectionKind == .screenQ,
              RemoteConnectionProtocol.macScreenSharing.connectionKind == .macScreenSharing,
              RemoteConnectionProtocol.vnc.connectionKind == .vnc,
              RemoteConnectionProtocol.rdp.connectionKind == .rdpReserved else {
            return fail("Protocol defaults", "protocol did not map to expected connection kind")
        }
        return ok("Protocol defaults route supported modes")
    }

    private static func testRDPProfileParser() -> Result {
        let rdp = """
        full address:s:100.76.201.41
        username:s:.\\chris.admin
        dynamic resolution:i:1
        administrative session:i:1
        connect to console:i:1
        redirectclipboard:i:1
        audiomode:i:0
        allow font smoothing:i:1
        """

        do {
            let profile = try RDPConnectionProfile(rdpFileText: rdp, fallbackDisplayName: "Test PC")
            guard profile.host == "100.76.201.41", profile.port == 3389 else {
                return fail("RDP profile parser", "wrong endpoint: \(profile.address)")
            }
            guard profile.domain == ".", profile.username == "chris.admin" else {
                return fail("RDP profile parser", "wrong username split: \(profile.normalizedUsername ?? "nil")")
            }
            guard profile.dynamicResolution,
                  profile.administrativeSession,
                  profile.connectToConsole,
                  profile.redirectClipboard,
                  profile.redirectAudio,
                  profile.allowFontSmoothing else {
                return fail("RDP profile parser", "expected boolean flags were not parsed")
            }
            guard profile.networkScope == .tailscale else {
                return fail("RDP profile parser", "100.64.0.0/10 should classify as Tailscale")
            }
            return ok("RDP profile parser imports .rdp settings")
        } catch {
            return fail("RDP profile parser", "\(error)")
        }
    }

    private static func testRDPFrameConversion() -> Result {
        let frame = RDPEngineFrame(
            width: 2,
            height: 1,
            bytesPerRow: 8,
            data: Data([
                0, 0, 255, 255,
                0, 255, 0, 255
            ])
        )
        guard let image = frame.makeCGImage() else {
            return fail("RDP frame conversion", "BGRA frame did not produce a CGImage")
        }
        guard image.width == 2, image.height == 1 else {
            return fail("RDP frame conversion", "wrong image dimensions: \(image.width)x\(image.height)")
        }
        return ok("RDP BGRA frames convert to CGImage")
    }

    private static func testRDPSecurityStatus() -> Result {
        let certificate = RDPCertificateInfo(
            subject: "CN=windows-pc",
            issuer: "CN=windows-pc",
            fingerprintSHA256: "AA:BB:CC",
            validFrom: nil,
            validUntil: nil,
            host: "100.76.201.41"
        )
        let report = RDPSecurityReport(
            tlsProtocol: "TLS 1.3",
            nlaSucceeded: true,
            isTransportEncrypted: true,
            isAuthenticated: true,
            certificate: certificate,
            serverIdentityVerified: true
        )
        let status = RemoteSecurityStatus.rdp(report: report, scope: .tailscale)
        guard status.level == .encrypted,
              status.isTransportEncrypted,
              status.isAuthenticated,
              status.recommendedAction == nil else {
            return fail("RDP security status", "confirmed TLS/NLA should be reported as encrypted")
        }

        let pending = RemoteSecurityStatus.rdpCertificatePending(certificate, scope: .tailscale)
        guard pending.level == .unknown, !pending.isAuthenticated else {
            return fail("RDP security status", "pending certificate should not claim authentication")
        }
        return ok("RDP security status stays truthful")
    }

    private static func testRDPCredentialNormalisation() -> Result {
        let domainUser = RDPCredentials.fromUserInput(
            domain: nil,
            username: "PC-2-VMix\\chris",
            password: "secret"
        )
        guard domainUser.domain == "PC-2-VMix", domainUser.username == "chris" else {
            return fail("RDP credential normalisation", "DOMAIN\\user was not split")
        }

        let explicitDomain = RDPCredentials.fromUserInput(
            domain: "WORKGROUP",
            username: "chris",
            password: "secret"
        )
        guard explicitDomain.domain == "WORKGROUP", explicitDomain.username == "chris" else {
            return fail("RDP credential normalisation", "explicit domain was not preserved")
        }

        let certificate = RDPCertificateInfo(
            subject: "CN = PC-2-VMix",
            issuer: "CN = PC-2-VMix",
            fingerprintSHA256: "aa",
            validFrom: nil,
            validUntil: nil,
            host: "100.76.201.41"
        )
        guard certificate.commonName == "PC-2-VMix" else {
            return fail("RDP credential normalisation", "certificate CN was not parsed")
        }

        return ok("RDP credentials normalise Windows usernames")
    }

    private static func testRDPAuthFailureClassifier() -> Result {
        let logonFailure = Int32((2 << 16) | 0x14)
        guard RDPFailureClassifier.isCredentialOrAccountFailure(
            statusCode: logonFailure,
            message: "FreeRDP failed to connect: Logon failed."
        ) else {
            return fail("RDP auth failure classifier", "logon failure should prompt for fresh credentials")
        }

        let transportFailure = Int32((2 << 16) | 0x0D)
        guard !RDPFailureClassifier.isCredentialOrAccountFailure(
            statusCode: transportFailure,
            message: "FreeRDP failed to connect: The connection transport layer failed."
        ) else {
            return fail("RDP auth failure classifier", "transport failure should not clear saved credentials")
        }

        return ok("RDP auth failures clear cached credentials")
    }

    private static func testSavedConnectionProtocolResolution() -> Result {
        let legacyVNC = SavedConnection(
            displayName: "Legacy VNC",
            host: "mac.local",
            port: RemoteConnectionProtocol.vnc.defaultPort,
            connectionProtocol: nil
        )
        guard legacyVNC.resolvedProtocol == .vnc else {
            return fail("Saved connection protocol", "legacy port 5900 should resolve to VNC")
        }

        let defaultScreenQ = SavedConnection(
            displayName: "Screen Q",
            host: "screenq.local",
            port: ScreenQProtocol.defaultPort,
            connectionProtocol: nil
        )
        guard defaultScreenQ.resolvedProtocol == .screenQ else {
            return fail("Saved connection protocol", "Screen Q default port should resolve to Screen Q")
        }

        let explicitScreenQOnVNC = SavedConnection(
            displayName: "Explicit Screen Q",
            host: "custom.local",
            port: RemoteConnectionProtocol.vnc.defaultPort,
            connectionProtocol: .screenQ
        )
        guard explicitScreenQOnVNC.resolvedProtocol == .screenQ else {
            return fail("Saved connection protocol", "explicit protocol should override port heuristic")
        }

        let explicitRDP = SavedConnection(
            displayName: "Future RDP",
            host: "pc.local",
            port: RemoteConnectionProtocol.rdp.defaultPort,
            connectionProtocol: .rdp
        )
        guard explicitRDP.resolvedProtocol == .rdp else {
            return fail("Saved connection protocol", "explicit RDP should round-trip for saved entries")
        }

        return ok("Saved connections resolve protocol routes")
    }

    private static func testSessionStateRoutingFlags() -> Result {
        let inactive: [SessionState] = [
            .idle,
            .ended(reason: "done"),
            .failed(reason: "boom")
        ]
        for state in inactive where state.isActive {
            return fail("Session routing flags", "\(state) should not be active")
        }

        let active: [SessionState] = [
            .advertising,
            .browsing,
            .connecting(host: "mac.local"),
            .handshake,
            .awaitingPairingCode,
            .awaitingHostApproval,
            .approved,
            .streaming,
            .viewOnly
        ]
        for state in active where !state.isActive {
            return fail("Session routing flags", "\(state) should be active")
        }

        guard SessionState.approved.allowsInputInjection else {
            return fail("Session routing flags", "approved should allow input")
        }
        guard SessionState.streaming.allowsInputInjection else {
            return fail("Session routing flags", "streaming should allow input")
        }
        guard !SessionState.viewOnly.allowsInputInjection else {
            return fail("Session routing flags", "viewOnly should not allow input")
        }
        guard !SessionState.handshake.allowsInputInjection else {
            return fail("Session routing flags", "handshake should not allow input")
        }

        return ok("Session states expose active/input flags")
    }

    private static func testNetworkTrustScopeClassification() -> Result {
        guard NetworkTrustScope.classify(host: "100.99.131.73") == .tailscale else {
            return fail("Network trust scope", "100.64.0.0/10 should classify as tailscale")
        }
        guard NetworkTrustScope.classify(host: "192.168.0.14") == .privateLAN else {
            return fail("Network trust scope", "RFC1918 should classify as private LAN")
        }
        guard NetworkTrustScope.classify(host: "8.8.8.8") == .publicInternet else {
            return fail("Network trust scope", "public IPv4 should classify as public internet")
        }
        guard NetworkTrustScope.classify(host: "pc.tailnet.ts.net") == .tailscale else {
            return fail("Network trust scope", "Tailscale MagicDNS should classify as tailscale")
        }
        return ok("Network trust scope classifies VNC routes")
    }

    private static func testVNCRemoteSecurityStatus() -> Result {
        let report = RFBSecurityReport(mode: .vncAuth, offeredModes: [.vncAuth, .none])
        let tailscale = RemoteSecurityStatus.vnc(report: report, scope: .tailscale)
        guard tailscale.level == .networkProtected else {
            return fail("VNC security status", "VNC auth over Tailscale should be network-protected")
        }
        guard !tailscale.isTransportEncrypted else {
            return fail("VNC security status", "VNC should not claim transport encryption")
        }

        let publicStatus = RemoteSecurityStatus.vnc(report: report, scope: .publicInternet)
        guard publicStatus.level == .legacyAuth, publicStatus.recommendedAction != nil else {
            return fail("VNC security status", "Public VNC should be warned as legacy auth")
        }

        return ok("VNC security status stays honest")
    }

    private static func testRFBSecurityNegotiationPolicy() -> Result {
        let offered = [
            RFBSecurityType.vncAuth.rawValue,
            RFBSecurityType.appleDH.rawValue
        ]

        let macChoice = RFBSecurityNegotiationPolicy.chooseSecurityType(
            offered: offered,
            hasUsername: false,
            preference: .macAccountFirst
        )
        guard macChoice == RFBSecurityType.appleDH.rawValue else {
            return fail("RFB security negotiation", "Mac Screen Sharing should prefer Apple DH")
        }

        let genericWithUsername = RFBSecurityNegotiationPolicy.chooseSecurityType(
            offered: offered,
            hasUsername: true,
            preference: .vncPasswordFirst
        )
        guard genericWithUsername == RFBSecurityType.appleDH.rawValue else {
            return fail("RFB security negotiation", "supplying a username should prefer Apple DH before VNC auth")
        }

        let genericPasswordOnly = RFBSecurityNegotiationPolicy.chooseSecurityType(
            offered: offered,
            hasUsername: false,
            preference: .vncPasswordFirst
        )
        guard genericPasswordOnly == RFBSecurityType.vncAuth.rawValue else {
            return fail("RFB security negotiation", "generic VNC without a username should prefer VNC auth")
        }

        return ok("RFB security negotiation prefers Apple DH when appropriate")
    }

    // MARK: - RFB encoding decoders

    private static func testZRLEDecoderRawTile() -> Result {
        do {
            var inflated = Data([0]) // raw tile
            inflated.append(contentsOf: [
                0, 0, 255,   // red in little-endian compact XRGB
                0, 255, 0    // green
            ])
            let decoded = try RFBEncodingDecoder.decodeZRLE(
                width: 2,
                height: 1,
                compressed: zlibCompress(inflated)
            )
            let expected = Data([
                0, 0, 255, 0,
                0, 255, 0, 0
            ])
            guard decoded == expected else {
                return fail("ZRLE raw tile", "decoded bytes did not match expected XRGB")
            }
            return ok("ZRLE raw tile decodes to XRGB")
        } catch {
            return fail("ZRLE raw tile", "\(error)")
        }
    }

    private static func testZRLEDecoderSolidTile() -> Result {
        do {
            let inflated = Data([
                1,          // palette size 1, no RLE
                255, 0, 0   // blue in little-endian compact XRGB
            ])
            let decoded = try RFBEncodingDecoder.decodeZRLE(
                width: 3,
                height: 2,
                compressed: zlibCompress(inflated)
            )
            var expected = Data()
            for _ in 0..<6 {
                expected.append(contentsOf: [255, 0, 0, 0])
            }
            guard decoded == expected else {
                return fail("ZRLE solid tile", "solid palette did not fill the whole tile")
            }
            return ok("ZRLE solid tile decodes")
        } catch {
            return fail("ZRLE solid tile", "\(error)")
        }
    }

    private static func testZRLEDecoderPackedPaletteTile() -> Result {
        do {
            let inflated = Data([
                2,                  // palette size 2, packed 1-bit indices
                0, 0, 0,            // black
                255, 255, 255,      // white
                0b0110_0000         // black, white, white, black
            ])
            let decoded = try RFBEncodingDecoder.decodeZRLE(
                width: 4,
                height: 1,
                compressed: zlibCompress(inflated)
            )
            let expected = Data([
                0, 0, 0, 0,
                255, 255, 255, 0,
                255, 255, 255, 0,
                0, 0, 0, 0
            ])
            guard decoded == expected else {
                return fail("ZRLE packed palette", "palette indices did not unpack correctly")
            }
            return ok("ZRLE packed palette decodes")
        } catch {
            return fail("ZRLE packed palette", "\(error)")
        }
    }

    private static func testZRLEDecoderRejectsTruncatedTile() -> Result {
        do {
            _ = try RFBEncodingDecoder.decodeZRLE(
                width: 2,
                height: 1,
                compressed: zlibCompress(Data([0]))
            )
            return fail("ZRLE truncated tile", "decoder accepted a raw tile without pixel bytes")
        } catch RFBError.protocolError {
            return ok("ZRLE decoder rejects truncated tile data")
        } catch {
            return fail("ZRLE truncated tile", "wrong error: \(error)")
        }
    }

    private static func testTightFillDecoder() -> Result {
        do {
            let payload = Data([
                0x80,        // fill subencoding
                255, 0, 0    // red in Tight RGB order
            ])
            let decoded = try RFBEncodingDecoder.decodeTightPayload(
                width: 2,
                height: 1,
                encoding: RFBEncoding.tight.rawValue,
                payload: payload,
                state: RFBEncodingDecoder.TightDecodeState()
            )
            let expected = Data([
                0, 0, 255, 0,
                0, 0, 255, 0
            ])
            guard decoded == expected else {
                return fail("Tight fill", "fill colour did not decode to XRGB")
            }
            return ok("Tight fill decodes")
        } catch {
            return fail("Tight fill", "\(error)")
        }
    }

    private static func testTightCopySmallDecoder() -> Result {
        do {
            let payload = Data([
                0x00,        // basic, stream 0, implicit copy, uncompressed because payload is < 12 bytes
                255, 0, 0,
                0, 255, 0
            ])
            let decoded = try RFBEncodingDecoder.decodeTightPayload(
                width: 2,
                height: 1,
                encoding: RFBEncoding.tight.rawValue,
                payload: payload,
                state: RFBEncodingDecoder.TightDecodeState()
            )
            let expected = Data([
                0, 0, 255, 0,
                0, 255, 0, 0
            ])
            guard decoded == expected else {
                return fail("Tight copy", "copy filter did not decode RGB to XRGB")
            }
            return ok("Tight copy filter decodes")
        } catch {
            return fail("Tight copy", "\(error)")
        }
    }

    private static func testTightPaletteMonoDecoder() -> Result {
        do {
            let payload = Data([
                0x40,        // basic + explicit filter
                0x01,        // palette filter
                0x01,        // two colours
                0, 0, 0,
                255, 255, 255,
                0b1010_0000  // white, black, white, black
            ])
            let decoded = try RFBEncodingDecoder.decodeTightPayload(
                width: 4,
                height: 1,
                encoding: RFBEncoding.tight.rawValue,
                payload: payload,
                state: RFBEncodingDecoder.TightDecodeState()
            )
            let expected = Data([
                255, 255, 255, 0,
                0, 0, 0, 0,
                255, 255, 255, 0,
                0, 0, 0, 0
            ])
            guard decoded == expected else {
                return fail("Tight mono palette", "1-bit palette did not unpack correctly")
            }
            return ok("Tight 1-bit palette decodes")
        } catch {
            return fail("Tight mono palette", "\(error)")
        }
    }

    private static func testTightGradientDecoder() -> Result {
        do {
            let payload = Data([
                0x40,        // basic + explicit filter
                0x02,        // gradient filter
                10, 20, 30,
                5, 5, 5
            ])
            let decoded = try RFBEncodingDecoder.decodeTightPayload(
                width: 2,
                height: 1,
                encoding: RFBEncoding.tight.rawValue,
                payload: payload,
                state: RFBEncodingDecoder.TightDecodeState()
            )
            let expected = Data([
                30, 20, 10, 0,
                35, 25, 15, 0
            ])
            guard decoded == expected else {
                return fail("Tight gradient", "gradient predictor did not reconstruct expected pixels")
            }
            return ok("Tight gradient filter decodes")
        } catch {
            return fail("Tight gradient", "\(error)")
        }
    }

    private static func testTightCompressedCopyDecoder() -> Result {
        do {
            let rgb = Data([
                255, 0, 0,
                0, 255, 0,
                0, 0, 255,
                255, 255, 255
            ])
            let compressed = try zlibCompress(rgb)
            var payload = Data([0x01]) // reset stream 0, basic stream 0, implicit copy
            payload.append(tightCompactLength(compressed.count))
            payload.append(compressed)
            let decoded = try RFBEncodingDecoder.decodeTightPayload(
                width: 4,
                height: 1,
                encoding: RFBEncoding.tight.rawValue,
                payload: payload,
                state: RFBEncodingDecoder.TightDecodeState()
            )
            let expected = Data([
                0, 0, 255, 0,
                0, 255, 0, 0,
                255, 0, 0, 0,
                255, 255, 255, 0
            ])
            guard decoded == expected else {
                return fail("Tight compressed copy", "zlib copy filter did not decode correctly")
            }
            return ok("Tight zlib copy filter decodes")
        } catch {
            return fail("Tight compressed copy", "\(error)")
        }
    }

    private static func testTightNoZlibDecoder() -> Result {
        do {
            let rgb = Data([
                255, 0, 0,
                0, 255, 0,
                0, 0, 255,
                255, 255, 255
            ])
            var payload = Data([0xA0]) // standard Tight no-zlib basic, implicit copy
            payload.append(tightCompactLength(rgb.count))
            payload.append(rgb)
            let decoded = try RFBEncodingDecoder.decodeTightPayload(
                width: 4,
                height: 1,
                encoding: RFBEncoding.tight.rawValue,
                payload: payload,
                state: RFBEncodingDecoder.TightDecodeState()
            )
            let expected = Data([
                0, 0, 255, 0,
                0, 255, 0, 0,
                255, 0, 0, 0,
                255, 255, 255, 0
            ])
            guard decoded == expected else {
                return fail("Tight no-zlib", "no-zlib copy filter did not decode correctly")
            }
            return ok("Tight no-zlib copy filter decodes")
        } catch {
            return fail("Tight no-zlib", "\(error)")
        }
    }

    private static func testTightPNGDecoder() -> Result {
        do {
            let expected = Data([
                0, 0, 255, 0,
                0, 255, 0, 0
            ])
            let png = try pngFixture(width: 1, height: 2, xrgb: expected)
            var payload = Data([0xA0]) // PNG subencoding
            payload.append(tightCompactLength(png.count))
            payload.append(png)
            let decoded = try RFBEncodingDecoder.decodeTightPayload(
                width: 1,
                height: 2,
                encoding: RFBEncoding.tightPNG.rawValue,
                payload: payload,
                state: RFBEncodingDecoder.TightDecodeState()
            )
            guard decoded == expected else {
                return fail("TightPNG", "PNG payload did not decode to expected XRGB")
            }
            return ok("TightPNG payload decodes")
        } catch {
            return fail("TightPNG", "\(error)")
        }
    }

    private static func zlibCompress(_ data: Data) throws -> Data {
        let source = Array(data)
        var capacity = max(64, source.count * 2 + 64)
        let maxCapacity = max(1024, source.count * 16 + 1024)

        while capacity <= maxCapacity {
            var destination = [UInt8](repeating: 0, count: capacity)
            let encodedCount = source.withUnsafeBufferPointer { sourcePtr in
                destination.withUnsafeMutableBufferPointer { destinationPtr in
                    compression_encode_buffer(
                        destinationPtr.baseAddress!,
                        destinationPtr.count,
                        sourcePtr.baseAddress!,
                        sourcePtr.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }

            if encodedCount > 0 {
                return Data(destination.prefix(encodedCount))
            }
            capacity *= 2
        }

        throw RFBError.protocolError("Unable to create ZRLE test fixture")
    }

    private static func tightCompactLength(_ value: Int) -> Data {
        precondition(value >= 0 && value <= 0x3F_FFFF)
        if value <= 0x7F {
            return Data([UInt8(value)])
        }
        if value <= 0x3FFF {
            return Data([
                UInt8((value & 0x7F) | 0x80),
                UInt8((value >> 7) & 0x7F)
            ])
        }
        return Data([
            UInt8((value & 0x7F) | 0x80),
            UInt8(((value >> 7) & 0x7F) | 0x80),
            UInt8((value >> 14) & 0xFF)
        ])
    }

    private static func pngFixture(width: Int, height: Int, xrgb: Data) throws -> Data {
        guard xrgb.count == width * height * 4,
              let provider = CGDataProvider(data: xrgb as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw RFBError.protocolError("Unable to create PNG test image")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw RFBError.protocolError("Unable to create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RFBError.protocolError("Unable to finalize PNG fixture")
        }
        return output as Data
    }
}
