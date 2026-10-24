import Foundation
import ZenithMedia

enum FetchError: Error, Equatable {
    case unauthorized(AuthChallenge?, Origin, rejected: Bool)
    case forbidden
    case http(status: Int)
}

final class AuthorizedFetcher {
    static let shared = AuthorizedFetcher(credentials: CredentialStore(secrets: KeychainSecretStore()))

    static func streamCredential(for url: URL) -> StreamCredential? {
        guard let origin = Origin(url) else { return nil }
        guard let cred = shared.credentials.credential(for: origin) else { return nil }
        switch cred {
        case .password(let user, let password): return .password(user: user, password: password)
        case .bearer(let token): return .bearer(token)
        }
    }

    private let credentials: CredentialStore
    private let session: URLSession

    init(credentials: CredentialStore, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.credentials = credentials
        self.session = session
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        guard let origin = Origin(url) else { throw URLError(.unsupportedURL) }

        var request = URLRequest(url: url)
        if case .bearer(let token) = credentials.credential(for: origin) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let delegate = AuthDelegate(origin: origin, credentials: credentials)
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let final = http.url.flatMap(Origin.init) ?? origin
            switch http.statusCode {
            case 200..<300:
                return (data, http)
            case 401:
                let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate").flatMap(AuthChallenge.parse) ?? delegate.challenge
                throw FetchError.unauthorized(challenge, final, rejected: credentials.credential(for: final) != nil)
            case 403:
                throw FetchError.forbidden
            default:
                throw FetchError.http(status: http.statusCode)
            }
        } catch let error as FetchError {
            throw error
        } catch {
            if let challenge = delegate.challenge,
               let urlError = error as? URLError,
               urlError.code == .cancelled {
                throw FetchError.unauthorized(challenge, origin, rejected: true)
            }
            throw error
        }
    }
}

final class AuthDelegate: NSObject, URLSessionTaskDelegate {
    let origin: Origin
    let credentials: CredentialStore
    private(set) var challenge: AuthChallenge?

    init(origin: Origin, credentials: CredentialStore) {
        self.origin = origin
        self.credentials = credentials
    }

    private func origin(for space: URLProtectionSpace) -> Origin? {
        guard let scheme = space.protocol?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let port = space.port > 0 ? space.port : (scheme == "https" ? 443 : 80)
        guard let url = URL(string: "\(scheme)://\(space.host):\(port)/") else { return nil }
        return Origin(url)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let authMethod = space.authenticationMethod
        let challengeOrigin = origin(for: space)
        let credential = challengeOrigin.flatMap { credentials.credential(for: $0) }

        if (authMethod == NSURLAuthenticationMethodHTTPBasic || authMethod == NSURLAuthenticationMethodHTTPDigest),
           challenge.previousFailureCount == 0,
           case .password(let user, let password)? = credential {
            return (.useCredential, URLCredential(user: user, password: password, persistence: .none))
        }
        if authMethod == NSURLAuthenticationMethodHTTPBasic || authMethod == NSURLAuthenticationMethodHTTPDigest {
            let scheme = authMethod == NSURLAuthenticationMethodHTTPDigest ? "digest" : "basic"
            self.challenge = AuthChallenge(scheme: scheme, realm: space.realm, resourceMetadata: nil)
            if challenge.previousFailureCount > 0 {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.rejectProtectionSpace, nil)
        }
        return (.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url else { return request }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Authorization")
        if let newOrigin = Origin(url), case .bearer(let token) = credentials.credential(for: newOrigin) {
            next.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return next
    }
}
