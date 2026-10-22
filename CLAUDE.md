# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository.

## Project

Zenith Player: native tvOS and iPadOS IPTV app (SwiftUI). Loads a user-supplied
M3U playlist (no built-in server; first run shows SetupView, Bonjour
`_zenith._tcp` discovery fills it in), plays raw MPEG-TS through ZenithMedia.

- `IPTVPlayer/`: app (targets IPTVPlayer = tvOS, ZenithTV-iPad, ZenithTV-Mac)
- `ZenithMedia/`: player library, Swift package over a Rust staticlib
  (`ZenithMedia/rust`, transmux demux). VideoToolbox decode, Metal deinterlace,
  AVSampleBufferDisplayLayer / AudioRenderer output.
- `tools/decode-probe`: on-device test harness and live soak.

## Build and test

- Signing comes from `Config/Signing.xcconfig` + gitignored
  `Config/Signing.local.xcconfig`. Never put team IDs or bundle IDs in the project.
- `scripts/test-zenith-media.sh [filter]`: library tests on the Mac.
- `scripts/test-app.sh [-only-testing:…]`: app tests on the tvOS simulator.
- `scripts/verify-on-tv.sh`: harness + soak + app install on a paired Apple TV
  (reads `.env`).

## Simulator navigation

Arrow keys navigate, Return selects, Escape goes back.
