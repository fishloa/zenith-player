import Foundation

struct DeviceAuthorization: Decodable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let verificationURIComplete: URL?
    let expiresIn: Int
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri",
             verificationURIComplete = "verification_uri_complete", expiresIn = "expires_in", interval
    }
}

enum DeviceGrantError: Error, Equatable { case denied, expired, invalidResponse }

final class DeviceGrant {
    static let clientID = "zenith-player"

    private let session: URLSession
    private let sleep: (Duration) async throws -> Void

    init(session: URLSession = URLSession(configuration: .ephemeral),
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.session = session
        self.sleep = sleep
    }

    private struct ResourceMetadata: Decodable { let resource: URL; let authorization_servers: [URL] }
    private struct ServerMetadata: Decodable { let issuer: URL; let device_authorization_endpoint: URL; let token_endpoint: URL }
    private struct TokenReply: Decodable { let access_token: String?; let error: String? }

    static func sameIssuer(_ a: URL, _ b: URL) -> Bool {
        func normalized(_ url: URL) -> String {
            var s = url.absoluteString
            if s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return normalized(a) == normalized(b)
    }

    static func wellKnown(issuer: URL) -> URL {
        var c = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        c.path = "/.well-known/oauth-authorization-server" + path
        return c.url!
    }

    func endpoints(resourceMetadata: URL, for origin: Origin) async throws -> (device: URL, token: URL) {
        let resource: ResourceMetadata = try await get(resourceMetadata)
        guard Origin(resource.resource) == origin else { throw DeviceGrantError.invalidResponse }
        guard let issuer = resource.authorization_servers.first else { throw DeviceGrantError.invalidResponse }
        let server: ServerMetadata = try await get(Self.wellKnown(issuer: issuer))
        guard Self.sameIssuer(server.issuer, issuer) else { throw DeviceGrantError.invalidResponse }
        return (server.device_authorization_endpoint, server.token_endpoint)
    }

    func start(_ device: URL) async throws -> DeviceAuthorization {
        let (data, response) = try await post(device, ["client_id": Self.clientID])
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let auth = try? JSONDecoder().decode(DeviceAuthorization.self, from: data) else { throw DeviceGrantError.invalidResponse }
        return auth
    }

    func poll(_ token: URL, _ authorization: DeviceAuthorization) async throws -> String {
        var interval = authorization.interval ?? 5
        var waited = 0
        while waited < authorization.expiresIn {
            try await sleep(.seconds(interval))
            waited += interval
            do {
                let (data, response) = try await post(token, ["grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                                               "device_code": authorization.deviceCode, "client_id": Self.clientID])
                if let http = response as? HTTPURLResponse, (500...599).contains(http.statusCode) {
                    continue
                }
                guard let reply = try? JSONDecoder().decode(TokenReply.self, from: data) else { throw DeviceGrantError.invalidResponse }
                if let t = reply.access_token { return t }
                switch reply.error {
                case "authorization_pending": continue
                case "slow_down": interval += 5
                case "access_denied": throw DeviceGrantError.denied
                case "expired_token": throw DeviceGrantError.expired
                default: throw DeviceGrantError.invalidResponse
                }
            } catch let urlError as URLError {
                if urlError.code == .cancelled { throw urlError }
                continue
            } catch is CancellationError {
                throw CancellationError()
            }
        }
        throw DeviceGrantError.expired
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let v = try? JSONDecoder().decode(T.self, from: data) else {
            throw DeviceGrantError.invalidResponse
        }
        return v
    }

    private func post(_ url: URL, _ form: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        return try await session.data(for: request)
    }
}
