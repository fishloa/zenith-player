import Foundation

struct Channel: Identifiable {
    let id: String
    let name: String
    let logoURL: URL?
    let streamURL: URL
    let group: String?
    let channelNumber: Int
    /// ISO 3166 country code from the playlist (tvg-country), if given.
    var country: String? = nil
}

/// Flag for a playlist group: from the channels' tvg-country code when the
/// playlist carries one, else from the group-title (a country name).
enum GroupFlag {
    /// Regional-indicator flag for an ISO 3166 alpha-2 code ("AT" -> 🇦🇹).
    static func emoji(countryCode: String) -> String? {
        let code = countryCode.uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
    }

    /// Flag for a group of channels: their country code first, then the name.
    static func emoji(for group: String, channels: [Channel]) -> String? {
        if let cc = channels.lazy.compactMap(\.country).first, let f = emoji(countryCode: cc) { return f }
        return emoji(for: group)
    }

    static func emoji(for group: String) -> String? {
        switch group.lowercased() {
        case "france": return "\u{1F1EB}\u{1F1F7}"
        case "italy", "italia": return "\u{1F1EE}\u{1F1F9}"
        case "austria", "\u{00F6}sterreich", "osterreich": return "\u{1F1E6}\u{1F1F9}"
        case "germany", "deutschland": return "\u{1F1E9}\u{1F1EA}"
        case "switzerland", "schweiz", "suisse", "svizzera": return "\u{1F1E8}\u{1F1ED}"
        case "spain", "espa\u{00F1}a": return "\u{1F1EA}\u{1F1F8}"
        case "uk", "united kingdom": return "\u{1F1EC}\u{1F1E7}"
        default: return nil
        }
    }
}
