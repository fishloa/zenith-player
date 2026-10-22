import Foundation
import Observation

/// How often the EPG automatically refreshes in the background (seconds).
private let kRefreshInterval: TimeInterval = 30 * 60  // 30 minutes

/// If data is older than this when the overlay opens, fetch immediately.
private let kStaleThreshold: TimeInterval = 60 * 60   // 60 minutes

@Observable
final class EPGService {
    private(set) var eventsBySlug: [String: [EPGEvent]] = [:]
    private(set) var isLoading = false
    private(set) var error: String?

    /// When the last successful fetch completed.
    private(set) var lastFetchDate: Date?

    /// The URL currently being auto-refreshed.
    private var refreshURL: URL?
    private var refreshTask: Task<Void, Never>?

    init() {}

    #if DEBUG
    init(preloaded events: [EPGEvent]) {
        var grouped: [String: [EPGEvent]] = [:]
        for event in events { grouped[event.serviceSlug, default: []].append(event) }
        eventsBySlug = grouped
        lastFetchDate = .now
    }
    #endif

    /// Start auto-refreshing every 30 minutes from the given URL.
    /// Call once when the app has a valid EPG URL (e.g. at launch or after settings change).
    /// Safe to call multiple times — restarts the timer if the URL changed.
    func startAutoRefresh(from url: URL) {
        guard refreshURL != url else { return }
        stopAutoRefresh()
        refreshURL = url
        print("[EPG] auto-refresh started: \(url)")

        refreshTask = Task { [weak self] in
            // Initial fetch
            await self?.load(from: url)

            // Periodic refresh
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(kRefreshInterval))
                } catch { return }
                guard !Task.isCancelled else { return }
                print("[EPG] auto-refresh tick")
                await self?.load(from: url)
            }
        }
    }

    /// Stop background auto-refresh.
    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshURL = nil
    }

    /// Fetch if data is stale (>60 min old) or never fetched.
    /// Call this when the EPG overlay opens — returns immediately if data is fresh.
    func loadIfStale(from url: URL) async {
        if let last = lastFetchDate, Date.now.timeIntervalSince(last) < kStaleThreshold {
            return  // data is fresh enough
        }
        await load(from: url)
    }

    /// Fetches the XMLTV guide (the playlist's url-tvg) fresh and rebuilds the index.
    func load(from url: URL) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let events = try XMLTVParser.events(from: data)
            var grouped: [String: [EPGEvent]] = [:]
            for event in events { grouped[event.serviceSlug, default: []].append(event) }
            eventsBySlug = grouped
            lastFetchDate = .now
            print("[EPG] loaded \(events.count) events for \(grouped.count) channels")
        } catch {
            // eventsBySlug intentionally left unchanged on failure —
            // preserves the last successful fetch until the next load succeeds.
            self.error = error.localizedDescription
            print("[EPG] load failed: \(error.localizedDescription)")
        }
    }

    /// The event currently airing on the given channel slug, if any.
    func currentEvent(for slug: String) -> EPGEvent? {
        let now = Date.now
        return eventsBySlug[slug]?.first { $0.startTime <= now && $0.stopTime > now }
    }

    /// The event currently airing on the given channel slug (optional variant).
    func currentEvent(for slug: String?) -> EPGEvent? {
        guard let slug else { return nil }
        return currentEvent(for: slug)
    }

    /// Events whose stop time is in the future and start time is within 6 hours.
    func upcomingEvents(for slug: String) -> [EPGEvent] {
        let now = Date.now
        let cutoff = now.addingTimeInterval(6 * 3600)
        return eventsBySlug[slug]?
            .filter { $0.stopTime > now && $0.startTime < cutoff }
            .sorted { $0.startTime < $1.startTime }
            ?? []
    }

    /// Events upcoming for the given channel slug (optional variant).
    func upcomingEvents(for slug: String?) -> [EPGEvent] {
        guard let slug else { return [] }
        return upcomingEvents(for: slug)
    }
}

/// Streaming XMLTV reader: `<programme start stop channel>` with `<title>` and
/// `<desc>`; `channel` is the playlist's tvg-id. Programmes without a stop
/// time are skipped (no duration to show).
final class XMLTVParser: NSObject, XMLParserDelegate {
    struct Invalid: Error {}

    static func events(from data: Data) throws -> [EPGEvent] {
        let delegate = XMLTVParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawTV else { throw parser.parserError ?? Invalid() }
        return delegate.events
    }

    private var events: [EPGEvent] = []
    private var sawTV = false
    private var current: (channel: String, start: Date, stop: Date?)?
    private var title: String?, desc: String?, language: String?
    private var text = ""
    private var inText = false

    /// "YYYYMMDDhhmmss ±hhmm" (zone optional, UTC if absent), parsed directly:
    /// a DateFormatter per programme made a full guide take seconds on the TV.
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let b = Array(s.utf8)
        func num(_ i: Int, _ n: Int) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for k in i..<(i + n) { let c = Int(b[k]) - 48; guard (0...9).contains(c) else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2), let h = num(8, 2),
              let mi = num(10, 2), let se = num(12, 2) else { return nil }
        var offset = 0
        var i = 14
        while i < b.count, b[i] == 32 { i += 1 }
        if i < b.count, b[i] == 43 || b[i] == 45, let oh = num(i + 1, 2), let om = num(i + 3, 2) {
            offset = (oh * 3600 + om * 60) * (b[i] == 45 ? -1 : 1)
        }
        // Days from civil (proleptic Gregorian), UTC.
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let secs = days * 86400 + h * 3600 + mi * 60 + se - offset
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "tv": sawTV = true
        case "programme":
            guard let ch = attributes["channel"], let start = Self.date(attributes["start"]) else { current = nil; return }
            current = (ch, start, Self.date(attributes["stop"]))
            title = nil; desc = nil; language = nil
        case "title", "desc":
            guard current != nil else { return }
            inText = true; text = ""
            if name == "title", language == nil { language = attributes["lang"] }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "title" where inText: if title == nil { title = text.trimmingCharacters(in: .whitespacesAndNewlines) }; inText = false
        case "desc" where inText: if desc == nil { desc = text.trimmingCharacters(in: .whitespacesAndNewlines) }; inText = false
        case "programme":
            if let p = current, let stop = p.stop, stop > p.start {
                events.append(EPGEvent(id: UUID(), serviceSlug: p.channel, startTime: p.start,
                                       durationSecs: Int(stop.timeIntervalSince(p.start)),
                                       title: title, description: desc, language: language))
            }
            current = nil
        default: break
        }
    }
}
