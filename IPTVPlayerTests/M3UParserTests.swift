import XCTest
@testable import IPTVPlayer

final class M3UParserTests: XCTestCase {

    func testParsesValidPlaylist() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="france2" tvg-name="France 2" tvg-logo="http://example.com/france2.png",France 2
        http://example.com/hls/france2/index.m3u8
        #EXTINF:-1 tvg-id="rai1" tvg-name="Rai 1" tvg-logo="http://example.com/rai1.png",Rai 1
        http://example.com/hls/rai1/index.m3u8
        """

        let channels = M3UParser.parse(m3u)

        XCTAssertEqual(channels.count, 2)

        XCTAssertEqual(channels[0].id, "france2")
        XCTAssertEqual(channels[0].name, "France 2")
        XCTAssertEqual(channels[0].logoURL, URL(string: "http://example.com/france2.png"))
        XCTAssertEqual(channels[0].streamURL, URL(string: "http://example.com/hls/france2/index.m3u8")!)

        XCTAssertEqual(channels[1].id, "rai1")
        XCTAssertEqual(channels[1].name, "Rai 1")
    }

    func testParsesEntryWithoutLogo() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="tf1" tvg-name="TF1",TF1
        http://example.com/hls/tf1/index.m3u8
        """

        let channels = M3UParser.parse(m3u)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].id, "tf1")
        XCTAssertEqual(channels[0].name, "TF1")
        XCTAssertNil(channels[0].logoURL)
    }

    func testSkipsMalformedEntries() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="france2" tvg-name="France 2",France 2
        http://example.com/hls/france2/index.m3u8
        this is garbage
        #EXTINF:-1 tvg-id="rai1" tvg-name="Rai 1",Rai 1
        not-a-url
        #EXTINF:-1 tvg-id="arte" tvg-name="Arte",Arte
        http://example.com/hls/arte/index.m3u8
        """

        let channels = M3UParser.parse(m3u)

        // Should get france2 and arte; rai1 skipped because "not-a-url" is not a valid URL
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].id, "france2")
        XCTAssertEqual(channels[1].id, "arte")
    }

    func testEmptyInput() {
        let channels = M3UParser.parse("")
        XCTAssertTrue(channels.isEmpty)
    }

    func testNoExtm3uHeader() {
        let m3u = """
        #EXTINF:-1 tvg-id="france2" tvg-name="France 2",France 2
        http://example.com/hls/france2/index.m3u8
        """

        let channels = M3UParser.parse(m3u)

        // Should still parse — the #EXTM3U header is optional
        XCTAssertEqual(channels.count, 1)
    }

    func testParsesGroupTitle() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="france2" tvg-name="France 2" group-title="France",France 2
        http://example.com/hls/france2/index.m3u8
        #EXTINF:-1 tvg-id="rai1" tvg-name="Rai 1" group-title="Italy",Rai 1
        http://example.com/hls/rai1/index.m3u8
        """

        let channels = M3UParser.parse(m3u)

        XCTAssertEqual(channels[0].group, "France")
        XCTAssertEqual(channels[1].group, "Italy")
    }

    func testGroupIsNilWhenMissing() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="tf1" tvg-name="TF1",TF1
        http://example.com/hls/tf1/index.m3u8
        """

        let channels = M3UParser.parse(m3u)

        XCTAssertNil(channels[0].group)
    }

    func testFallsBackToDisplayNameWhenAttributesMissing() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1,My Channel
        http://example.com/hls/ch1/index.m3u8
        """

        let channels = M3UParser.parse(m3u)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].name, "My Channel")
        XCTAssertEqual(channels[0].id, "my-channel")
        XCTAssertNil(channels[0].logoURL)
    }

    func testStreamURLPassedThroughUnmodified() {
        let rawURL = "https://tv.example.com/hls/8511337b-a192-4a89-8516-1b1e75d42acd/index.m3u8"
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="abc" tvg-name="ABC",ABC
        \(rawURL)
        """

        let channels = M3UParser.parse(m3u)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].streamURL, URL(string: rawURL)!)
    }

    /// zenith#1251: logo API URLs are fetched as server-rendered PNGs (dark
    /// logos on a light plate); tvg-country gives the group's flag.
    func testZenithLogosAsPNGAndCountry() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="france-2" tvg-name="France 2 HD" tvg-logo="https://tv.example.org/api/logos/fr/france2" tvg-country="FR" group-title="France",France 2 HD
        https://tv.example.org/stream/ts/france-2
        #EXTINF:-1 tvg-id="x" tvg-name="X" tvg-logo="http://example.com/x.png" group-title="Austria",X
        http://example.com/x
        """
        let channels = M3UParser.parse(m3u)
        XCTAssertEqual(channels[0].logoURL?.absoluteString, "https://tv.example.org/api/logos/fr/france2?format=png&size=256&bg=dark")
        XCTAssertEqual(channels[0].country, "FR")
        XCTAssertEqual(channels[1].logoURL, URL(string: "http://example.com/x.png"), "other logo URLs untouched")
        XCTAssertNil(channels[1].country)
        XCTAssertEqual(GroupFlag.emoji(for: "France", channels: [channels[0]]), "\u{1F1EB}\u{1F1F7}")
        XCTAssertEqual(GroupFlag.emoji(countryCode: "AT"), "\u{1F1E6}\u{1F1F9}")
        XCTAssertEqual(GroupFlag.emoji(for: "Austria", channels: [channels[1]]), "\u{1F1E6}\u{1F1F9}", "falls back to the group name")
        XCTAssertNil(GroupFlag.emoji(countryCode: "A1"))
    }

    /// One config item: the guide URL comes from the playlist header
    /// (url-tvg, or x-tvg-url; first of a comma list; relative to the playlist).
    func testGuideURLFromHeader() {
        let base = URL(string: "https://tv.example/playlist.m3u")!
        XCTAssertEqual(M3UParser.guideURL(in: "#EXTM3U url-tvg=\"https://tv.example/epg.xml\" refresh=\"3600\"\n#EXTINF:-1,A\nhttp://a", relativeTo: base),
                       URL(string: "https://tv.example/epg.xml"))
        XCTAssertEqual(M3UParser.guideURL(in: "#EXTM3U x-tvg-url=\"https://g.example/a.xml,https://g.example/b.xml\"", relativeTo: base),
                       URL(string: "https://g.example/a.xml"))
        XCTAssertEqual(M3UParser.guideURL(in: "#EXTM3U url-tvg=\"/epg.xml\"", relativeTo: base)?.absoluteString,
                       "https://tv.example/epg.xml")
        XCTAssertNil(M3UParser.guideURL(in: "#EXTM3U\n#EXTINF:-1 url-tvg=\"http://x\",A\nhttp://a", relativeTo: base), "only the header line")
        XCTAssertNil(M3UParser.guideURL(in: "#EXTINF:-1,A\nhttp://a", relativeTo: base))
    }

    /// The player only plays raw MPEG-TS: the playlist is always requested
    /// with format=ts, so zenith never hands out HLS stream URLs (it does for
    /// clients outside the LAN otherwise). An explicit format is kept.
    func testPlaylistIsRequestedAsTS() {
        XCTAssertEqual(PlaylistService.requestURL(for: URL(string: "https://tv.example/playlist.m3u")!).absoluteString,
                       "https://tv.example/playlist.m3u?format=ts")
        XCTAssertEqual(PlaylistService.requestURL(for: URL(string: "https://tv.example/playlist.m3u?a=1")!).absoluteString,
                       "https://tv.example/playlist.m3u?a=1&format=ts")
        XCTAssertEqual(PlaylistService.requestURL(for: URL(string: "https://tv.example/playlist.m3u?format=hls")!).absoluteString,
                       "https://tv.example/playlist.m3u?format=hls")
    }
}
