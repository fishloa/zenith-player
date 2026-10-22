import Foundation

enum M3UParser {

    /// The guide (XMLTV) URL from the `#EXTM3U` header: `url-tvg`, or the
    /// `x-tvg-url` alias; the first of a comma-separated list; resolved
    /// against the playlist's own URL.
    static func guideURL(in text: String, relativeTo playlist: URL) -> URL? {
        guard let header = text.split(whereSeparator: \.isNewline).first.map(String.init),
              header.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") else { return nil }
        let value = extractAttribute("url-tvg", from: header) ?? extractAttribute("x-tvg-url", from: header)
        guard let first = value?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
              !first.isEmpty else { return nil }
        return URL(string: first, relativeTo: playlist)?.absoluteURL
    }

    static func parse(_ text: String) -> [Channel] {
        var channels: [Channel] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXTINF:") {
                // Look for the stream URL on the next non-empty line
                i += 1
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }

                if i < lines.count {
                    let urlLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if let streamURL = URL(string: urlLine), urlLine.hasPrefix("http") {
                        let channel = parseExtInf(line, streamURL: streamURL)
                        channels.append(channel)
                    }
                }
            }

            i += 1
        }

        return channels
    }

    private static func parseExtInf(_ line: String, streamURL: URL) -> Channel {
        let tvgId = extractAttribute("tvg-id", from: line)
        let tvgName = extractAttribute("tvg-name", from: line)
        let tvgLogo = extractAttribute("tvg-logo", from: line)
        let groupTitle = extractAttribute("group-title", from: line)
        let tvgChno = extractAttribute("tvg-chno", from: line).flatMap { Int($0) } ?? 0

        // Display name is after the last comma in the #EXTINF line
        let displayName = line.split(separator: ",", maxSplits: .max, omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""

        let name = tvgName ?? displayName
        let id = tvgId ?? name.lowercased().replacingOccurrences(of: " ", with: "-")
        let logoURL = tvgLogo.flatMap { URL(string: $0) }.map(rasterLogo)
        let country = extractAttribute("tvg-country", from: line)

        return Channel(id: id, name: name, logoURL: logoURL, streamURL: streamURL, group: groupTitle,
                       channelNumber: tvgChno, country: country)
    }

    /// zenith's logo API renders PNGs server-side (zenith#1251): no SVG
    /// parsing in the app, and dark logos come on a light plate (bg=dark)
    /// so they show on the dark tiles. Other logo URLs are left alone.
    static func rasterLogo(_ url: URL) -> URL {
        guard url.path.contains("/api/logos/"), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var q = (c.queryItems ?? []).filter { !["format", "size", "bg"].contains($0.name) }
        q += [URLQueryItem(name: "format", value: "png"), URLQueryItem(name: "size", value: "256"), URLQueryItem(name: "bg", value: "dark")]
        c.queryItems = q
        return c.url ?? url
    }

    private static func extractAttribute(_ key: String, from line: String) -> String? {
        // Match: key="value"
        let pattern = "\(key)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        let value = String(line[range])
        return value.isEmpty ? nil : value
    }
}
