import AVFoundation
import CoreMedia
import Foundation

/// Display layer + audio renderer on one synchronizer; the audio renderer drives the clock.
///
/// Threading: every AVFoundation mutation runs on one private serial queue,
/// so callers (main actor, pipeline queue, VideoToolbox threads) never touch
/// the renderers directly and never block on them — flushing or changing
/// the rate of an audio renderer can block for many seconds on some outputs
/// (AirPlay, measured 15 s on macOS).
///
/// Sessions: a playback session gets a token from `beginSession()`. Every
/// enqueue/start carries its token and is dropped on the queue if the
/// session has ended, so nothing from an old channel reaches the screen
/// after `endSession()`, however late it arrives.
///
/// Feeding: samples wait in bounded backlogs and are handed over only when
/// the renderer asks (`isReadyForMoreMediaData` / `requestMediaDataWhenReady`).
public final class Renderer: @unchecked Sendable {
    public let displayLayer = AVSampleBufferDisplayLayer()
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    /// Replaced on every flush (see flushLocked()).
    public private(set) var audio: AVSampleBufferAudioRenderer

    /// ~2 s of 50p video / >= 4 s of audio frames (AAC 21 ms, E-AC-3 32 ms;
    /// the pipeline hands audio over up to audioAhead early); the oldest are
    /// dropped beyond this.
    public static let maxVideoBacklog = 100
    public static let maxAudioBacklog = 500

    /// The clock, including start/pause/resume calls the renderer has not made
    /// effective yet: those are extrapolated from when they were issued.
    /// "Effective" is checked, not assumed: with delaysRateChangeUntilHas-
    /// SufficientMediaData (default) the synchronizer defers a rate change
    /// until its renderers have prerolled and meanwhile still reports its old
    /// time; on a renderer shared across channels that is the previous
    /// channel's position, which made every channel look starved at start.
    public var currentTime: CMTime {
        statusLock.lock(); let c = commanded; let applied = appliedSeq; statusLock.unlock()
        guard let c else { return synchronizer.currentTime() }
        let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), c.host)
        let expected = CMTimeAdd(c.time, CMTimeMultiplyByFloat64(elapsed, multiplier: Float64(c.rate)))
        guard applied == c.seq else { return expected }
        let sync = synchronizer.currentTime()
        // Consistent with the command (within its time .. its time + elapsed, plus slack)?
        let lo = CMTimeSubtract(c.time, CMTime(value: 1, timescale: 10))
        let hi = CMTimeAdd(expected, CMTime(value: 1, timescale: 10))
        if sync >= lo, sync <= hi {
            statusLock.lock(); if commanded?.seq == c.seq { commanded = nil }; statusLock.unlock()
            return sync
        }
        return c.time   // deferred (prerolling): playback has not started from the commanded time yet
    }
    private var appliedSeq = 0
    private var commanded: (time: CMTime, rate: Float, host: CMTime, seq: Int)?
    private var commandSeq = 0
    /// The live session, readable without the queue (guarded by statusLock).
    private var liveSession = 0
    private var sessionSnapshot: Int { statusLock.lock(); defer { statusLock.unlock() }; return liveSession }

    /// Record a clock command now; returns what the queue must apply.
    private func command(time: CMTime, rate: Float) -> (CMTime, Float, CMTime, Int) {
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        statusLock.lock(); defer { statusLock.unlock() }
        commandSeq += 1
        commanded = (time, rate, host, commandSeq)
        return (time, rate, host, commandSeq)
    }

    /// On q: apply a recorded command, then stop extrapolating. Plain
    /// setRate(_:time:) — the host-time variant made the audio pulse on and
    /// off every ~0.5 s on the Apple TV (it fights the audio device clock).
    private func apply(_ c: (CMTime, Float, CMTime, Int)) {
        synchronizer.setRate(c.1, time: c.0)
        statusLock.lock(); appliedSeq = max(appliedSeq, c.3); statusLock.unlock()   // currentTime confirms it took effect
    }
    /// Status flags, refreshed on the renderer queue after every enqueue and
    /// flush; reads never wait for that queue (it can sit in a slow
    /// AVFoundation call, which stalled the pipeline and the main actor).
    public var audioFailed: Bool { statusLock.lock(); defer { statusLock.unlock() }; return _audioFailed }
    /// The display layer stopped decoding (e.g. interrupted while in background).
    public var displayFailed: Bool { statusLock.lock(); defer { statusLock.unlock() }; return _displayFailed }
    /// Format of the frames being displayed (for AVDisplayCriteria).
    public var displayedFormat: CMVideoFormatDescription? { statusLock.lock(); defer { statusLock.unlock() }; return _displayedFormat }
    private var _displayedFormat: CMVideoFormatDescription?
    private let statusLock = NSLock()
    private var _audioFailed = false, _displayFailed = false

    // Diagnostics / tests (read after sync()).
    private(set) var enqueuedVideo = 0
    private(set) var flushCount = 0
    var videoBacklogCount: Int { q.sync { videoBacklog.count } }
    /// Frames handed to the display layer after MetalFX upscaling (diagnostics).
    private(set) var upscaledFrames = 0
    /// Most upscaled (4K) buffers the renderer held at once: rises while an
    /// upscale is in flight for a frame being handed off, so it stays tiny.
    private(set) var peakUpscaledInFlight = 0
    /// High-water mark of the decoded backlog's footprint, bytes (the cushion
    /// must stay at decode size — upscale happens at hand-off, not in the backlog).
    private(set) var backlogPeakBytes = 0
    /// Largest single decoded frame ever queued, bytes: proves the cushion
    /// never held an upscaled (4K) frame.
    private(set) var peakBacklogFrameBytes = 0

    /// MetalFX upscaling target (tvOS screen size by default via PlayerPolicy).
    /// nil skips upscaling: frames are shown exactly as decoded.
    public var upscaleTarget: CGSize? {
        get { targetLock.lock(); defer { targetLock.unlock() }; return _upscaleTarget }
        set {
            targetLock.lock(); _upscaleTarget = newValue; let t = newValue; targetLock.unlock()
            if t == nil { q.async { self.upscaler = nil } }
        }
    }
    private let targetLock = NSLock()
    private var _upscaleTarget: CGSize?
    /// Created lazily (on the renderer queue) the first time a frame is upscaled.
    private var upscaler: Upscaler?

    private let q = DispatchQueue(label: "zenithmedia.renderer")
    private let audioOutput: Bool
    private var session = 0
    private var videoFormat: CMVideoFormatDescription?
    /// Decoded frames waiting to be handed to the display layer; upscaled only
    /// at hand-off, so this cushion stays at decode size (a decoded 4K frame is
    /// ~12 MB; the backlog could hold a hundred).
    private var videoBacklog: [DecodedFrame] = []
    private var audioBacklog: [CMSampleBuffer] = []
    private var videoRequested = false, audioRequested = false

    /// `audioOutput: false` keeps the audio renderer off the synchronizer and
    /// drops audio (host tests: the clock then runs on the host clock).
    public init(audioOutput: Bool = true) {
        self.audioOutput = audioOutput
        audio = AVSampleBufferAudioRenderer()
        displayLayer.videoGravity = .resizeAspect
        synchronizer.addRenderer(displayLayer)
        if audioOutput { synchronizer.addRenderer(audio) }
    }

    /// Start a new session: clears whatever the previous one left.
    public func beginSession() -> Int {
        q.sync {
            session += 1
            flushLocked()
            statusLock.lock(); liveSession = session; statusLock.unlock()
            return session
        }
    }

    /// End the current session (stop / channel switch). Returns at once.
    public func endSession() {
        statusLock.lock(); liveSession = -1; statusLock.unlock()
        let c = command(time: currentTime, rate: 0)
        q.async { [self] in
            session += 1
            flushLocked()
            apply(c)
        }
    }

    /// Clear the renderers within a session (pipeline restart / rebuffer).
    public func flush(session s: Int) {
        guard s == sessionSnapshot else { return }
        let c = command(time: currentTime, rate: 0)
        q.async { [self] in
            guard s == session else { return }
            flushLocked()
            apply(c)
        }
    }

    public func start(at time: CMTime, session s: Int) {
        guard s == sessionSnapshot else { return }
        let c = command(time: time, rate: 1)
        q.async { [self] in
            guard s == session else { return }
            apply(c)
        }
    }

    /// Stall: stop the clock at `time` and keep everything queued (no flush).
    /// Pausing (non-zero -> 0) never flushes the audio renderer.
    public func pause(at time: CMTime, session s: Int) {
        guard s == sessionSnapshot else { return }
        let c = command(time: time, rate: 0)
        q.async { [self] in
            guard s == session else { return }
            apply(c)
        }
    }

    /// Resume after a stall, at exactly `time`: media queued during the pause
    /// is ahead of it and plays on.
    public func resume(at time: CMTime, session s: Int) {
        guard s == sessionSnapshot else { return }
        let c = command(time: time, rate: 1)
        q.async { [self] in
            guard s == session else { return }
            apply(c)
        }
    }

    public func enqueueVideo(_ f: DecodedFrame, session s: Int) {
        q.async { [self] in
            guard s == session else { return }
            if videoFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(videoFormat!, imageBuffer: f.pixelBuffer) {
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: f.pixelBuffer, formatDescriptionOut: &videoFormat)
                statusLock.lock(); _displayedFormat = videoFormat; statusLock.unlock()
            }
            guard videoFormat != nil else { return }
            videoBacklog.append(f)
            backlogPeakBytes = max(backlogPeakBytes, Self.cushionBytes(videoBacklog))
            peakBacklogFrameBytes = max(peakBacklogFrameBytes, CVPixelBufferGetDataSize(f.pixelBuffer))
            if videoBacklog.count > Self.maxVideoBacklog { videoBacklog.removeFirst(videoBacklog.count - Self.maxVideoBacklog) }
            pumpVideo()
            refreshStatus()
        }
    }

    /// Bytes held by the decoded backlog (the cushion): stays at decode size
    /// because upscaling happens only at hand-off.
    private static func cushionBytes(_ backlog: [DecodedFrame]) -> Int {
        backlog.reduce(0) { $0 + CVPixelBufferGetDataSize($1.pixelBuffer) }
    }

    public func enqueueAudio(_ sb: CMSampleBuffer, session s: Int) {
        guard audioOutput else { return }
        q.async { [self] in
            guard s == session else { return }
            audioBacklog.append(sb)
            if audioBacklog.count > Self.maxAudioBacklog { audioBacklog.removeFirst(audioBacklog.count - Self.maxAudioBacklog) }
            pumpAudio()
            refreshStatus()
        }
    }

    /// Frames the display layer has shown and dropped (missed their display
    /// deadline) since it was created, from AVVideoPerformanceMetrics.
    public func displayMetrics() async -> (total: Int, dropped: Int)? {
        guard #available(macOS 14.4, iOS 17.4, tvOS 17.4, *),
              let m = await displayLayer.sampleBufferRenderer.videoPerformanceMetrics else { return nil }
        return (m.totalNumberOfFrames, m.numberOfDroppedFrames)
    }

    /// Wait until everything queued so far has been applied (tests).
    func sync() { q.sync {} }

    /// Occupy the renderer queue (tests: a slow AVFoundation call).
    func blockQueueForTesting(seconds: Double) { q.async { Thread.sleep(forTimeInterval: seconds) } }

    // MARK: on q

    private func refreshStatus() {
        let a = audio.status == .failed
        let d = displayLayer.status == .failed || displayLayer.sampleBufferRenderer.requiresFlushToResumeDecoding
        statusLock.lock(); _audioFailed = a; _displayFailed = d; statusLock.unlock()
    }

    /// Flushing (or pausing) an AVSampleBufferAudioRenderer waits for the output
    /// device to drain, so the old audio renderer is detached asynchronously and
    /// a fresh one takes its place.
    /// Switch audio tracks mid-play: drop queued audio and swap in a fresh
    /// audio renderer; video and the clock carry on.
    public func flushAudio(session s: Int) {
        guard s == sessionSnapshot else { return }
        q.async { [self] in
            guard s == session else { return }
            audioBacklog.removeAll(); audioRequested = false
            let old = audio
            audio = AVSampleBufferAudioRenderer()
            audio.isMuted = old.isMuted
            audio.volume = old.volume
            old.stopRequestingMediaData()
            if audioOutput {
                synchronizer.removeRenderer(old, at: .invalid) { _ in }
                synchronizer.addRenderer(audio)
            }
            refreshStatus()
        }
    }

    private func flushLocked() {
        flushCount += 1
        videoBacklog.removeAll(); audioBacklog.removeAll()
        videoRequested = false; audioRequested = false
        videoFormat = nil
        displayLayer.sampleBufferRenderer.stopRequestingMediaData()
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        let old = audio
        audio = AVSampleBufferAudioRenderer()
        audio.isMuted = old.isMuted
        audio.volume = old.volume
        old.stopRequestingMediaData()
        if audioOutput {
            synchronizer.removeRenderer(old, at: .invalid) { _ in }
            synchronizer.addRenderer(audio)
        }
        synchronizer.setRate(0, time: synchronizer.currentTime())
        refreshStatus()
    }

    private func pumpVideo() {
        let r = displayLayer.sampleBufferRenderer
        while r.isReadyForMoreMediaData, !videoBacklog.isEmpty {
            if let sb = makeDisplayBuffer(videoBacklog.removeFirst()) {
                r.enqueue(sb)
                enqueuedVideo += 1
            }
        }
        guard !videoBacklog.isEmpty, !videoRequested else { return }
        videoRequested = true
        let s = session
        r.requestMediaDataWhenReady(on: q) { [weak self] in
            guard let self, s == self.session else { r.stopRequestingMediaData(); return }
            while r.isReadyForMoreMediaData, !self.videoBacklog.isEmpty {
                if let sb = self.makeDisplayBuffer(self.videoBacklog.removeFirst()) {
                    r.enqueue(sb)
                    self.enqueuedVideo += 1
                }
            }
            if self.videoBacklog.isEmpty { self.videoRequested = false; r.stopRequestingMediaData() }
        }
    }

    /// On q: turn one decoded frame into the sample buffer the display layer
    /// gets, upscaling it first when the target is set, MetalFX is available
    /// and the frame should be scaled. This is the last moment before display,
    /// so only the frames inside the display layer hold 4K buffers, never the
    /// decoded cushion.
    private func makeDisplayBuffer(_ f: DecodedFrame) -> CMSampleBuffer? {
        let pb = upscaled(f) ?? f.pixelBuffer
        let fmt: CMVideoFormatDescription?
        if let videoFormat, CMVideoFormatDescriptionMatchesImageBuffer(videoFormat, imageBuffer: pb) {
            fmt = videoFormat
        } else {
            var created: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &created)
            fmt = created
        }
        guard let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: f.pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }

    /// On q: the frame at the upscale target, or nil when it must be shown as
    /// decoded. Skip rules are per frame so playback falls back instantly.
    private func upscaled(_ f: DecodedFrame) -> CVPixelBuffer? {
        targetLock.lock(); let target = _upscaleTarget; targetLock.unlock()
        guard let target else { return nil }
        // Thermal runaway: drop to the decoded picture at once and keep it there.
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else { return nil }
        if upscaler == nil { upscaler = Upscaler() }
        guard let upscaler else { return nil }          // no MetalFX on this device
        upscaledInFlight += 1
        peakUpscaledInFlight = max(peakUpscaledInFlight, upscaledInFlight)
        defer { upscaledInFlight -= 1 }
        guard let out = upscaler.upscale(f, pixelAspect: PixelAspect.of(f.pixelBuffer), to: target) else { return nil }
        upscaledFrames += 1
        return out.pixelBuffer
    }
    private var upscaledInFlight = 0

    private func pumpAudio() {
        let a = audio
        while a.isReadyForMoreMediaData, !audioBacklog.isEmpty { a.enqueue(audioBacklog.removeFirst()) }
        guard !audioBacklog.isEmpty, !audioRequested else { return }
        audioRequested = true
        let s = session
        a.requestMediaDataWhenReady(on: q) { [weak self] in
            guard let self, s == self.session, a === self.audio else { a.stopRequestingMediaData(); return }
            while a.isReadyForMoreMediaData, !self.audioBacklog.isEmpty { a.enqueue(self.audioBacklog.removeFirst()) }
            if self.audioBacklog.isEmpty { self.audioRequested = false; a.stopRequestingMediaData() }
        }
    }
}
