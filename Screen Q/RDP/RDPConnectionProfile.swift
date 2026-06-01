//
//  RDPConnectionProfile.swift
//  Screen Q
//
//  Small, Swift-native representation of a Microsoft .rdp file. This lets the
//  app route Windows connections honestly before the native RDP engine is
//  linked.
//

import Foundation

nonisolated struct RDPConnectionProfile: Codable, Hashable, Sendable {
    var displayName: String
    var host: String
    var port: UInt16
    var username: String?
    var domain: String?
    var gatewayHost: String?
    var gatewayUsername: String?
    var desktopWidth: Int?
    var desktopHeight: Int?
    var dynamicResolution: Bool
    var administrativeSession: Bool
    var connectToConsole: Bool
    var redirectClipboard: Bool
    var redirectAudio: Bool
    var allowFontSmoothing: Bool
    var rawSettings: [String: String]

    static var defaultRedirectClipboard: Bool {
        #if os(iOS)
        return false
        #else
        return true
        #endif
    }

    init(
        displayName: String,
        host: String,
        port: UInt16 = RemoteConnectionProtocol.rdp.defaultPort,
        username: String? = nil,
        domain: String? = nil,
        gatewayHost: String? = nil,
        gatewayUsername: String? = nil,
        desktopWidth: Int? = nil,
        desktopHeight: Int? = nil,
        dynamicResolution: Bool = true,
        administrativeSession: Bool = false,
        connectToConsole: Bool = false,
        redirectClipboard: Bool = RDPConnectionProfile.defaultRedirectClipboard,
        redirectAudio: Bool = false,
        allowFontSmoothing: Bool = true,
        rawSettings: [String: String] = [:]
    ) {
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.gatewayHost = gatewayHost
        self.gatewayUsername = gatewayUsername
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.dynamicResolution = dynamicResolution
        self.administrativeSession = administrativeSession
        self.connectToConsole = connectToConsole
        self.redirectClipboard = redirectClipboard
        self.redirectAudio = redirectAudio
        self.allowFontSmoothing = allowFontSmoothing
        self.rawSettings = rawSettings
    }

    init(rdpFileText text: String, fallbackDisplayName: String = "RDP Connection") throws {
        let settings = Self.parseSettings(text)
        guard let address = settings["full address"], !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RDPProfileError.missingFullAddress
        }

        let endpoint = Self.parseEndpoint(address)
        let parsedUsername = settings["username"].flatMap(Self.nilIfEmpty)
        let splitUsername = Self.splitWindowsUsername(parsedUsername)
        let gateway = Self.nilIfEmpty(settings["gatewayhostname"])
        let name = fallbackDisplayName.isEmpty ? endpoint.host : fallbackDisplayName

        self.init(
            displayName: name,
            host: endpoint.host,
            port: endpoint.port,
            username: splitUsername.username,
            domain: splitUsername.domain,
            gatewayHost: gateway,
            gatewayUsername: settings["gatewayusername"].flatMap(Self.nilIfEmpty),
            desktopWidth: Self.intValue(settings["desktopwidth"]).flatMap { $0 > 0 ? $0 : nil },
            desktopHeight: Self.intValue(settings["desktopheight"]).flatMap { $0 > 0 ? $0 : nil },
            dynamicResolution: Self.boolValue(settings["dynamic resolution"]) ?? true,
            administrativeSession: Self.boolValue(settings["administrative session"]) ?? false,
            connectToConsole: Self.boolValue(settings["connect to console"]) ?? false,
            redirectClipboard: Self.boolValue(settings["redirectclipboard"]) ?? Self.defaultRedirectClipboard,
            redirectAudio: Self.intValue(settings["audiomode"]) == 0,
            allowFontSmoothing: Self.boolValue(settings["allow font smoothing"]) ?? true,
            rawSettings: settings
        )
    }

    var address: String {
        "\(host):\(port)"
    }

    var networkScope: NetworkTrustScope {
        NetworkTrustScope.classify(host: host)
    }

    var normalizedUsername: String? {
        guard let username, !username.isEmpty else { return nil }
        if let domain, !domain.isEmpty {
            return "\(domain)\\\(username)"
        }
        return username
    }

    static func parseSettings(_ text: String) -> [String: String] {
        var settings: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            settings[key] = value
        }
        return settings
    }

    private static func parseEndpoint(_ raw: String) -> (host: String, port: UInt16) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = UInt16(parts[1]) {
            return (String(parts[0]), port)
        }
        return (trimmed, RemoteConnectionProtocol.rdp.defaultPort)
    }

    private static func splitWindowsUsername(_ username: String?) -> (domain: String?, username: String?) {
        guard let username, !username.isEmpty else { return (nil, nil) }
        if let slash = username.firstIndex(of: "\\") {
            let domain = String(username[..<slash])
            let name = String(username[username.index(after: slash)...])
            return (nilIfEmpty(domain), nilIfEmpty(name))
        }
        return (nil, username)
    }

    private static func boolValue(_ raw: String?) -> Bool? {
        guard let value = intValue(raw) else { return nil }
        return value != 0
    }

    private static func intValue(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func nilIfEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum RDPProfileError: LocalizedError, Sendable {
    case missingFullAddress

    var errorDescription: String? {
        switch self {
        case .missingFullAddress:
            return "The .rdp file does not contain a full address."
        }
    }
}
