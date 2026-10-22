import XCTest
@testable import IPTVPlayer

/// Records what the preview asked the player to do.
final class FakePreviewPlayer: PreviewPlaying {
    var played: [URL] = []
    var stops = 0
    func play(url: URL) { played.append(url) }
    func stop() { stops += 1 }
}

/// Channel grid preview (Apple TV): the focused tile's channel tunes in the
/// background after a short dwell; selecting it hands the running player over
/// to full screen without re-tuning.
@MainActor
final class ChannelPreviewTests: XCTestCase {
    private func ch(_ id: String) -> Channel {
        Channel(id: id, name: id, logoURL: nil, streamURL: URL(string: "https://tv.example/stream/ts/\(id)")!,
                group: "G", channelNumber: 0)
    }

    private func make(dwell: Duration = .milliseconds(100)) -> (ChannelPreview, FakePreviewPlayer) {
        let p = FakePreviewPlayer()
        return (ChannelPreview(dwell: dwell, player: p), p)
    }

    func testFocusTunesAfterTheDwell() async throws {
        let (preview, player) = make()
        preview.focus(ch("tf-1"))
        XCTAssertTrue(player.played.isEmpty, "nothing tunes before the dwell")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.played.map(\.lastPathComponent), ["tf-1"])
        XCTAssertEqual(preview.channel?.id, "tf-1")
    }

    func testScrollingPastTilesTunesOnlyWhereFocusRests() async throws {
        let (preview, player) = make()
        for id in ["a", "b", "c", "d"] {
            preview.focus(ch(id))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.played.map(\.lastPathComponent), ["d"])
    }

    func testRefocusingThePlayingChannelDoesNotRetune() async throws {
        let (preview, player) = make()
        preview.focus(ch("tf-1"))
        try await Task.sleep(for: .milliseconds(250))
        preview.focus(ch("tf-1"))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.played.count, 1)
    }

    func testLeavingTheGridStopsThePreview() async throws {
        let (preview, player) = make()
        preview.focus(ch("tf-1"))
        try await Task.sleep(for: .milliseconds(250))
        preview.leave()
        XCTAssertEqual(player.stops, 1)
        XCTAssertNil(preview.channel)
        // A pending tune is cancelled too.
        preview.focus(ch("arte"))
        preview.leave()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.played.map(\.lastPathComponent), ["tf-1"])
    }

    func testSelectingThePreviewedChannelHandsOverWithoutRetuning() async throws {
        let (preview, player) = make()
        preview.focus(ch("tf-1"))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(preview.isPlaying(ch("tf-1")), "full screen can reuse the running stream")
        XCTAssertFalse(preview.isPlaying(ch("arte")))
        preview.beginFullScreen()
        // While full screen owns the stream, focus changes behind it must not tune.
        preview.focus(ch("arte"))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.played.count, 1)
        XCTAssertEqual(player.stops, 0, "the handed-over stream keeps playing")
        preview.endFullScreen(nowPlaying: ch("tf-1"))
        XCTAssertEqual(preview.channel?.id, "tf-1", "back on the grid, the stream continues as the preview")
    }

    func testChannelSwitchedInFullScreenBecomesThePreview() async throws {
        let (preview, player) = make()
        preview.focus(ch("tf-1"))
        try await Task.sleep(for: .milliseconds(250))
        preview.beginFullScreen()
        preview.endFullScreen(nowPlaying: ch("m6"))
        XCTAssertEqual(preview.channel?.id, "m6")
        XCTAssertEqual(player.played.count, 1, "full screen tuned m6 itself; the preview does not re-tune it")
    }
}
