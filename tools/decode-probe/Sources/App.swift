import SwiftUI
import ZenithMedia

/// Hosts the harness renderer's display layer so decoded frames are really presented.
struct PlayerLayerHost: UIViewRepresentable {
    final class LayerView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
    func makeUIView(context: Context) -> UIView {
        let v = LayerView()
        v.backgroundColor = .black
        v.layer.addSublayer(PlayerHarness.renderer.displayLayer)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Result lines go to the console and to Library/Caches/probe.log (tvOS apps
/// cannot write Documents), so a run
/// survives the devicectl console detaching (run-on-device.sh copies the file).
enum ProbeLog {
    static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.log")
    static func reset() { try? Data().write(to: url) }
    static func emit(_ line: String) {
        print("PROBE " + line)
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile(); h.write(Data(("PROBE " + line + "\n").utf8)); try? h.close()
    }
}

@main
struct DecodeProbeApp: App {
    @State private var lines: [String] = ["running…"]

    var body: some Scene {
        WindowGroup {
            HStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 14, design: .monospaced))
                        }
                    }
                    .padding(20)
                }
                PlayerLayerHost().frame(width: 960, height: 540)
            }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true } // keep the TV awake for unattended runs
            .task {
                ProbeLog.reset()
                // -playerOnly skips the codec capability probe (faster harness runs).
                if !ProcessInfo.processInfo.arguments.contains("-playerOnly") {
                    let result = await Task.detached(priority: .userInitiated) { Probe.run() }.value
                    lines = result
                }
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-throughput"), args.indices.contains(i + 1), let u = URL(string: args[i + 1]) {
                    await Throughput.run(url: u) { line in lines.append(line); ProbeLog.emit(line) }
                } else if let i = args.firstIndex(of: "-syncgap"), args.indices.contains(i + 1) {
                    await SyncGapExperiment.run(id: args[i + 1]) { line in lines.append(line); ProbeLog.emit(line) }
                } else if let i = args.firstIndex(of: "-soak") {
                    let secs = args.indices.contains(i + 1) ? Int(args[i + 1]) ?? 60 : 60
                    await LiveSoak.run(seconds: secs) { line in lines.append(line); ProbeLog.emit(line) }
                } else {
                    await PlayerHarness.run { line in
                        lines.append(line)
                        ProbeLog.emit(line)
                    }
                }
            }
        }
    }
}
