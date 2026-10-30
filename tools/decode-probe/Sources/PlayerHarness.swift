import CoreMedia
import Foundation
import ZenithMedia

/// Plays every bundled TS fixture through the real pipeline at realtime pace
/// and checks the spec's on-device thresholds.
@MainActor
enum PlayerHarness {
    static let renderer = Renderer()

    static func run(log: (String) -> Void) async {
        let dir = Bundle.main.resourceURL!.appendingPathComponent("Fixtures")
        let manifest = (try? String(contentsOf: dir.appendingPathComponent("manifest.tsv"), encoding: .utf8)) ?? ""
        // manifest.tsv: id, ext, "codec,width,height,field_order", audio, frames=, start...
        var fieldOrder: [String: String] = [:]
        for line in manifest.split(separator: "\n") {
            let cols = line.split(separator: "\t").map(String.init)
            if cols.count > 2 { fieldOrder[cols[0]] = cols[2].split(separator: ",").last.map(String.init) ?? "progressive" }
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ts" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let id = url.deletingPathExtension().lastPathComponent
            let order = fieldOrder[id] ?? "progressive"
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            // Production defaults: interlace, field order, audio track and live
            // join all come from transmux; the manifest only labels the output.
            let c = PlayerController(renderer: renderer)
            let t0 = Date()
            c.play { FileByteSource(url: url, bytesPerSecond: size / 10) }   // fixtures are 10 s
            try? await Task.sleep(for: .seconds(9))
            let s = c.stats
            let stopStart = Date()
            c.stop()
            let stopTime = Date().timeIntervalSince(stopStart)
            // framesDropped includes VideoToolbox's asynchronous failures: one is
            // allowed (VT rejects a B-picture after some recovery-point joins, #1169).
            let pass = s.framesDropped <= 1 && abs(s.avOffset) <= 0.040 && s.audioFlushes == 0
                && (s.firstFrameAfter ?? 99) <= 2.5 && stopTime < 0.5 && s.restarts == 0
            log(String(format: "PLAYER %@ %@ manifest=%@ first_frame=%.2fs decoded=%d dropped=%d leading=%d before_join=%d av=%.3fs audio_flushes=%d audio=%@ restarts=%d rebuffers=%d stop=%.3fs",
                       pass ? "PASS" : "FAIL", id, order, s.firstFrameAfter ?? -1, s.framesDecoded, s.framesDropped,
                       s.leadingPictures, s.framesDroppedBeforeRAP, s.avOffset, s.audioFlushes,
                       s.audioTrackLabel ?? "none", s.restarts, s.rebuffers, stopTime))
        }
        log("PLAYER DONE")
    }
}

/// Live soak: every channel in the server playlist through the real
/// pipeline for `seconds` each (spec: 60 s), on the device.
@MainActor
enum LiveSoak {
    static func run(seconds: Int, log: (String) -> Void) async {
        // -playlist <url>: the server playlist (run-on-device.sh passes $ZENITH_URL).
        let argv = ProcessInfo.processInfo.arguments
        guard let p = argv.firstIndex(of: "-playlist"), argv.indices.contains(p + 1),
              let list = URL(string: argv[p + 1]),
              let (data, _) = try? await URLSession.shared.data(from: list) else { log("SOAK no playlist"); return }
        // -channels a,b,c limits the soak to those playlist ids.
        let args = ProcessInfo.processInfo.arguments
        let only = args.firstIndex(of: "-channels").flatMap { args.indices.contains($0 + 1) ? Set(args[$0 + 1].split(separator: ",").map(String.init)) : nil }
        let urls = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map(String.init).filter { $0.hasPrefix("http") }.compactMap(URL.init(string:))
            .filter { only?.contains($0.lastPathComponent) ?? true }
        log("SOAK \(urls.count) channels × \(seconds) s")
        var passed = 0
        for url in urls {
            let id = url.lastPathComponent
            let m0 = await PlayerHarness.renderer.displayMetrics()
            let c = PlayerController(renderer: PlayerHarness.renderer)
            // -trace: phase changes (Library/Caches/traces).
            let trace = args.contains("-trace") ? ArrivalTrace(id: id) : nil
            c.play(url: url)
            var bufferingEpisodes = 0, wasBuffering = false, maxReconnect = 0
            var lastPhase = ""
            let t0 = Date()
            while Date().timeIntervalSince(t0) < Double(seconds) {
                try? await Task.sleep(for: .milliseconds(trace == nil ? 250 : 50))
                let phase = "\(c.phase)"
                if phase != lastPhase { trace?.event(phase); lastPhase = phase }
                switch c.phase {
                case .buffering: if !wasBuffering { bufferingEpisodes += 1 }; wasBuffering = true
                case .reconnecting(let n): maxReconnect = max(maxReconnect, n); wasBuffering = false
                default: wasBuffering = false
                }
            }
            let s = c.stats
            let m1 = await PlayerHarness.renderer.displayMetrics()
            let shown = (m1?.total ?? 0) - (m0?.total ?? 0), late = (m1?.dropped ?? 0) - (m0?.dropped ?? 0)
            let stopStart = Date()
            c.stop()
            trace?.write()
            let stopTime = Date().timeIntervalSince(stopStart)
            let pass = (s.firstFrameAfter ?? 99) <= 2.5 && bufferingEpisodes == 0 && maxReconnect == 0
                && s.framesDropped <= 1 && s.audioFlushes == 0 && s.audioTrack != nil && stopTime < 0.5   // dropped ≤1: see above
            if pass { passed += 1 }
            log(String(format: "SOAK %@ %@ first_frame=%.2fs buffering=%d reconnects=%d restarts=%d dropped=%d audio_flushes=%d av=%.3fs audio=%@ stop=%.3fs starved_nodata=%d starved_data=%d max_chunk_gap=%.2fs max_feed=%.3fs byte=%.2fs track=%.2fs join=%.2fs fps=%.2f hw=%@ display_frames=%d display_dropped=%d decoded=%d enqueued=%d audio_min_lead=%.2fs audio_late=%d deint_wait=%.3fs deint_gpu=%.3fs decode_call=%.3fs demux_feed=%.3fs discontinuities=%d pauses=[%@]",
                       pass ? "PASS" : "FAIL", id, s.firstFrameAfter ?? -1, bufferingEpisodes, maxReconnect, s.restarts,
                       s.framesDropped, s.audioFlushes, s.avOffset, s.audioTrackLabel ?? "none", stopTime,
                       s.starvedNoData, s.starvedWithData, s.maxChunkGap, s.maxFeedSeconds,
                       s.firstByteAfter ?? -1, s.firstTrackAfter ?? -1, s.joinPointAfter ?? -1,
                       s.outputFrameRate ?? -1, s.hardwareDecode.map { $0 ? "yes" : "no" } ?? "?", shown, late, s.framesDecoded, s.framesEnqueued,
                       s.minAudioLeadSeconds ?? -1, s.audioLateBuffers, s.maxDeintWait, s.maxDeintGPU, s.maxDecodeCall, s.maxDemuxFeed, s.discontinuities, s.lastPauseInfo ?? ""))
        }
        log("SOAK DONE \(passed)/\(urls.count) passed")
    }
}
