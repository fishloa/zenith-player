import Foundation

struct Origin: Hashable, Codable, CustomStringConvertible {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https",
              let h = url.host?.lowercased(), !h.isEmpty else { return nil }
        scheme = s
        host = h
        port = url.port ?? (s == "https" ? 443 : 80)
    }

    var description: String { "\(scheme)://\(host):\(port)" }
}

enum Credential: Codable, Equatable {
    case password(user: String, password: String)
    case bearer(String)

    static func split(_ text: String) -> (url: String, credential: Credential?) {
        guard var c = URLComponents(string: text), let user = c.user, !user.isEmpty else { return (text, nil) }
        let credential = Credential.password(user: user, password: c.password ?? "")
        c.user = nil
        c.password = nil
        return (c.string ?? text, credential)
    }
}

struct AuthChallenge: Equatable {
    let scheme: String
    let realm: String?
    let resourceMetadata: URL?

    static func parse(_ header: String) -> AuthChallenge? {
        guard let (scheme, params) = parameters(header) else { return nil }
        return AuthChallenge(scheme: scheme, realm: params["realm"],
                             resourceMetadata: params["resource_metadata"].flatMap(URL.init(string:)))
    }

    /// RFC 9110 §11.6.1. Only the first challenge of a list is read.
    static func parameters(_ header: String) -> (scheme: String, params: [String: String])? {
        let s = header.trimmingCharacters(in: .whitespaces)
        let space = s.firstIndex(of: " ") ?? s.endIndex
        let scheme = s[..<space].lowercased()
        guard !scheme.isEmpty else { return nil }
        var params: [String: String] = [:]
        var rest = s[space...]
        while let eq = rest.firstIndex(of: "=") {
            let name = rest[..<eq].trimmingCharacters(in: CharacterSet(charactersIn: ", ")).lowercased()
            if name.isEmpty || name.contains(" ") { break }
            rest = rest[rest.index(after: eq)...].drop(while: { $0 == " " })
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var escaped = false
                while let c = rest.first {
                    rest = rest.dropFirst()
                    if escaped { value.append(c); escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { break }
                    else { value.append(c) }
                }
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            params[name] = value
        }
        return (scheme, params)
    }
}
