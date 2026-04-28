//
//  TailnetDeviceProvider.swift
//  Screen Q
//
//  Reads the user's Tailscale device list. This is discovery only: Tailscale
//  provides the private route, while Screen Q/RDP/Mac Screen Sharing/VNC still
//  own authentication and session security.
//

import Foundation

nonisolated enum TailnetDeviceProvider {
    private static let devicesURL = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices")!
    private static let oauthTokenURL = URL(string: "https://api.tailscale.com/api/v2/oauth/token")!
    static let oauthDeviceReadScope = "devices:core:read"

    static func fetchDevices(credentials: TailscaleCredentialStore.Credentials) async throws -> [TailnetDevice] {
        switch credentials {
        case .apiToken(let token):
            return try await fetchDevices(apiToken: token)
        case .oauthClient(let id, let secret):
            let accessToken = try await mintOAuthAccessToken(clientID: id, clientSecret: secret)
            return try await fetchDevices(apiToken: accessToken)
        }
    }

    static func fetchDevices(apiToken: String) async throws -> [TailnetDevice] {
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw TailnetDeviceProviderError.missingToken
        }

        var request = URLRequest(url: devicesURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ScreenQ/1 TailnetDiscovery", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw TailnetDeviceProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TailnetDeviceProviderError.httpStatus(http.statusCode, apiMessage(from: data))
        }

        let decoded = try JSONDecoder.tailnet.decode(TailscaleDevicesResponse.self, from: data)
        return decoded.devices.map(\.tailnetDevice).sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func oauthTokenRequestBody(
        clientID: String,
        clientSecret: String,
        scope: String = oauthDeviceReadScope
    ) -> Data? {
        formURLEncodedBody([
            ("grant_type", "client_credentials"),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("scope", scope)
        ])
    }

    private static func mintOAuthAccessToken(clientID: String, clientSecret: String) async throws -> String {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedSecret.isEmpty else {
            throw TailnetDeviceProviderError.missingOAuthClientCredentials
        }
        guard let body = oauthTokenRequestBody(clientID: trimmedID, clientSecret: trimmedSecret) else {
            throw TailnetDeviceProviderError.invalidResponse
        }

        var request = URLRequest(url: oauthTokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ScreenQ/1 TailnetDiscovery", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw TailnetDeviceProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TailnetDeviceProviderError.oauthStatus(http.statusCode, oauthMessage(from: data))
        }

        let decoded = try JSONDecoder().decode(TailscaleOAuthTokenResponse.self, from: data)
        let accessToken = decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw TailnetDeviceProviderError.invalidResponse
        }
        return accessToken
    }

    private static func apiMessage(from data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(TailscaleErrorResponse.self, from: data) else {
            return String(data: data, encoding: .utf8)
        }
        return payload.message
    }

    private static func oauthMessage(from data: Data) -> String? {
        if let payload = try? JSONDecoder().decode(TailscaleOAuthErrorResponse.self, from: data) {
            return payload.errorDescription ?? payload.error
        }
        return apiMessage(from: data)
    }

    private static func formURLEncodedBody(_ pairs: [(String, String)]) -> Data? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = pairs.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return encoded.data(using: .utf8)
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: TailnetDeviceProviderError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}

nonisolated enum TailnetDeviceProviderError: LocalizedError, Equatable {
    case missingToken
    case missingOAuthClientCredentials
    case invalidResponse
    case httpStatus(Int, String?)
    case oauthStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Enter a Tailscale API access token to load tailnet devices."
        case .missingOAuthClientCredentials:
            return "Enter a Tailscale OAuth client ID and client secret to load tailnet devices."
        case .invalidResponse:
            return "Tailscale returned an invalid response."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "Tailscale API error \(status): \(message)"
            }
            if status == 401 || status == 403 {
                return "Tailscale rejected the API token. Create a token with device read access and try again."
            }
            return "Tailscale API error \(status)."
        case .oauthStatus(let status, let message):
            if let message, !message.isEmpty {
                return "Tailscale OAuth error \(status): \(message)"
            }
            if status == 401 || status == 403 {
                return "Tailscale rejected the OAuth client. Check that it has devices:core read access and try again."
            }
            return "Tailscale OAuth error \(status)."
        }
    }
}

private nonisolated struct TailscaleOAuthTokenResponse: Decodable {
    var accessToken: String
    var tokenType: String?
    var expiresIn: Int?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

private nonisolated struct TailscaleDevicesResponse: Decodable {
    var devices: [TailscaleAPIDevice]
}

private nonisolated struct TailscaleAPIDevice: Decodable {
    var id: String?
    var nodeId: String?
    var name: String?
    var hostname: String?
    var os: String?
    var addresses: [String]?
    var online: Bool?
    var lastSeen: Date?
    var tags: [String]?
    var isExternal: Bool?

    var tailnetDevice: TailnetDevice {
        let normalizedHostname = hostname?.nilIfBlank
        let normalizedName = name?.nilIfBlank
        let displayName = normalizedHostname ?? normalizedName ?? primaryAddressFallback ?? "Tailnet Device"
        return TailnetDevice(
            id: id?.nilIfBlank ?? nodeId?.nilIfBlank ?? displayName,
            displayName: displayName,
            hostname: normalizedHostname ?? normalizedName,
            os: os?.nilIfBlank,
            addresses: addresses ?? [],
            isOnline: online,
            lastSeen: lastSeen,
            tags: tags ?? [],
            isExternal: isExternal ?? false
        )
    }

    private var primaryAddressFallback: String? {
        addresses?.first(where: { $0.hasPrefix("100.") }) ?? addresses?.first
    }
}

private nonisolated struct TailscaleErrorResponse: Decodable {
    var message: String?
}

private nonisolated struct TailscaleOAuthErrorResponse: Decodable {
    var error: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private nonisolated extension JSONDecoder {
    static var tailnet: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.tailnet.date(from: value) {
                return date
            }
            if let date = ISO8601DateFormatter.tailnetWithoutFractionalSeconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        return decoder
    }
}

private nonisolated extension ISO8601DateFormatter {
    static let tailnet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let tailnetWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private nonisolated extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
