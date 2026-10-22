# Future feature: Metal pull renderer with MetalFX upscaling

Status: **deferred** (owner decision, 2026-10-19). Not scheduled.

## Goal

Sharper SD and 720p pictures on the Apple TV by upscaling each frame to the
screen's native resolution (3840x2160) with Apple's MetalFX spatial scaler,
instead of the display layer's default GPU scaling.

## Why it is not in the app today

The working `Upscaler` (MetalFX spatial scaler, Y'CbCr→RGB, square-pixel
output shaped by the pixel aspect; `UpscalerTests` 4/4) exists, but our
video output is a **push** renderer: frames are enqueued into
`AVSampleBufferDisplayLayer` ahead of time, and on the Apple TV the layer
accepts hundreds of frames ahead. Every placement of the upscale in that
model failed on the device (Apple TV 4K 3rd gen, 2026-10-19):

| Attempt | Result on the TV |
|---|---|
| Upscale at decode time (6c69788) | The 1.5 s decoded cushion held 4K frames (12.4 MB each). The app hit the 2.2 GB per-process jetsam limit; VideoToolbox decode submissions then failed (404 on tf-1, 1198 on bfm-tv). |
| Upscale at hand-off, fixed pool of 8, frames handed only within 0.2 s of the clock (51ca0bd) | No memory kills, but the hand-off window throttled decoding and delayed the start (melodie/tf-1: 164 frames decoded vs 205-213, first frame 2.7 s vs 0.7-1.0 s); rai-4 576i: 186 decode failures; the soak test app hung and was killed. |
| Upscale at hand-off, eager feed, pool of 8 as the only bound (d569bdb, not run on the TV) | The layer takes far more than 8 frames ahead, so the pool is exhausted nearly all the time: most frames would go out unscaled, mixing 4K and SD frames. |

The upscale belongs at the moment a frame is **drawn**, which the push model
cannot express.

## Proposed design

Replace the video output with a **pull** renderer:

- A `CAMetalLayer` (or `MTKView`) driven by a `CADisplayLink` at the display's
  refresh rate (50 Hz with Match Frame Rate on).
- On each vsync, take the frame whose PTS matches the audio clock (from
  `AVSampleBufferAudioRenderer` / the synchronizer's time), run the Y'CbCr→RGB
  conversion and the MetalFX scaler, and present. Only 2-3 frames are in
  flight on the GPU; the decoded cushion stays at decode size.
- Audio stays on `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`;
  video follows the synchronizer's clock, so A/V sync, pause/resume and the
  buffering-runtime decisions keep their current contract.
- Keep the skip rules: thermal state serious/critical, HDR / 10-bit, source
  already at or above the screen size (draw it directly).
- Display-mode matching (AVDisplayCriteria) and HDR output need the Metal
  layer configured for the content's colour space / EDR.

## Acceptance (when this is picked up)

- On the TV: no memory growth over a 30-minute soak (jetsam-free, footprint
  flat), first frame and stall counts no worse than the push renderer, 0
  dropped display frames at 50 fps on 1080i and 576i channels, A/V offset
  within ±20 ms.
- Upscaled output measurably sharper than the layer's scaling on an SD
  channel (side-by-side capture), and a clean fall-back when the TV heats up.

## Where the code is

- Branch `feature/metalfx-upscale` (worktree `.worktree/upscale`): the
  `Upscaler`, the Metal shaders, `UpscalerTests`, and the three integration
  attempts above (6c69788, 51ca0bd, d569bdb).
- On the main line the `Upscaler` ships dormant: `PlayerPolicy.upscaleTarget`
  defaults to nil (0f8013f).
- Colour inputs the converter should use come from transmux 0.27.6
  (`DisplayGeometry.video_signal`): matrix, transfer, full range.
