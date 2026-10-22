# VLCKit removal — probe findings

Date: 2026-10-12
Goal: replace VLCKit (licence) with a client-side player. Constraints: no
GPL/LGPL code, no libavcodec, no server-side transcoding.

## What VLCKit does for us today

`IPTVPlayer/Views/PlayerView.swift` + `VLCPlayerView.swift` (tvOS, iPad, macOS):

- plays raw MPEG-TS over HTTP: `<server>/stream/ts/<id>`
- 5 s network/live caching
- state polling for error / ended / buffering → reconnect with back-off
- draws into a UIView/NSView

No audio-track picker, no subtitles, no seeking. VLC silently does
software H.264 decode (libavcodec) + CPU deinterlace for interlaced channels.

## Stream inventory (43 channels, 2026-10-11)

| | |
|---|---|
| Video | H.264 on all channels except rai-news-24 (HEVC 720p50). No MPEG-2. |
| Interlaced | 36/43. PAFF (field pictures): TF1, M6, arte, BFM, LCI, TMC, W9, 6ter, cnews, cstar, gulli, l-equipe, lcp, novo-19, t18, tfx, france-5, melodie. MBAFF: France 2/3/4, franceinfo, Rai, ServusTV, Krone, stimmungsgarten. Mixed: rai-2, rai-5, rai-sport. |
| Progressive | ORF ×4, r9, rai-movie, rai-news-24 |
| Audio | E-AC-3 (French), AC-3, MP2 (France 3, Rai, ORF, Austrian), AAC-LC (rai-4/premium/scuola/storia). No AC-4. |
| GOP | TF1/M6/ORF/arte groups never send IDR: open GOPs starting on SPS + I + recovery-point SEI. |
| PES layout | PAFF channels send one PES per **field**. Rai sends MP2/AAC PES not aligned to audio frames. |

## Device results — Apple TV 4K 3rd gen (AppleTV14,1, A15), tvOS 27.0

Probe: `tools/decode-probe` (run with `tools/decode-probe/run-on-device.sh`).
Fixtures: 10 s cuts made by `scripts/capture-test-streams.sh`, each verified
frame-exact against an ffmpeg decode run with full prior context.

### Video (VideoToolbox)

| Stream | HW decoder | SW decoder | Bit-exact vs ffmpeg |
|---|---|---|---|
| 1080i MBAFF (france-2/3, rai-2) | refused `-12911` | 2.1–2.4× realtime | rai-2 247/247; France 2/3 ±1 LSB (≥63.5 dB, checked on macOS) |
| 1080i PAFF (tf-1) | refused | 4.2–5.6× | 250/250 when both fields go in one sample |
| 576i (melodie PAFF, rai-4 MBAFF) | refused | 10–18× | 250/250, 247/247 |
| 720p50 H.264 (orf1) | 34× | 6.8× | 493/493 |
| 720p50 HEVC (rai-news-24) | 34× | 31× | 493/493 (needs `hvc1` format description; `hev1` → `-12906`) |

- The hardware decoder never accepts interlaced H.264; VideoToolbox's
  software decoder handles PAFF and MBAFF correctly, at least 2× faster
  than realtime, which leaves headroom for deinterlacing.
- **PAFF fields must be paired.** If each field goes in as its own sample,
  VideoToolbox emits an output per field, and the first one is a
  half-filled frame (pattern `.M.M.M`). Concatenating the two fields into
  one sample gives exactly one correct frame.
- **VideoToolbox can't deinterlace on tvOS.** `FieldMode` and
  `DeinterlaceMode` are missing from the session's supported-property
  dictionary, and setting either returns `-12900`
  (kVTPropertyNotSupportedErr). Output is woven frames, so we have to
  deinterlace ourselves.

### Audio

| Codec | AudioToolbox decoder | AVSampleBufferAudioRenderer (compressed) |
|---|---|---|
| E-AC-3 | yes (PCM decode OK) | plays |
| AC-3 | yes | plays |
| AAC-LC | yes | not verified (AAC fixture damaged, see below) |
| MP2 / MP1 | **no** (`-11800`) | **fails** `-11800` |
| AC-4 | no | not needed |

- tvOS has no MPEG-1 Layer I/II decoder (macOS does).
- **`nanomp3-core` 0.2.0** (Rust, MIT OR Apache-2.0, `#![forbid(unsafe_code)]`,
  no_std, bit-identical port of minimp3, Layer I/II on by default),
  linked into the app as a Rust static library:
  - 68–73 dB SNR vs ffmpeg, max diff 1 LSB, zero lag, every clean MP2 track
  - ~7 ms to decode 10 s of stereo audio
  - decoded s16 PCM enqueued as LPCM to `AVSampleBufferAudioRenderer`
    plays (status rendering).
- Alternative considered: `oxideav-mp2` (MIT, clean-room, 43 k lines,
  includes an encoder). `symphonia-bundle-mp3` is MPL-2.0. `rust_h264`-style
  "pure" decoders were not needed for audio.

### Toolchain

- Rust `aarch64-apple-tvos` installs from rustup on stable (1.97.1).
  `transmux` (rust-broadcast) cross-compiles unchanged; a Rust `staticlib`
  links into the tvOS app through a pre-build `cargo` step and runs on the
  device.
- Signing: the App Store Connect API key works with
  `-allowProvisioningUpdates` (Xcode has no Apple ID signed in). Requires
  the Program License Agreement to be current.

## Bug found: rust-broadcast `TsDemux` drops audio frames that span two PES

`transmux/src/ts_demux.rs` `split_mpeg_audio_frames` / `find_adts_sync`
split each PES payload on its own, with no carry between PES ("partial
frame tail … discarded (no cross-PES carry)"). Rai's muxer does not align
PES to audio frames, so every frame that straddles a PES boundary is lost:

- 22 tracks affected in the fixture set: every Rai MP2 track (~33 frames
  lost per 10 s ≈ 8 %) and every Rai AAC track (rai-4/premium/scuola/storia:
  ~18 gaps, nearly all audio lost).
- Not affected: E-AC-3/AC-3 tracks; French and ORF MP2 tracks (aligned PES).
- The fixtures in `testdata/streams` carry the damage for those tracks.
  Video in them is fine.

Needed: carry the unconsumed tail of each PES into the next one per track
(MPEG audio, ADTS, and for safety AC-3/E-AC-3/DTS), interpolating
timestamps from the PES that carries the frame start. Then recapture
the Rai fixtures.

## Excluded

- Apple TV HD (A8): out of scope, per decision on 2026-10-12.
- Server-side transcoding, LGPL/GPL, libavcodec: excluded by requirement.
- `rust_h264` 0.4 (MIT/Apache): tested on the fixtures and rejected (PAFF
  output was garbage, MBAFF wrong, blocky even on progressive streams).
  The VideoToolbox software decoder makes a third-party video decoder
  unnecessary.

## Open items for the design

1. Deinterlacer: Metal compute shader (bob / yadif- or bwdif-style
   temporal), 50 fields/s → 50p output.
2. Field pairing in the demux → VideoToolbox path (slice header
   `field_pic_flag` / `bottom_field_flag`), plus MBAFF/PAFF detection to
   decide when to deinterlace (SPS `frame_mbs_only_flag`, pic_struct SEI).
3. A/V sync and presentation: `AVSampleBufferRenderSynchronizer` with an
   `AVSampleBufferDisplayLayer` (decoded frames) and an
   `AVSampleBufferAudioRenderer` (compressed AC-3/E-AC-3/AAC, or MP2 decoded
   to LPCM).
4. Live-edge buffering, stall detection and reconnect (today's VLC state polling).
5. The same pipeline on iPad and macOS (macOS has a hardware decoder for
   progressive streams and an MP2 decoder in AudioToolbox, but one code
   path is simpler).
