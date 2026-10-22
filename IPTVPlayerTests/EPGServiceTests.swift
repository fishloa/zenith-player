import XCTest
@testable import IPTVPlayer

final class EPGServiceTests: XCTestCase {

    func testDecodeEPGEvent() throws {
        let json = """
        [{
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "service_slug": "tf1",
          "start_time": "2026-01-01T19:00:00Z",
          "duration_secs": 3600,
          "title": "Le Journal 19h",
          "description": "Journal présenté par Gilles Bouleau.",
          "language": "fre"
        }]
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode([EPGEvent].self, from: json)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "Le Journal 19h")
        XCTAssertEqual(events[0].durationSecs, 3600)
        XCTAssertEqual(events[0].serviceSlug, "tf1")
        XCTAssertEqual(events[0].stopTime, events[0].startTime.addingTimeInterval(3600))
    }

    /// The guide comes from the playlist's url-tvg as XMLTV: channel = tvg-id,
    /// start/stop "YYYYMMDDhhmmss ±zzzz", optional desc, lang on the title.
    func testParsesXMLTV() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE tv SYSTEM "xmltv.dtd">
        <tv generator-info-name="zenith">
          <channel id="tf-1"><display-name>TF1</display-name></channel>
          <programme start="20261018190000 +0200" stop="20261018194500 +0200" channel="tf-1">
            <title lang="fr">Le Journal &amp; la météo</title>
            <desc lang="fr">Présenté par Gilles Bouleau.</desc>
          </programme>
          <programme start="20261018174500 +0000" stop="20261018184500 +0000" channel="orf1">
            <title>ZIB</title>
          </programme>
          <programme start="20261018200000 +0000" channel="orf1"><title>No stop</title></programme>
        </tv>
        """.data(using: .utf8)!
        let events = try XMLTVParser.events(from: xml)
        XCTAssertEqual(events.count, 2, "a programme without stop has no duration and is skipped")
        let tf1 = try XCTUnwrap(events.first { $0.serviceSlug == "tf-1" })
        XCTAssertEqual(tf1.title, "Le Journal & la météo")
        XCTAssertEqual(tf1.description, "Présenté par Gilles Bouleau.")
        XCTAssertEqual(tf1.language, "fr")
        XCTAssertEqual(tf1.startTime, ISO8601DateFormatter().date(from: "2026-10-18T17:00:00Z"))
        XCTAssertEqual(tf1.durationSecs, 45 * 60)
        let zib = try XCTUnwrap(events.first { $0.serviceSlug == "orf1" })
        XCTAssertNil(zib.description)
        XCTAssertEqual(zib.durationSecs, 3600)
    }

    func testXMLTVDates() {
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(XMLTVParser.date("20240229235959 -0500"), iso.date(from: "2024-03-01T04:59:59Z"))
        XCTAssertEqual(XMLTVParser.date("20260101000000 +0100"), iso.date(from: "2025-12-31T23:00:00Z"))
        XCTAssertEqual(XMLTVParser.date("19700101000000"), Date(timeIntervalSince1970: 0), "no zone = UTC")
        XCTAssertNil(XMLTVParser.date("2026-10-18"))
        XCTAssertNil(XMLTVParser.date(nil))
    }

    func testXMLTVRejectsNonXML() {
        XCTAssertThrowsError(try XMLTVParser.events(from: Data("[{\"id\":1}]".utf8)))
    }

    func testCurrentEvent() {
        let slug = "tf1"
        let now = Date.now
        let current = EPGEvent(id: UUID(), serviceSlug: slug,
                               startTime: now.addingTimeInterval(-600), durationSecs: 3600,
                               title: "Current", description: nil, language: nil)
        let future = EPGEvent(id: UUID(), serviceSlug: slug,
                              startTime: now.addingTimeInterval(1800), durationSecs: 3600,
                              title: "Future", description: nil, language: nil)
        let service = EPGService(preloaded: [current, future])
        XCTAssertEqual(service.currentEvent(for: slug)?.title, "Current")
    }

    func testCurrentEventNilWhenNone() {
        let service = EPGService()
        XCTAssertNil(service.currentEvent(for: "unknown-channel"))
    }

    func testUpcomingExcludesPast() {
        let slug = "france-2"
        let now = Date.now
        let past = EPGEvent(id: UUID(), serviceSlug: slug,
                            startTime: now.addingTimeInterval(-7200), durationSecs: 1800,
                            title: "Past", description: nil, language: nil)
        let current = EPGEvent(id: UUID(), serviceSlug: slug,
                               startTime: now.addingTimeInterval(-600), durationSecs: 3600,
                               title: "Current", description: nil, language: nil)
        let future = EPGEvent(id: UUID(), serviceSlug: slug,
                              startTime: now.addingTimeInterval(1800), durationSecs: 3600,
                              title: "Future", description: nil, language: nil)
        let service = EPGService(preloaded: [past, current, future])
        let upcoming = service.upcomingEvents(for: slug)
        XCTAssertEqual(upcoming.count, 2)
        XCTAssertTrue(upcoming.contains { $0.title == "Current" })
        XCTAssertTrue(upcoming.contains { $0.title == "Future" })
        XCTAssertFalse(upcoming.contains { $0.title == "Past" })
    }

    func testStopTimeComputed() {
        let start = Date(timeIntervalSince1970: 0)
        let event = EPGEvent(id: UUID(), serviceSlug: "m6",
                             startTime: start, durationSecs: 3600,
                             title: nil, description: nil, language: nil)
        XCTAssertEqual(event.stopTime, Date(timeIntervalSince1970: 3600))
    }

    func testCurrentEventNilSlug() {
        let service = EPGService()
        XCTAssertNil(service.currentEvent(for: nil as String?))
    }

    func testUpcomingEventsNilSlug() {
        let service = EPGService()
        XCTAssertTrue(service.upcomingEvents(for: nil as String?).isEmpty)
    }
}
