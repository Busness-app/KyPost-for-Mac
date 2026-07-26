//
//  HTTPClient.swift
//  KyPost
//
//  URLSession wrapper (spec Phase 2, OkHttp equivalent). Centralizes the
//  pairing-auth headers and HTTP status → error mapping so every client
//  shares one failure model (Ponytail principle #4).
//

import Foundation

/// Shared failure model for all backend calls.
enum NetworkError: Error, Equatable {
    case invalidURL
    /// 401/403 — pairing credentials rejected; prompt re-scan (spec §3).
    case unauthorized
    /// 409 — backend rejected the request state (e.g. expired MFA challenge).
    case conflict(body: String)
    /// 429 — rate limited (e.g. too many desktop pairing attempts); wait, then retry.
    case rateLimited
    /// 503 — backend config issue; persistent error, cannot retry (spec §3).
    case serviceUnavailable
    case server(statusCode: Int)
    case transport(description: String)
    case decoding(description: String)

    /// Maps a non-2xx HTTP status to its error. 2xx returns nil. `body` is
    /// retained only for 409, where the relay distinguishes a client-protected
    /// send refusal from an ordinary conflict by its payload.
    static func from(statusCode: Int, body: Data = Data()) -> NetworkError? {
        switch statusCode {
        case 200..<300: nil
        case 401, 403: .unauthorized
        case 409: .conflict(body: String(decoding: body, as: UTF8.self))
        case 429: .rateLimited
        case 503: .serviceUnavailable
        default: .server(statusCode: statusCode)
        }
    }
}

/// Per-device auth credentials, sent as X-Kypost-Device-Id/X-Kypost-Device-Secret
/// headers on every authenticated request. deviceSecret is minted server-side
/// once per successful registration and returned only in that response — see
/// DeviceRegistrationService.performPair.
struct RelayAuth: Equatable, Sendable {
    var deviceId: String
    var deviceSecret: String

    init(deviceId: String, deviceSecret: String) {
        self.deviceId = deviceId
        self.deviceSecret = deviceSecret
    }

    init(pairing: Pairing) {
        self.init(deviceId: pairing.lastDeviceId ?? "", deviceSecret: pairing.deviceSecret)
    }

    var headerFields: [String: String] {
        ["X-Kypost-Device-Id": deviceId, "X-Kypost-Device-Secret": deviceSecret]
    }
}

final class HTTPClient: Sendable {
    /// Injectable transport so clients are unit-testable without a network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        transport = { try await session.data(for: $0) }
    }

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    // MARK: - Requests

    func get<Response: Decodable>(
        _ type: Response.Type,
        url: URL,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: try url.appending(queryOrThrow: query))
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await decode(execute(request))
    }

    /// GET returning the raw response body (attachment downloads).
    func getData(
        url: URL,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: try url.appending(queryOrThrow: query))
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await execute(request)
    }

    func post<Response: Decodable>(
        _ type: Response.Type,
        url: URL,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        jsonBody: some Encodable
    ) async throws -> Response {
        var request = URLRequest(url: try url.appending(queryOrThrow: query))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            request.httpBody = try encoder.encode(jsonBody)
        } catch {
            throw NetworkError.decoding(description: "Encoding request body: \(error)")
        }
        return try await decode(execute(request))
    }

    // MARK: - Private

    private func execute(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.transport(description: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.transport(description: "Non-HTTP response")
        }
        if let error = NetworkError.from(statusCode: http.statusCode, body: data) {
            throw error
        }
        return data
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw NetworkError.decoding(description: "\(error)")
        }
    }
}

extension URL {
    /// Appends query items, preserving any existing ones.
    func appending(queryOrThrow items: [URLQueryItem]) throws -> URL {
        guard !items.isEmpty else { return self }
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else { throw NetworkError.invalidURL }
        return url
    }
}
