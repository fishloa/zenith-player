import AVFoundation
import Foundation
import ZenithMedia

/// `-syncgap <fixture-id>`: what does AVSampleBufferRenderSynchronizer do across
/// a delivery gap when the player does NOT re-buffer? Plays the fixture paced
/// in real time, stops delivery for 1.5 s after 4 s, then continues; samples the
/// synchronizer rate/time and each renderer's readiness every 20 ms.
@MainActor
enum SyncGapExperiment {
    static func run(id: String, log: (String) -> Void) async {
        let url = Bundle.main.resourceURL!.appendingPathComponent("Fixtures/\(id).ts")
        guard let data = try? Data(contentsOf: url) else { log("SYNCGAP no fixture \(id)"); return }
        var policy = PlayerPolicy()
        // -syncgap <id> rebuffer: let the player pause/resume across the gap
        // (listening test for the stall path); default: measure Apple's behaviour.
        policy.rebufferOnStarvation = ProcessInfo.processInfo.arguments.contains("rebuffer")
        policy.stallReconnectAfter = 60
        let r = PlayerHarness.renderer
        let c = PlayerController(renderer: r, policy: policy)
        c.play { GapSource(data: data, seconds: 10, gapAt: 4, gap: 1.5) }
        log("SYNCGAP rebuffer=\(policy.rebufferOnStarvation): listen: sound 0-4 s, gap, sound again after ~6 s")
        log("SYNCGAP \(id) delays=\(r.synchronizer.delaysRateChangeUntilHasSufficientMediaData)")
        let t0 = Date()
        var last = ""
        while Date().timeIntervalSince(t0) < 9 {
            let line = String(format: "rate=%.2f clock=%.3f audioSufficient=%d videoSufficient=%d buffered=%.2f phase=%@",
                              r.synchronizer.rate, CMTimeGetSeconds(r.synchronizer.currentTime()) ,
                              r.audio.hasSufficientMediaDataForReliablePlaybackStart ? 1 : 0,
                              r.displayLayer.sampleBufferRenderer.hasSufficientMediaDataForReliablePlaybackStart ? 1 : 0,
                              c.stats.bufferedSeconds, "\(c.phase)")
            let key = line.replacingOccurrences(of: #"clock=[0-9.\-]+ "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"buffered=[0-9.]+ "#, with: "", options: .regularExpression)
            // Log every state change, plus every 0.25 s for the clock trace.
            let elapsed = Date().timeIntervalSince(t0)
            if key != last || Int(elapsed * 50) % 12 == 0 { log(String(format: "SYNCGAP t=%.2f ", elapsed) + line); last = key }
            try? await Task.sleep(for: .milliseconds(20))
        }
        c.stop()
        log("SYNCGAP DONE")
    }
}

/// Fixture paced in real time with one delivery gap.
struct GapSource: ByteSource {
    let data: Data, seconds: Double, gapAt: Double, gap: Double
    func bytes() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                let bps = Double(data.count) / seconds, chunk = 32768
                var off = 0, gapped = false
                while off < data.count, !Task.isCancelled {
                    let n = min(chunk, data.count - off)
                    cont.yield(data.subdata(in: off..<off + n)); off += n
                    try? await Task.sleep(for: .seconds(Double(n) / bps))
                    if !gapped, Double(off) / bps >= gapAt { gapped = true; try? await Task.sleep(for: .seconds(gap)) }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
