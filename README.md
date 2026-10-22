# Zenith Player

A native IPTV player for Apple TV and iPad, written in Swift and SwiftUI.
It plays live MPEG-TS channels from an M3U playlist you provide, with a
programme guide from the playlist's XMLTV `url-tvg`.

Zenith Player ships no channels and no server. Point it at your own
playlist, or run a Zenith server on your
network and the app finds it over Bonjour (`_zenith._tcp`).

## Features

- Live MPEG-TS over HTTP, decoded with VideoToolbox (hardware where the
  stream allows, software for interlaced H.264), Metal deinterlacing,
  AC-3 / E-AC-3 / MP2 / AAC audio, audio-track selection.
- Channel grid by `group-title`, logos from `tvg-logo`, country flags from
  `tvg-country`.
- Programme guide (XMLTV) from the playlist header: `#EXTM3U url-tvg="…"`.
- Live preview: on Apple TV, focusing a channel plays it behind the grid.
- Display matching: frame rate and dynamic range follow the channel.
- The playlist URL syncs across your devices through iCloud.

No third-party video libraries: demuxing is
[transmux](https://crates.io/crates/transmux) (Rust, MIT OR Apache-2.0),
decoding and output are Apple frameworks.

## Playlist format

```
#EXTM3U url-tvg="http://server.local/epg.xml.gz"
#EXTINF:-1 tvg-id="france-2" tvg-logo="http://server.local/logos/france2.png" tvg-country="FR" group-title="France",France 2
http://server.local/stream/ts/france-2
```

Stream URLs must serve raw MPEG-TS (not HLS). The app adds `format=ts` to
the playlist request so a Zenith server hands out TS URLs.

## Building

Requirements: a current Xcode (developed with Xcode 27), Rust stable with the Apple targets:

```bash
rustup target add aarch64-apple-tvos aarch64-apple-tvos-sim aarch64-apple-ios aarch64-apple-ios-sim
```

1. Copy `Config/Signing.local.xcconfig.example` to
   `Config/Signing.local.xcconfig` and set your bundle ID and team ID
   (simulator builds work without it).
2. Open `IPTVPlayer.xcodeproj`, choose the `IPTVPlayer` (tvOS) or
   `ZenithTV-iPad` scheme, and run. The Rust library builds as part of the
   Xcode build.

## Tests

```bash
scripts/test-zenith-media.sh   # player library: Rust + Swift tests on the Mac
scripts/test-app.sh            # app tests on the tvOS simulator
```

Most player tests need stream fixtures in `testdata/`. Synthetic audio,
PAFF and deinterlace fixtures are built by `scripts/make-*-fixtures.sh`
(from openly licensed sources). Broadcast captures are not distributed:
record your own with `scripts/capture-test-streams.sh`. Tests whose
fixtures are missing are skipped. Live-server tests run when
`ZENITH_TEST_SERVER` is set.

Maintainer scripts (on-device verification, TestFlight) read their
settings from `.env`; see `.env.example`.

## Licence

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. Unless you explicitly state otherwise, any contribution
intentionally submitted for inclusion in this work, as defined in the
Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.
