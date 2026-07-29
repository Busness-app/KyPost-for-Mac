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
enum NetworkError: Error, Equatable, LocalizedError {
    case invalidURL
    /// 401/403 — pairing credentials rejected; prompt re-scan (spec §3).
    case unauthorized
    /// 409 — backend rejected the request state (e.g. expired MFA challenge).
    case conflict(body: String)
    /// 429 — rate limited (e.g. too many desktop pairing attempts); wait, then retry.
    case rateLimited
    /// The relay presented a different key than the one pinned at pairing
    /// (TOFU). Deliberately distinct from `.transport`: either a legitimate
    /// certificate rotation (clear the pairing and re-pair) or interception.
    case certificateMismatch
    /// 503 — backend config issue; persistent error, cannot retry (spec §3).
    case serviceUnavailable
    /// The response body exceeded the caller's cap. A hostile or broken relay
    /// must not be able to choose this app's memory footprint.
    case responseTooLarge
    case server(statusCode: Int)
    case transport(description: String)
    case decoding(description: String)

    /// Longest 409 body kept for `conflict`. The payload is a small JSON
    /// discriminator (RelayMailSource.conflictError); the rest is only ever
    /// interpolated into logs and toasts, so an unbounded body would be a free
    /// way to blow those up.
    static let maxConflictBodyBytes = 8 * 1024

    /// User-facing text for the errors that reach toasts/list banners via
    /// localizedDescription; the rest keep their default rendering.
    var errorDescription: String? {
        switch self {
        case .certificateMismatch:
            String(localized: "The server's security certificate changed and no longer matches this pairing. If you rotated your server's certificate, remove the pairing in Settings → Connection and re-pair; otherwise the connection may be intercepted.")
        case .responseTooLarge:
            String(localized: "The server sent more data than KyPost will accept for this request.")
        default:
            nil
        }
    }

    /// Maps a non-2xx HTTP status to its error. 2xx returns nil. `body` is
    /// retained only for 409, where the relay distinguishes a client-protected
    /// send refusal from an ordinary conflict by its payload.
    static func from(statusCode: Int, body: Data = Data()) -> NetworkError? {
        switch statusCode {
        case 200..<300: nil
        case 401, 403: .unauthorized
        case 409: .conflict(
            body: String(decoding: body.prefix(maxConflictBodyBytes), as: UTF8.self)
        )
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
    /// Transport for bodies of unknown size, capped at `limit` bytes.
    typealias StreamTransport = @Sendable (_ request: URLRequest, _ limit: Int) async throws
        -> (Data, URLResponse)

    /// Cap for attachment downloads — the only path that reads an
    /// attacker-sized body. Comfortably above any mail provider's attachment
    /// limit, far below what would jetsam an iPhone.
    static let maxAttachmentBytes = 64 * 1024 * 1024

    private let transport: Transport
    private let streamTransport: StreamTransport
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        transport = { try await session.data(for: $0) }
        streamTransport = Self.streamTransport(session: session)
    }

    init(transport: @escaping Transport) {
        self.transport = transport
        streamTransport = Self.cappingStreamTransport(wrapping: transport)
    }

    /// Both seams supplied. The pinned relay client needs this: it wraps every
    /// call to map a pin failure onto `certificateMismatch`, and building it
    /// from `init(transport:)` alone silently left attachment downloads on the
    /// buffering fallback — which is exactly the path the cap exists for.
    init(transport: @escaping Transport, streamTransport: @escaping StreamTransport) {
        self.transport = transport
        self.streamTransport = streamTransport
    }

    /// Streams a response and refuses one that exceeds `limit`.
    ///
    /// `session.data(for:)` buffers the whole body before returning, so a size
    /// check there arrives after the memory was already spent. AsyncBytes hands
    /// back the response headers first, which lets an over-sized body be
    /// refused before a byte of it is retained.
    static func streamTransport(session: URLSession) -> StreamTransport {
        { request, limit in
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse,
               http.expectedContentLength > Int64(limit) {
                throw NetworkError.responseTooLarge
            }
            var data = Data()
            if let http = response as? HTTPURLResponse, http.expectedContentLength > 0 {
                data.reserveCapacity(Int(min(http.expectedContentLength, Int64(limit))))
            }
            // A chunked response can lie about (or omit) its length, so the
            // running total is enforced too.
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw NetworkError.responseTooLarge }
            }
            return (data, response)
        }
    }

    /// Fallback for a buffering transport (tests): the cap still applies, it
    /// just cannot be enforced before the stub has produced its body.
    static func cappingStreamTransport(wrapping transport: @escaping Transport) -> StreamTransport {
        { request, limit in
            let (data, response) = try await transport(request)
            guard data.count <= limit else { throw NetworkError.responseTooLarge }
            return (data, response)
        }
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

    /// GET returning the raw response body (attachment downloads), capped so
    /// the relay cannot choose how much memory this app allocates.
    func getData(
        url: URL,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        maxBytes: Int = HTTPClient.maxAttachmentBytes
    ) async throws -> Data {
        var request = URLRequest(url: try url.appending(queryOrThrow: query))
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await execute(request, streamingUpTo: maxBytes)
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

    /// `streamingUpTo` routes through the capped streaming transport; nil uses
    /// the buffering one (JSON endpoints, whose bodies the relay's own handlers
    /// bound).
    private func execute(_ request: URLRequest, streamingUpTo limit: Int? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            if let limit {
                (data, response) = try await streamTransport(request, limit)
            } else {
                (data, response) = try await transport(request)
            }
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
