import AVFoundation
import QuartzCore
import CoreMedia
import Foundation
import Observation
import os
#if os(tvOS)
import UIKit
#endif

public enum PlayerPhase: Equatable, Sendable {
    case loading, playing, buffering(String?), reconnecting(attempt: Int), failed
}

/// An audio track the viewer can choose.
public struct AudioTrackOption: Sendable, Equatable, Identifiable {
    public let id: UInt32
    /// e.g. "Français · E-AC-3 stereo", "Deutsch · AC-3 5.1 · audio description".
    public let label: String
    public let language: String
    public let role: AudioRole

    init(_ t: TrackInfo) {
        id = t.trackID; language = t.language; role = t.role
        let lang = t.language.isEmpty ? "Unknown language"
            : (Locale.current.localizedString(forLanguageCode: t.language) ?? t.language).capitalized
        let codec: String = switch t.codec {
        case .eac3: "E-AC-3"
        case .ac3: "AC-3"
        case .aac: "AAC"
        case .mpegAudio: "MPEG audio"
        default: "audio"
        }
        let layout = t.channels == 1 ? "mono" : t.channels == 2 ? "stereo" : t.channels == 6 ? "5.1" : "\(t.channels) ch"
        var parts = [lang, "\(codec) \(layout)"]
        switch t.role {
        case .audioDescription: parts.append("audio description")
        case .hearingImpaired: parts.append("hard of hearing")
        default: break
        }
        label = parts.joined(separator: " · ")
    }
}

public struct PlayerPolicy: Sendable {
    /// MetalFX spatial upscaling of decoded SD/HD frames to the screen's
    /// native resolution before display (tvOS only; sharper than the display
    /// layer's own scaling). nil turns it off entirely. On tvOS the default is
    /// the screen's native size, set in one place here, so every player — the
    /// channel-grid preview's and full-screen's — gets it without a caller
    /// setting it. iPad and macOS keep nil (unchanged behaviour).
    /// Off (nil) until the memory problem is fixed: on the Apple TV the display
    /// layer takes far more than a few 4K frames ahead, so DecodeProbe reached
    /// the 2.2 GB per-process limit and VideoToolbox decodes failed (2026-10-19).
    /// Set to PlayerPolicy.tvOSScreenSize() to upscale.
    public var upscaleTarget: CGSize? = nil
    /// Seconds of decoded video before playback starts (zap time vs stall
    /// margin; an empty buffer shows "Buffering…" and refills).
    /// Covers video and audio (audio is muxed ~1 s behind video, so this is
    /// usually reached ~1.5 s after the join). 0.5 s since zenith stopped
    /// stalling (server catch-up + no runtime freezes, 2026-10-17).
    public var startBuffer = 0.5
    /// false: never flush and re-buffer on starvation (measurement of
    /// AVSampleBufferRenderSynchronizer's own behaviour across a gap).
    public var rebufferOnStarvation = true
    /// Video is decoded at most this far ahead of the clock; the rest of the
    /// buffer stays compressed (decoded 1080 frames are ~3 MB each).
    public var decodeAhead = 1.5
    /// Audio is handed to the renderer at most this far ahead of the clock.
    /// Compressed audio is small; hand it over well ahead (as soon as it
    /// arrives, in practice) so the audio output is never fed at the deadline.
    public var audioAhead = 8.0
    public var stallMessageAfter = 5.0
    public var stallReconnectAfter = 30.0
    public var reconnectDelays: [Double] = [2, 4, 8]
    public var reconnectMax = 10.0
    public var decoderFailuresBeforeReconnect = 3
    /// Frames in a row that VideoToolbox failed asynchronously, with no good
    /// frame between, before the decoder counts as broken (~1 s of 25p).
    /// Isolated failures (damaged frame, picky join) are tolerated.
    public var consecutiveDecodeErrorsBeforeReconnect = 25
    /// Give up on a start-up (first start or after a restart) that has not
    /// produced a picture after this long, and reconnect.
    public var startTimeout = 15.0
    /// A stream whose tracks are known but has no H.264/HEVC video fails after this long.
    public var noVideoAfter = 1.5
    public init() {}
    public init(startBuffer: Double, stallMessageAfter: Double, stallReconnectAfter: Double,
                reconnectDelays: [Double], reconnectMax: Double, decoderFailuresBeforeReconnect: Int) {
        self.startBuffer = startBuffer; self.stallMessageAfter = stallMessageAfter
        self.stallReconnectAfter = stallReconnectAfter; self.reconnectDelays = reconnectDelays
        self.reconnectMax = reconnectMax; self.decoderFailuresBeforeReconnect = decoderFailuresBeforeReconnect
    }

    /// The tvOS upscale target: the screen's native size. nil everywhere else
    /// (iPad and macOS do not upscale). Read on the main actor.
    public static func tvOSScreenSize() -> CGSize? {
        #if os(tvOS)
        return UIScreen.main.nativeBounds.size
        #else
        return nil
        #endif
    }
}

public struct PlayerStats: Sendable {
    public var bufferedSeconds = 0.0
    /// Decoded video queued ahead of the clock, seconds (memory-bound part).
    public var decodedAheadSeconds = 0.0
    /// Audio diagnostics while playing: the smallest lead (audio PTS − clock)
    /// at hand-off, and buffers handed over already past due.
    public var minAudioLeadSeconds: Double?
    public var audioLateBuffers = 0
    /// Stalls where live-buffer named audio as the starving track.
    public var starvedOnAudio = 0
    /// live-buffer's view at the last pause (diagnostics).
    public var lastPauseInfo: String?
    public var framesDecoded = 0
    /// Frames lost to decode failures (should stay 0).
    public var framesDropped = 0
    /// Samples skipped while waiting for a join point (transmux LiveJoin).
    public var framesDroppedBeforeRAP = 0
    /// Leading pictures of a join point: undecodable by design, skipped.
    public var leadingPictures = 0
    public var framesEnqueued = 0
    /// First enqueued audio PTS minus first displayed video PTS, seconds (start alignment).
    public var avOffset = 0.0
    /// AVSampleBufferAudioRenderer automatic flushes (audio underrun / timebase jump).
    public var audioFlushes = 0
    public var audioTrack: UInt32?
    /// e.g. "ac3 6ch deu" — the selected audio track, for logs.
    public var audioTrackLabel: String?
    /// Start-up milestones, seconds after the connection was opened:
    /// first byte, first track announced, first video join point, first picture.
    public var firstByteAfter: Double?
    public var firstTrackAfter: Double?
    public var joinPointAfter: Double?
    public var firstFrameAfter: Double?
    /// Frames per second leaving the pipeline (after deinterlacing), from the
    /// median PTS step: what the display should refresh at (AVDisplayCriteria).
    public var outputFrameRate: Double?
    /// VideoToolbox picked its hardware decoder for the current stream.
    public var hardwareDecode: Bool?
    public var restarts = 0
    /// Times the buffer ran dry and playback re-buffered in place.
    public var rebuffers = 0
    /// Starvations while no network data arrived for > 0.25 s (delivery stall)…
    public var starvedNoData = 0
    /// …and while data kept arriving (the stream fell behind real time, or we did).
    public var starvedWithData = 0
    /// Longest wall-clock gap between two received chunks, seconds.
    public var maxChunkGap = 0.0
    /// Longest time one chunk spent in the pipeline (demux + hand-off), seconds;
    /// reading stops meanwhile, so this is the player's own share of a gap.
    public var maxFeedSeconds = 0.0
    /// Deinterlacer: longest wall wait for one field, and longest GPU time (diagnostics).
    public var maxDeintWait = 0.0
    public var maxDeintGPU = 0.0
    /// Longest single VTDecompressionSessionDecodeFrame call and demux feed (diagnostics).
    public var maxDecodeCall = 0.0
    public var maxDemuxFeed = 0.0
}

private let log = Logger(subsystem: "zenithmedia", category: "player")

/// Owns one playback: source → demux → decode/deinterlace → renderer.
/// All pipeline work runs on `work`; state is published on the main actor.
/// Every start-up gets a new `generation`; work tagged with an older
/// generation is dropped, so a channel switch never leaks old frames.
@MainActor @Observable
public final class PlayerController {
    public private(set) var phase: PlayerPhase = .loading
    public private(set) var stats = PlayerStats()
    /// Output frame rate once known; changes rarely (views can observe it
    /// without redrawing on every stats update).
    public private(set) var outputFrameRate: Double?
    /// The channel's audio tracks (PMT order) and the one playing.
    public private(set) var audioTracks: [AudioTrackOption] = []
    public private(set) var playingAudioTrack: UInt32?
    /// The viewer's choice; nil = automatic (AudioTrackSelector). Cleared on a new play().
    public private(set) var chosenAudioTrack: UInt32?

    /// Play this audio track (nil: back to the automatic choice). Takes effect
    /// mid-stream: only the audio renderer is swapped.
    public func selectAudio(_ trackID: UInt32?) {
        chosenAudioTrack = trackID
        currentPipe?.selectAudio(trackID)
    }
    /// Diagnostics: every live-buffer input as a CSV row (see LiveBuffer.inputLog),
    /// called on the pipeline queue.
    public var liveBufferLog: (@Sendable (String) -> Void)?
    /// live-buffer stall memory, carried across connections and channels
    /// (session scope: it describes the network path, not one channel).
    private var stallMemory: (peak: UInt64, age: UInt64)?
    public let renderer: Renderer

    private let policy: PlayerPolicy
    private let chooseAudio: ([TrackInfo]) -> TrackInfo?
    private let isInterlaced: (TrackInfo) -> Bool
    private let topFieldFirst: ((TrackInfo) -> Bool)?
    private var makeVideoDecoder: @Sendable (TrackInfo) throws -> VideoDecoding = { try VideoDecoder(track: $0) }
    private var task: Task<Void, Never>?
    private var generation = 0
    private var currentPipe: Pipeline?
    private let work = DispatchQueue(label: "zenithmedia.player")

    /// The decode window allows this many frames beyond decodeAhead, and at
    /// most this many arrivals past it are skipped in a row (a backlog far
    /// beyond decodeAhead is worked off, not skipped wholesale).
    static let decodeAheadToleranceFrames = 3
    static let decodeAheadJumpFrames = 4
    /// Frame rate the jump margin is measured at (the fastest broadcast rate).
    static let decodeAheadNominalFPS = 50.0

    /// Interlaced unless transmux says the coding is progressive (R3).
    public nonisolated static func codedInterlaced(_ t: TrackInfo) -> Bool {
        t.scan == .paff || t.scan == .mbaff || t.scan == .fieldSequence
    }

    public init(renderer: Renderer = Renderer(), policy: PlayerPolicy = PlayerPolicy(),
                chooseAudio: @escaping ([TrackInfo]) -> TrackInfo? = AudioTrackSelector.choose,
                isInterlaced: @escaping (TrackInfo) -> Bool = PlayerController.codedInterlaced,
                topFieldFirst: ((TrackInfo) -> Bool)? = nil) {
        self.renderer = renderer; self.policy = policy; self.chooseAudio = chooseAudio
        self.isInterlaced = isInterlaced; self.topFieldFirst = topFieldFirst
        renderer.upscaleTarget = policy.upscaleTarget
    }

    /// Test seam: a substitute video decoder factory (nil = VideoToolbox).
    func useDecoders(_ f: (@Sendable (TrackInfo) throws -> VideoDecoding)?) {
        if let f { makeVideoDecoder = f }
    }

    public func play(_ source: @escaping () -> ByteSource) {
        stop()
        chosenAudioTrack = nil; audioTracks = []; playingAudioTrack = nil
        task = Task { [weak self] in await self?.runLoop(source) }
    }

    public func stop() {
        generation += 1
        currentPipe?.abort()          // old pipeline stops producing at once
        currentPipe = nil
        task?.cancel()
        task = nil
        renderer.endSession()          // and anything already queued is dropped
        phase = .loading
    }

    // MARK: connection loop with back-off

    private func runLoop(_ source: @escaping () -> ByteSource) async {
        var attempt = 0
        while !Task.isCancelled {
            let gen = generation
            let outcome = await runOnce(source(), gen: gen)
            guard !Task.isCancelled, gen == generation else { return }
            if outcome == .unsupported { phase = .failed; return }
            if outcome == .playedThenEnded {
                // The live stream played and then ended (server closed it): reconnect
                // at once. Each such retry must reach playback again, so this can't spin.
                attempt = 0
                phase = .reconnecting(attempt: 1)
                log.info("stream ended after playing; reconnecting now")
                continue
            }
            attempt += 1
            phase = .reconnecting(attempt: attempt)
            let delay = attempt <= policy.reconnectDelays.count ? policy.reconnectDelays[attempt - 1] : policy.reconnectMax
            log.info("reconnect attempt \(attempt) in \(delay)s")
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private enum Outcome { case failedBeforePlaying, playedThenEnded, unsupported }

    private func runOnce(_ src: ByteSource, gen: Int) async -> Outcome {
        let pipe = Pipeline(renderer: renderer, policy: policy, chooseAudio: chooseAudio,
                            isInterlaced: isInterlaced, topFieldFirst: topFieldFirst, makeDecoder: makeVideoDecoder, queue: work,
                            isCurrent: { [weak self] in await MainActor.run { self?.generation == gen } },
                            stallMemory: stallMemory, liveBufferLog: liveBufferLog, chosenAudio: chosenAudioTrack)
        currentPipe = pipe
        if case .reconnecting = phase {} else { phase = .loading }  // keep "Reconnecting… (n)" visible until playing
        var played = false
        var unsupported = false
        let monitor = Task { [weak self] in
            var waitStart: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, gen == self.generation else { return }
                let s = pipe.snapshot()
                self.stats = s.stats
                if let r = s.stats.outputFrameRate, r != self.outputFrameRate { self.outputFrameRate = r }
                let opts = pipe.audioOptions
                if opts != self.audioTracks { self.audioTracks = opts }
                if s.stats.audioTrack != self.playingAudioTrack { self.playingAudioTrack = s.stats.audioTrack }
                switch s.state {
                case .running:
                    played = true; waitStart = nil
                    if self.phase != .playing { self.phase = .playing }
                case .noVideo:
                    unsupported = true
                    pipe.abort()
                case .starting, .starved:
                    // Starved: the pipeline has paused the clock and is refilling.
                    // Starting: first start or after a restart. Either way, give up
                    // and reconnect if nothing plays for stallReconnectAfter.
                    let since = waitStart ?? Date(); waitStart = since
                    let t = Date().timeIntervalSince(since)
                    if played {
                        self.phase = .buffering(t > self.policy.stallMessageAfter ? "Waiting for server… (\(Int(t))s)" : "Buffering…")
                    }
                    if t > (played ? self.policy.stallReconnectAfter : self.policy.startTimeout) { pipe.abort() }
                case .decoderBroken:
                    pipe.abort()
                }
            }
        }
        // The read loop runs in its own task so abort() (stall, broken decoder)
        // can cancel it even while it is suspended waiting for bytes.
        let reader = Task {
            do {
                for try await chunk in src.bytes() {
                    if Task.isCancelled || pipe.aborted { break }
                    await pipe.feed(chunk)
                }
            } catch {
                log.error("source error: \(String(describing: error))")
            }
        }
        pipe.onAbort = { reader.cancel() }
        await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
        monitor.cancel()
        stallMemory = pipe.stallMemory          // the path's stall history outlives the connection
        await pipe.shutdown()
        if unsupported { return .unsupported }
        return played ? .playedThenEnded : .failedBeforePlaying
    }
}

/// The per-connection pipeline. Lives on `queue`; the controller reads
/// lock-protected snapshots. Every renderer call carries this pipeline's
/// renderer session, so nothing from it reaches the screen once it ends.
///
/// Buffering is compressed: demuxed samples wait in `videoQ` / `audioQ` and a
/// pump (after every chunk and on a 20 ms timer) decodes video only
/// `decodeAhead` ahead of the clock and hands audio over `audioAhead` ahead.
/// A stall pauses the clock at the last position with media and resumes it
/// there once refilled; nothing is flushed.
final class Pipeline: @unchecked Sendable {
    enum State { case starting, running, starved, decoderBroken, noVideo }

    private let renderer: Renderer
    private let policy: PlayerPolicy
    private let chooseAudio: ([TrackInfo]) -> TrackInfo?
    private let isInterlaced: (TrackInfo) -> Bool
    /// Override for tests/harness; nil = field order from the samples (R3).
    private let topFieldFirst: ((TrackInfo) -> Bool)?
    private let factory: @Sendable (TrackInfo) throws -> VideoDecoding
    private let queue: DispatchQueue
    private let isCurrent: @Sendable () async -> Bool
    private let session: Int
    private let born = Date()
    private var timer: DispatchSourceTimer?

    // Queue-confined state.
    private let demux = TsDemuxer()
    private var tracks: [UInt32: TrackInfo] = [:]
    private var video: (info: TrackInfo, decoder: VideoDecoding, deint: Deinterlacer?)?
    private var audio: (info: TrackInfo, factory: AudioSampleFactory)?
    /// Queued for the decode worker, not submitted to the decoder yet: they
    /// count against the decode window exactly like delivered frames.
    private var decodedQ: [MediaSample] = []
    /// Bumped on every restart: frames decoded for an older epoch are dropped.
    private var epoch = 0 { didSet { decoderLock.lock(); epochSnapshot = epoch; decoderLock.unlock() } }
    /// The decode worker: one serial queue, so decode calls stay in DTS order
    /// and a slow decoder cannot hold up the pipeline queue.
    private let decodeWorker = DispatchQueue(label: "zenithmedia.decode", qos: .userInitiated)
    /// The decoder the worker is exercising (dropped from the pipeline queue
    /// too, so a restart waits for its in-flight calls, not for the worker).
    private let decoderLock = NSLock()
    private var currentDecoder: VideoDecoding?
    /// `epoch` as the worker sees it, guarded by decoderLock.
    private var epochSnapshot = 0
    private var startPTS: Int64?            // join point PTS (video timescale)
    private var lastVideoPTS: Int64?        // newest demuxed video PTS
    private var lastVideoAt: Double?        // uptime (s) when lastVideoPTS was demuxed
    /// End of the newest demuxed audio frame (selected track).
    private var lastAudioEnd: CMTime?
    /// Demuxed, not yet decoded video (decode order).
    private var videoQ: [MediaSample] = []
    /// Selected-track audio not yet handed to the renderer.
    private var audioQ: [MediaSample] = []
    /// Decoded before the first start (at most decodeAhead of it).
    private var bufferedVideo: [DecodedFrame] = []
    private var started = false
    private var paused = false
    private var holdAt = CMTime.invalid
    private var decoderFailures: [Date] = []
    private var consecutiveDecodeErrors = 0
    /// rust-broadcast live-buffer: delivery jitter, buffer target and the
    /// start / pause / resume decisions. Video reports as track 1, audio as 2
    /// (logical ids, so an audio pick change never leaves a dead track).
    private let lb: LiveBuffer?
    private static let lbVideo: UInt32 = 1, lbAudio: UInt32 = 2
    private var startAllowed = false
    private var audioUnregistered = false
    /// The viewer's audio choice (queue-confined); nil = automatic.
    private var chosenAudio: UInt32?
    private var pubAudioOptions: [AudioTrackOption] = []
    /// Media ends reached while demuxing the current chunk: reported once per
    /// chunk (a delivery), so live-buffer sees the real delivery granularity
    /// (rai-3: one 0.3 s audio PES per delivery, not twelve 24 ms frames).
    private var pendingVideoEnd: CMTime?, pendingAudioEnd: CMTime?
    /// Field order: the override if given, else learned from the samples'
    /// slice headers / pic_struct (transmux R3); broadcast default TFF.
    private var tff = true
    struct Geometry: Equatable {
        let pixelAspect: PixelAspect?
        let colour: VideoColour?
    }
    /// Display geometry announced while demuxing (and not yet announced for
    /// the decode worker), and what the worker last sent to the decoder.
    /// Kept apart from `tracks` so a TrackUpdated's static geometry never
    /// overrides a per-picture display state.
    private var pendingGeometry: [UInt32: Geometry] = [:]
    private var submittedGeometry: [UInt32: Geometry] = [:]

    // Shared with the main actor (snapshot) — guarded by `lock`.
    private let lock = NSLock()
    private var stats = PlayerStats()
    private var state: State = .starting
    private var pubStarted = false
    private var pubLastVideoSeconds: Double?
    private var pubLastEnqueuedVideoSeconds: Double?
    private var pubHasVideo = false
    private var firstTrackAt: Date?
    private var _aborted = false
    private var _onAbort: (() -> Void)?
    private var restartRequested = false
    private var lastChunkAt: Date?

    private var flushObserver: NSObjectProtocol?

    init(renderer: Renderer, policy: PlayerPolicy, chooseAudio: @escaping ([TrackInfo]) -> TrackInfo?,
         isInterlaced: @escaping (TrackInfo) -> Bool, topFieldFirst: ((TrackInfo) -> Bool)?,
         makeDecoder: @escaping @Sendable (TrackInfo) throws -> VideoDecoding,
         queue: DispatchQueue, isCurrent: @escaping @Sendable () async -> Bool,
         stallMemory: (peak: UInt64, age: UInt64)? = nil, liveBufferLog: (@Sendable (String) -> Void)? = nil,
         chosenAudio: UInt32? = nil) {
        factory = makeDecoder
        self.chosenAudio = chosenAudio
        lb = LiveBuffer(initialStart: policy.startBuffer, seed: stallMemory)
        lb?.inputLog = liveBufferLog
        // Every track we will play is registered before the first delivery, so
        // the start waits for audio too (live-buffer #1364). A channel without
        // audio starts once the silence timeout drops the audio track.
        lb?.register(track: Self.lbVideo)
        lb?.register(track: Self.lbAudio)
        self.renderer = renderer; self.policy = policy; self.chooseAudio = chooseAudio
        self.isInterlaced = isInterlaced; self.topFieldFirst = topFieldFirst; self.queue = queue; self.isCurrent = isCurrent
        session = renderer.beginSession()
        flushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: nil, queue: nil
        ) { [weak self] note in
            guard let self, note.object as AnyObject? === self.renderer.audio else { return }
            self.lock.lock(); self.stats.audioFlushes += 1; self.lock.unlock()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in
            guard let self, !self.aborted else { return }
            if self.takeRestartRequest() { self.restart(newTimeline: false) }
            self.pump()
        }
        t.resume()
        timer = t
    }

    deinit {
        timer?.cancel()
        flushObserver.map(NotificationCenter.default.removeObserver)
    }

    // MARK: main-actor side

    func snapshot() -> (state: State, stats: PlayerStats) {
        lock.lock(); defer { lock.unlock() }
        var s = stats
        if pubStarted {
            let now = CMTimeGetSeconds(renderer.currentTime)
            s.bufferedSeconds = max(0, (pubLastVideoSeconds ?? now) - now)
            stats.bufferedSeconds = s.bufferedSeconds
            s.decodedAheadSeconds = max(0, (pubLastEnqueuedVideoSeconds ?? now) - now)
            stats.decodedAheadSeconds = s.decodedAheadSeconds
        }
        if !pubHasVideo, let t = firstTrackAt, Date().timeIntervalSince(t) > policy.noVideoAfter, state == .starting { state = .noVideo }
        // Layer interrupted (e.g. in background): restart through a flush.
        if renderer.displayFailed, pubStarted { restartRequested = true }
        return (state, s)
    }

    var aborted: Bool { lock.lock(); defer { lock.unlock() }; return _aborted }

    var audioOptions: [AudioTrackOption] { lock.lock(); defer { lock.unlock() }; return pubAudioOptions }

    func selectAudio(_ trackID: UInt32?) {
        queue.async {
            self.chosenAudio = trackID
            self.pickAudio(switching: true)
        }
    }

    var onAbort: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onAbort }
        set {
            lock.lock(); _onAbort = newValue; let already = _aborted; lock.unlock()
            if already { newValue?() }      // abort() before the reader was wired up
        }
    }

    /// Stop producing at once (stop / channel switch / give up). Safe from any thread.
    func abort() {
        lock.lock(); _aborted = true; let cb = _onAbort; lock.unlock()
        cb?()
        queue.async { self.timer?.cancel(); self.video?.decoder.invalidate() }
    }

    func feed(_ chunk: Data) async {
        guard await isCurrent(), !aborted else { abort(); return }
        let now = Date()
        let arrivalUs = LiveBuffer.nowUs()
        lock.lock()
        if let last = lastChunkAt { stats.maxChunkGap = max(stats.maxChunkGap, now.timeIntervalSince(last)) }
        if stats.firstByteAfter == nil { stats.firstByteAfter = now.timeIntervalSince(born) }
        lastChunkAt = now
        lock.unlock()
        defer {
            let t = Date().timeIntervalSince(now)
            lock.lock(); stats.maxFeedSeconds = max(stats.maxFeedSeconds, t); lock.unlock()
        }
        await withCheckedContinuation { cont in
            queue.async {
                if !self.aborted {
                    let t0 = CACurrentMediaTime()
                    self.demux.feed(chunk)
                    let dt = CACurrentMediaTime() - t0
                    if dt > self.stats.maxDemuxFeed { self.lock.lock(); self.stats.maxDemuxFeed = dt; self.lock.unlock() }
                    while !self.aborted, let ev = self.demux.nextEvent() { self.handle(ev) }
                    self.lb?.chunk(arrivalUs: arrivalUs, bytes: chunk.count, pcr27: self.demux.takePCR())
                    self.reportMediaEnds()
                    self.pump()
                }
                cont.resume()
            }
        }
    }

    /// Stall memory to seed the next connection's controller (session scope).
    var stallMemory: (peak: UInt64, age: UInt64)? {
        var m: (peak: UInt64, age: UInt64)?
        queue.sync { m = lb?.memory }
        return m
    }

    func shutdown() async {
        await withCheckedContinuation { cont in
            queue.async {
                self.timer?.cancel()
                self.video?.decoder.invalidate()
                cont.resume()
            }
        }
    }

    // MARK: queue side

    private func takeRestartRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let r = restartRequested; restartRequested = false
        return r
    }

    private func publish() {
        lock.lock()
        pubStarted = started
        pubLastVideoSeconds = mediaEnd().map(CMTimeGetSeconds)
        pubHasVideo = video != nil
        lock.unlock()
    }

    private func setState(_ s: State) { lock.lock(); state = s; lock.unlock() }

    private func handle(_ ev: DemuxEvent) {
        switch ev {
        case .trackAdded(let t), .trackUpdated(let t):
            tracks[t.trackID] = t
            lock.lock()
            if firstTrackAt == nil { firstTrackAt = Date() }
            if stats.firstTrackAfter == nil { stats.firstTrackAfter = Date().timeIntervalSince(born) }
            lock.unlock()
            if (t.codec == .h264 || t.codec == .hevc), video == nil || video?.info.trackID == t.trackID, video?.info != t {
                if let v = video, v.info.config == t.config {
                    video = (t, v.decoder, v.deint)          // descriptors only: nothing to rebuild
                } else if let v = video, v.decoder.adopt(t) {
                    video = (t, v.decoder, deinterlacer(for: t, reusing: v.deint))   // new parameter sets, same session
                } else if video != nil {
                    replaceDecoder(t, rejoin: true)           // keep playing; new session from the next join point
                } else {
                    setUpVideo(t)
                }
                publish()
            }
            pickAudio(switching: false)
        case .trackRemoved(let id):
            tracks[id] = nil
            pendingGeometry[id] = nil
            pickAudio(switching: true)
        case .displayChanged(let id, _, let par, let colour):
            // Applies from the first picture of the new state, which follows
            // in decode order; the decode worker is serial, so taking it
            // there keeps pictures already submitted on the old geometry.
            if id == video?.info.trackID { pendingGeometry[id] = Geometry(pixelAspect: par, colour: colour) }
        case .discontinuity(let track):
            // A gap on one audio PID is that track's problem; only a video
            // (or stream-wide) discontinuity invalidates the timeline.
            if track == nil || track == video?.info.trackID { restart(newTimeline: true) }
        case .sample(let s):
            if s.trackID == video?.info.trackID { videoSample(s) } else if s.trackID == audio?.info.trackID { audioSample(s) }
        }
    }

    /// Choose the audio track: the viewer's choice if it is on the channel,
    /// else the automatic pick. `switching`: a change while playing swaps the
    /// audio renderer (queued audio of the old track is dropped).
    private func pickAudio(switching: Bool) {
        let audios = tracks.values.filter { [.aac, .ac3, .eac3, .mpegAudio].contains($0.codec) }.sorted { $0.pid < $1.pid }
        let options = audios.map(AudioTrackOption.init)
        lock.lock(); pubAudioOptions = options; lock.unlock()
        let pick = audios.first { $0.trackID == chosenAudio } ?? chooseAudio(audios)
        guard let pick, audio?.info != pick else { return }
        guard let f = try? AudioSampleFactory(track: pick) else {
            log.error("audio track \(pick.trackID) (\(String(describing: pick.codec))) unusable; video-only")
            return
        }
        let wasPlaying = audio != nil && started
        if audioUnregistered { lb?.register(track: Self.lbAudio); audioUnregistered = false }
        audio = (pick, f)
        audioQ.removeAll { $0.trackID != pick.trackID }
        if wasPlaying && switching {
            renderer.flushAudio(session: session)
            audioQ.removeAll(); lastAudioEnd = nil; pendingAudioEnd = nil
        }
        lock.lock(); stats.audioTrack = pick.trackID; stats.audioTrackLabel = "\(pick.codec) \(pick.channels)ch \(pick.language)"; lock.unlock()
    }

    private func fieldOrder(_ t: TrackInfo) -> Bool { topFieldFirst?(t) ?? tff }

    private func makeDecoder(_ t: TrackInfo) -> VideoDecoding? {
        let dec: VideoDecoding
        do { dec = try factory(t) } catch { setState(.decoderBroken); return nil }
        // Frames are matched to the decoder that produced them: anything from a
        // replaced or restarted session is dropped (late VT callbacks).
        dec.onFrames = { [weak self, weak dec] frames in
            guard let self, let dec else { return }
            self.queue.async { self.videoFrames(frames, from: dec) }
        }
        dec.onError = { [weak self, weak dec] _ in
            guard let self, let dec else { return }
            self.queue.async { self.asyncDecodeFailed(from: dec) }
        }
        consecutiveDecodeErrors = 0
        return dec
    }

    /// New VT session (codec/size change, restart): the old one's frames are dropped.
    private func replaceDecoder(_ t: TrackInfo, rejoin: Bool) {
        guard let old = video, let dec = makeDecoder(t) else { return }
        old.decoder.invalidate()
        video = (t, dec, deinterlacer(for: t, reusing: old.deint))
        submittedGeometry[t.trackID] = nil
        if rejoin { videoQ = []; demux.rejoin(track: t.trackID) }
    }

    /// A new timeline (source switch, discontinuity): PTS steps back more than
    /// 1 s, or forward more than 5 s beyond the time that actually passed.
    /// Sparse pictures (a still slate sends one every 2.3 s) and catch-up
    /// bursts after a delivery gap are not jumps.
    static func isNewTimeline(ptsStep: Double, elapsed: Double) -> Bool {
        ptsStep < -1 || ptsStep > max(elapsed, 0) + 5
    }

    /// The scan can change with the parameter sets (a progressive still slate
    /// between interlaced programmes): a progressive picture held in a
    /// deinterlacer waits for a neighbour that may be seconds away.
    private func deinterlacer(for t: TrackInfo, reusing old: Deinterlacer?) -> Deinterlacer? {
        guard isInterlaced(t) else { return nil }
        return old ?? (try? Deinterlacer())
    }

    private func setUpVideo(_ t: TrackInfo) {
        guard let dec = makeDecoder(t) else { return }
        video = (t, dec, deinterlacer(for: t, reusing: nil))
        submittedGeometry[t.trackID] = nil
        restart(newTimeline: false)
    }

    /// Back to start-up: flush the screen, new decoder session, wait for the
    /// next join point. `newTimeline` (discontinuity / PTS jump) also drops
    /// queued audio, which belongs to the old timeline.
    private func restart(newTimeline: Bool) {
        if started { lock.lock(); stats.restarts += 1; lock.unlock() }
        renderer.flush(session: session)
        if let v = video { replaceDecoder(v.info, rejoin: true) }
        video?.deint?.reset()
        if newTimeline { audioQ = [] }
        startPTS = nil; lastVideoPTS = nil; lastVideoAt = nil; videoQ = []; bufferedVideo = []
        if newTimeline { lastAudioEnd = nil }
        started = false; paused = false; holdAt = .invalid; startAllowed = false
        pendingVideoEnd = nil; pendingAudioEnd = nil
        if newTimeline { lb?.hint(.pcrDiscontinuity) }
        lock.lock(); pubLastEnqueuedVideoSeconds = nil; lock.unlock()
        publish()
        setState(.starting)
    }

    private func videoSample(_ s: MediaSample) {
        guard let v = video else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        if let last = lastVideoPTS, let at = lastVideoAt,
           Self.isNewTimeline(ptsStep: Double(s.pts - last) / Double(v.info.timescale), elapsed: now - at) {
            restart(newTimeline: true)
            return
        }
        lastVideoAt = now
        // Join decisions come from transmux's LiveJoin (R4).
        switch s.join {
        case .dropBeforeRAP, .dropNotSelfContained:
            lock.lock(); stats.framesDroppedBeforeRAP += 1; lock.unlock(); return
        case .dropLeading:
            lock.lock(); stats.leadingPictures += 1; lock.unlock(); return
        case .joinPoint:
            if startPTS == nil {
                startPTS = s.pts; joinedAt = Date()
                // No audio chosen by the video join point: play video-only now
                // rather than wait out live-buffer's silence timeout.
                if audio == nil { lb?.unregister(track: Self.lbAudio); audioUnregistered = true }
                // live-buffer takes the first reported position as the start
                // origin: report the join point first (zero-length), before
                // any audio, so the lead is counted from where playback starts.
                lb?.media(track: Self.lbVideo, end: videoTime(s.pts))
            }
            lock.lock(); if stats.joinPointAfter == nil { stats.joinPointAfter = Date().timeIntervalSince(born) }; lock.unlock()
        case .keep:
            guard startPTS != nil else { lock.lock(); stats.framesDroppedBeforeRAP += 1; lock.unlock(); return }
        }
        if let b = s.bottomFieldFirst { tff = !b }
        lastVideoPTS = max(lastVideoPTS ?? s.pts, s.pts)
        publish()
        videoQ.append(s)
        if let last = lastVideoPTS { pendingVideoEnd = videoTime(last + Int64(s.duration)) }
    }

    /// Hand queued samples to the decode worker while the decode window (from
    /// the clock to decodeAhead past it) is not full. Frames still queued,
    /// being decoded, or decoded but not yet through the output callback
    /// count against it just like delivered frames, so the pipeline never
    /// decodes more than decodeAhead ahead, however fast frames come back.
    private func decodeQueued() {
        guard !aborted, let v = video, let clock = clockTime() else { return }
        let ahead = CMTime(seconds: policy.decodeAhead, preferredTimescale: 90000)
        let window = clock + ahead
        let later = clock + ahead + CMTime(seconds: Double(PlayerController.decodeAheadJumpFrames) / PlayerController.decodeAheadNominalFPS, preferredTimescale: 90000)
        var room = PlayerController.decodeAheadToleranceFrames - decodedQ.count - inFlightFrames(v.decoder)
        // Only new timelines, never every surplus frame: a backlog far beyond
        // decodeAhead (decoder stalled for a while) must be worked off.
        var skipped = 0
        while !aborted, room > 0 || skipped < PlayerController.decodeAheadJumpFrames {
            if room > 0, let s = videoQ.first, videoTime(s.dts) < window {
                videoQ.removeFirst()
                decodedQ.append(s)
                room -= 1
                continue
            }
            // The decode window ends later on: samples past it wait unused.
            guard let s = videoQ.first, videoTime(s.dts) >= later else { break }
            videoQ.removeFirst()
            lock.lock(); stats.framesDropped += 1; lock.unlock()
            skipped += 1
        }
        guard !decodedQ.isEmpty else { return }
        let batch = decodedQ
        decodedQ = []
        let ep = epoch
        let geometry = pendingGeometry[v.info.trackID]
        pendingGeometry[v.info.trackID] = nil
        let trackID = v.info.trackID, timescale = v.info.timescale
        decoderLock.lock(); currentDecoder = v.decoder; decoderLock.unlock()
        decodeWorker.async {
            self.decodeBatch(batch, track: trackID, timescale: Int32(timescale), with: v.decoder, epoch: ep, geometry: geometry)
        }
    }

    /// On the decode worker: in DTS order, one call at a time.
    private func decodeBatch(_ batch: [MediaSample], track: UInt32, timescale: Int32, with dec: VideoDecoding,
                             epoch ep: Int, geometry: Geometry?) {
        if let geometry, let d = dec as? VideoDecoder {
            d.apply(pixelAspect: geometry.pixelAspect, colour: geometry.colour)
            submittedGeometry[track] = geometry
        }
        for s in batch {
            // A restart (new timeline, decoder replacement) has superseded this batch.
            guard currentEpoch == ep else { return }
            if let d = dec as? VideoDecoder { applyGeometry(of: s, track: track, timescale: timescale, to: d) }
            // Calls do not block the pipeline queue, but a hung decoder must not
            // pile the queue up either: leave the rest to the next pump.
            if let d = dec as? VideoDecoder, d.inFlight >= Self.maxDecoderInFlight { return }
            let t0 = CACurrentMediaTime()
            let st = dec.decode(s)
            let dt = CACurrentMediaTime() - t0
            lock.lock()
            if dt > stats.maxDecodeCall { stats.maxDecodeCall = dt }
            lock.unlock()
            if st != noErr { queue.async { self.decodeFailed() } }
        }
    }

    private static let maxDecoderInFlight = 4

    /// A sample carries the display state in force for it (the picture's own,
    /// else the track's static geometry): hand it to the decoder before this
    /// picture is submitted. Only on the decode worker.
    private func applyGeometry(of s: MediaSample, track: UInt32, timescale: Int32, to d: VideoDecoder) {
        let (par, colour) = (s.pixelAspect ?? tracks[s.trackID]?.pixelAspect, s.colour ?? tracks[s.trackID]?.colour)
        let g = Self.Geometry(pixelAspect: par, colour: colour)
        guard submittedGeometry[s.trackID] != g else { return }
        submittedGeometry[s.trackID] = g
        d.apply(pixelAspect: par, colour: colour)
    }

    private func decodeFailed() {
        lock.lock(); stats.framesDropped += 1; lock.unlock()
        decoderFailures = decoderFailures.filter { Date().timeIntervalSince($0) < 10 } + [Date()]
        if decoderFailures.count >= policy.decoderFailuresBeforeReconnect { setState(.decoderBroken) }
    }

    private var currentEpoch: Int { decoderLock.lock(); defer { decoderLock.unlock() }; return epochSnapshot }

    /// Submitted to the decoder and not back yet.
    private func inFlightFrames(_ dec: VideoDecoding) -> Int {
        decoderLock.lock(); defer { decoderLock.unlock() }
        return currentDecoder === dec ? (dec as? VideoDecoder)?.inFlight ?? 0 : 0
    }

    private func asyncDecodeFailed(from dec: VideoDecoding) {
        guard !aborted, let v = video, v.decoder === dec else { return }
        lock.lock(); stats.framesDropped += 1; lock.unlock()
        consecutiveDecodeErrors += 1
        if consecutiveDecodeErrors >= policy.consecutiveDecodeErrorsBeforeReconnect { setState(.decoderBroken) }
    }

    private func videoFrames(_ frames: [DecodedFrame], from dec: VideoDecoding) {
        guard !aborted, let v = video, v.decoder === dec else { return }
        consecutiveDecodeErrors = 0
        let hw = dec.usingHardware
        lock.lock(); stats.framesDecoded += frames.count; stats.hardwareDecode = hw; lock.unlock()
        var out: [DecodedFrame] = []
        if let d = v.deint {
            let field = CMTime(value: 1, timescale: 50)   // one field of 25i/50 Hz
            let order = fieldOrder(v.info)
            for f in frames { out += d.push(f, topFieldFirst: order, fieldDuration: field) }
            lock.lock(); stats.maxDeintWait = d.maxWaitSeconds; stats.maxDeintGPU = d.maxGPUSeconds; lock.unlock()
        } else {
            out = frames
        }
        noteOutputFrames(out)
        if started {
            for f in out { renderer.enqueueVideo(f, session: session) }
            lock.lock(); stats.framesEnqueued += out.count
            if let l = out.last { pubLastEnqueuedVideoSeconds = CMTimeGetSeconds(l.pts) }
            lock.unlock()
        } else {
            bufferedVideo += out
            maybeStart()
        }
    }

    private var outputPTS: [CMTime] = []

    /// Median PTS step of the first output frames -> frames per second.
    private func noteOutputFrames(_ frames: [DecodedFrame]) {
        guard outputPTS.count < 25 else { return }
        outputPTS += frames.map(\.pts)
        guard outputPTS.count >= 25 else { return }
        let steps = zip(outputPTS.dropFirst(), outputPTS).map { CMTimeGetSeconds($0 - $1) }.filter { $0 > 0 }.sorted()
        guard !steps.isEmpty else { return }
        let fps = 1 / steps[steps.count / 2]
        lock.lock(); stats.outputFrameRate = (fps * 100).rounded() / 100; lock.unlock()
    }

    /// Audio and video tracks have different timescales (48 kHz vs 90 kHz):
    /// compare as CMTime, never as raw ticks.
    private func audioTime(_ s: MediaSample) -> CMTime {
        CMTime(value: s.pts, timescale: audio?.info.timescale ?? 90000)
    }

    private func audioSample(_ s: MediaSample) {
        guard !aborted, let a = audio else { return }
        audioQ.append(s)
        let end = audioTime(s) + CMTime(value: CMTimeValue(s.duration), timescale: a.info.timescale)
        lastAudioEnd = max(lastAudioEnd ?? end, end)
        publish()
        // Audio before the video join point would anchor the start origin too
        // early (it arrives first in the mux) and eat the audio cushion.
        if let e = lastAudioEnd, let s0 = startPTS, e > videoTime(s0) { pendingAudioEnd = e }
        if !started {
            // Keep at most ~10 s; abs() so a backwards timeline can't pin it.
            while let first = audioQ.first, audioQ.count > 1,
                  abs(CMTimeGetSeconds(audioTime(s) - audioTime(first))) > 10 { audioQ.removeFirst() }
        }
    }

    // MARK: pump

    private func videoTime(_ v: Int64) -> CMTime { CMTime(value: v, timescale: video?.info.timescale ?? 90000) }

    /// The position the decode/audio windows are measured from: the start
    /// point before the first start, then the renderer clock (frozen while paused).
    private func clockTime() -> CMTime? {
        if started { return paused ? holdAt : renderer.currentTime }
        return startPTS.map(videoTime)
    }

    /// End of the buffered media: video, and audio too once the selected track
    /// has delivered anything. TS muxes send video ahead of its time and audio
    /// close to real time, so judging the buffer on video alone starts (and
    /// resumes) before the audio for that moment has arrived: on bfm-tv every
    /// audio buffer then arrived after its play time, i.e. no sound at all.
    private func mediaEnd() -> CMTime? {
        guard let v = lastVideoPTS.map(videoTime) else { return nil }
        guard audio != nil, let a = lastAudioEnd, !audioWaitExpired else { return v }
        return min(v, a)
    }

    /// The selected audio track has sent nothing for a while after the video
    /// join: start video-only rather than wait for it forever.
    private var audioWaitExpired: Bool {
        guard lastAudioEnd == nil, let j = joinedAt else { return lastAudioEnd == nil }
        return Date().timeIntervalSince(j) > 3
    }
    private var joinedAt: Date?

    private func reportMediaEnds() {
        if let v = pendingVideoEnd { lb?.media(track: Self.lbVideo, end: v); pendingVideoEnd = nil }
        if let a = pendingAudioEnd { lb?.media(track: Self.lbAudio, end: a); pendingAudioEnd = nil }
    }

    private func pump() {
        // 1. Decode video up to decodeAhead past the clock (decode order, so DTS).
        if video != nil { decodeQueued() }
        guard !aborted, let clock = clockTime() else { return }
        // 2. Audio up to audioAhead past the clock.
        if started { feedAudio(upTo: clock + CMTime(seconds: policy.audioAhead, preferredTimescale: 90000)) }
        // 3. Buffer decisions: live-buffer's.
        lb?.tick(playback: started ? clock : nil)
        for d in lb?.decisions() ?? [] { apply(d) }
        if !started { maybeStart() }
    }

    private func apply(_ d: LiveBuffer.Decision) {
        switch d {
        case .start:
            startAllowed = true
        case .pause(let hold, let track):
            guard started, !paused, policy.rebufferOnStarvation else { return }
            holdAt = hold
            paused = true
            renderer.pause(at: hold, session: session)
            lock.lock()
            stats.rebuffers += 1
            let age = lastChunkAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if age > 0.25 { stats.starvedNoData += 1 } else { stats.starvedWithData += 1 }
            if track == Self.lbAudio { stats.starvedOnAudio += 1 }
            if let l = lb?.stats, let c = clockTime() {
                stats.lastPauseInfo = (stats.lastPauseInfo.map { $0 + " | " } ?? "") + "t+\(String(format: "%.1f", Date().timeIntervalSince(born)))s pause at \(String(format: "%.3f", CMTimeGetSeconds(c))) lead \(l.leadUs / 1000) ms target \(l.targetUs / 1000) ms track \(track.map(String.init) ?? "-") video_end \(lastVideoPTS.map { String(format: "%.3f", CMTimeGetSeconds(videoTime($0))) } ?? "-") audio_end \(lastAudioEnd.map { String(format: "%.3f", CMTimeGetSeconds($0)) } ?? "-")"
            }
            state = .starved
            lock.unlock()
        case .resume(let at):
            // After a restart (discontinuity) the controller resumes rather than
            // starting afresh: that opens the start gate for the new timeline.
            guard started else { startAllowed = true; return }
            guard paused else { return }
            paused = false
            holdAt = at
            renderer.resume(at: at, session: session)
            setState(.running)
            if let l = lb?.stats {
                lock.lock()
                stats.lastPauseInfo = (stats.lastPauseInfo ?? "") + " -> resume at \(String(format: "%.3f", CMTimeGetSeconds(at))) lead \(l.leadUs / 1000) ms target \(l.targetUs / 1000) ms video_end \(lastVideoPTS.map { String(format: "%.3f", CMTimeGetSeconds(videoTime($0))) } ?? "-") audio_end \(lastAudioEnd.map { String(format: "%.3f", CMTimeGetSeconds($0)) } ?? "-")"
                lock.unlock()
            }
        }
    }

    private func feedAudio(upTo limit: CMTime) {
        guard let a = audio else { return }
        let clock = clockTime()
        while let s = audioQ.first, audioTime(s) < limit {
            audioQ.removeFirst()
            guard let sb = a.factory.make(s) else { continue }
            if let clock, started, !paused {
                let lead = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb) + CMSampleBufferGetDuration(sb) - clock)
                lock.lock()
                stats.minAudioLeadSeconds = min(stats.minAudioLeadSeconds ?? lead, lead)
                if lead < 0 { stats.audioLateBuffers += 1 }
                lock.unlock()
            }
            renderer.enqueueAudio(sb, session: session)
            if renderer.audioFailed {
                log.error("audio renderer failed; continuing video-only")
                audio = nil
                audioQ = []
                lock.lock(); stats.audioTrack = nil; lock.unlock()
                return
            }
        }
    }

    private func maybeStart() {
        // live-buffer decides when the buffer (min over video and audio) is deep enough.
        guard !aborted, !started, startAllowed, startPTS != nil, let first = bufferedVideo.first else { return }
        for f in bufferedVideo { renderer.enqueueVideo(f, session: session) }
        var firstAudio: CMTime?
        if let a = audio {
            audioQ.removeAll { $0.trackID != a.info.trackID }
            // Frames can be long (8 kHz AAC: 128 ms). The one that straddles the
            // first picture is queued too, trimmed so sound starts with the picture.
            let limit = first.pts + CMTime(seconds: policy.audioAhead, preferredTimescale: 90000)
            while let e = audioQ.first, audioTime(e) < limit {
                audioQ.removeFirst()
                let dur = CMTime(value: CMTimeValue(e.duration), timescale: a.info.timescale)
                guard audioTime(e) >= first.pts || (e.duration > 0 && audioTime(e) + dur > first.pts),
                      let sb = a.factory.make(e) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                if pts < first.pts {
                    let trim = first.pts - pts
                    CMSetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                                    value: CMTimeCopyAsDictionary(trim, allocator: nil), attachmentMode: kCMAttachmentMode_ShouldPropagate)
                }
                firstAudio = firstAudio ?? max(pts, first.pts)
                renderer.enqueueAudio(sb, session: session)
            }
        }
        lock.lock()
        stats.framesEnqueued += bufferedVideo.count
        pubLastEnqueuedVideoSeconds = bufferedVideo.last.map { CMTimeGetSeconds($0.pts) }
        if stats.firstFrameAfter == nil { stats.firstFrameAfter = Date().timeIntervalSince(born) }
        if let firstAudio { stats.avOffset = CMTimeGetSeconds(firstAudio - first.pts) }
        lock.unlock()
        bufferedVideo = []
        renderer.start(at: first.pts, session: session)
        started = true
        publish()
        setState(.running)
    }
}
