import AVFoundation
import AudioToolbox
import CryptoKit
import VideoToolbox

/// On-device decode capability probe. Every result line is printed with a
/// "PROBE " prefix so `devicectl ... --console` output can be grepped.
enum Probe {
    static func log(_ s: String, to lines: inout [String]) {
        print("PROBE " + s)
        lines.append(s)
    }

    static func run() -> [String] {
        var out: [String] = []
        log("device: \(deviceModel()) tvOS \(ProcessInfo.processInfo.operatingSystemVersionString)", to: &out)
        audioDecoders(&out)
        let dir = Bundle.main.resourceURL!.appendingPathComponent("Fixtures")
        let movs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mov" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for mov in movs {
            video(mov, &out)
            deinterlace(mov, &out)
            audio(mov, &out)
            mp2(mov, &out)
            renderer(mov, &out)
        }
        log("DONE", to: &out)
        return out
    }

    // MARK: Audio

    static func audioDecoders(_ out: inout [String]) {
        let ids: [(String, AudioFormatID)] = [
            ("aac", kAudioFormatMPEG4AAC), ("ac3", kAudioFormatAC3), ("eac3", kAudioFormatEnhancedAC3),
            ("mp2", kAudioFormatMPEGLayer2), ("mp1", kAudioFormatMPEGLayer1), ("ac4", 0x6163_2D34),
        ]
        var parts: [String] = []
        for (name, var id) in ids {
            var size: UInt32 = 0
            let st = AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, UInt32(MemoryLayout<AudioFormatID>.size), &id, &size)
            parts.append("\(name)=\(st == noErr && size > 0 ? "yes" : "no")")
        }
        log("audio-decoders " + parts.joined(separator: " "), to: &out)
    }

    /// Decode every audio track to LPCM through AVAssetReader (AudioToolbox).
    static func audio(_ url: URL, _ out: inout [String]) {
        let asset = AVURLAsset(url: url)
        for (i, track) in asset.tracks(withMediaType: .audio).enumerated() {
            let fourcc = (track.formatDescriptions.first as! CMFormatDescription?).map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
            guard let reader = try? AVAssetReader(asset: asset) else { continue }
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(o)
            reader.startReading()
            var frames = 0
            while let sb = o.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sb) }
            let err = reader.error.map { " error=\(($0 as NSError).code) \($0.localizedDescription)" } ?? ""
            log("\(url.deletingPathExtension().lastPathComponent) audio#\(i) \(fourcc) pcm_frames=\(frames) status=\(reader.status.rawValue)\(err)", to: &out)
        }
    }

    /// Bundled MP2 decoder (nanomp3-core via Rust static lib) vs ffmpeg reference PCM.
    static func mp2(_ url: URL, _ out: inout [String]) {
        let name = url.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: url)
        for (i, track) in asset.tracks(withMediaType: .audio).enumerated() {
            let refURL = url.deletingLastPathComponent().appendingPathComponent("\(name).a\(i).s16")
            guard let refData = try? Data(contentsOf: refURL) else { continue }
            guard let r = try? AVAssetReader(asset: asset) else { continue }
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            r.add(o); r.startReading()
            var es = Data()
            while let sb = o.copyNextSampleBuffer() {
                guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
                var d = Data(count: CMBlockBufferGetDataLength(bb))
                _ = d.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                es.append(d)
            }
            var pcm = [Int16](repeating: 0, count: 48000 * 2 * 30)
            var nch: UInt32 = 0, ly: UInt32 = 0, fr: UInt32 = 0
            let t0 = CFAbsoluteTimeGetCurrent()
            let n = es.withUnsafeBytes { src in
                pcm.withUnsafeMutableBufferPointer { dst in
                    probe_mpa_decode(src.bindMemory(to: UInt8.self).baseAddress, src.count, dst.baseAddress, dst.count, &nch, &ly, &fr)
                }
            }
            pcm.removeSubrange(max(n, 0)...)
            let channels = Int(nch), layer = Int(ly), frames = Int(fr)
            let secs = CFAbsoluteTimeGetCurrent() - t0
            let ref = refData.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            // Align (decoders may differ by a frame of priming), then SNR.
            var best = (lag: 0, snr: -Double.infinity, maxd: 0)
            let ch = max(channels, 1)
            for lag in stride(from: -1152 * ch, through: 1152 * ch, by: ch) {
                let a0 = max(0, lag), b0 = max(0, -lag)
                let n = min(pcm.count - a0, ref.count - b0)
                if n < 48000 { continue }
                var sig = 0.0, err = 0.0, maxd = 0
                for k in stride(from: 0, to: n, by: 7) {   // subsample for the search
                    let a = Int(pcm[a0 + k]), b = Int(ref[b0 + k]); let e = a - b
                    sig += Double(b * b); err += Double(e * e); maxd = max(maxd, abs(e))
                }
                let snr = err == 0 ? 200 : 10 * log10(sig / err)
                if snr > best.snr { best = (lag / ch, snr, maxd) }
            }
            let lpcm = renderLPCM(pcm, channels: channels, rate: 48000)
            log(String(format: "%@ audio#%d mp2(nanomp3) -> LPCM renderer: %@", name, i, lpcm), to: &out)
            log(String(format: "%@ audio#%d mp2(nanomp3): layer=%d ch=%d frames=%d pcm=%d ref=%d lag=%d snr=%.1fdB maxdiff=%d decode=%.3fs",
                       name, i, layer, channels, frames, pcm.count, ref.count, best.lag, best.snr, best.maxd, secs), to: &out)
        }
    }

    /// Feed decoded s16 PCM to AVSampleBufferAudioRenderer (the in-app MP2 path).
    static func renderLPCM(_ pcm: [Int16], channels: Int, rate: Double) -> String {
        guard channels > 0, !pcm.isEmpty else { return "no pcm" }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1,
                                               mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 16, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        guard let fd else { return "fmt failed" }
        let rend = AVSampleBufferAudioRenderer()
        rend.isMuted = true
        let sync = AVSampleBufferRenderSynchronizer()
        sync.addRenderer(rend)
        let chunk = 1152 * channels
        var pos = 0
        while pos < pcm.count {
            let n = min(chunk, pcm.count - pos)
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 2, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: n * 2, flags: 0, blockBufferOut: &bb)
            guard let bb else { break }
            _ = pcm[pos..<(pos + n)].withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: n * 2) }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: fd,
                                                                 sampleCount: n / channels,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(pos / channels), timescale: CMTimeScale(rate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
            if let sb { rend.enqueue(sb) }
            pos += n
        }
        sync.setRate(1, time: .zero)
        Thread.sleep(forTimeInterval: 1.5)
        let played = CMTimeGetSeconds(sync.currentTime())
        let err = rend.error.map { " error=\(($0 as NSError).code)" } ?? ""
        sync.setRate(0, time: .zero); rend.flush(); sync.removeRenderer(rend, at: .zero)
        return String(format: "status=%d played=%.2fs%@", rend.status.rawValue, played, err)
    }

    /// Can the system audio renderer take each compressed track directly?
    /// (AC-3/E-AC-3 passthrough to HDMI/eARC, no decode in-app.)
    static func renderer(_ url: URL, _ out: inout [String]) {
        let name = url.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: url)
        for (i, track) in asset.tracks(withMediaType: .audio).enumerated() {
            guard let r = try? AVAssetReader(asset: asset) else { continue }
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            r.add(o); r.startReading()
            var sbs: [CMSampleBuffer] = []
            while let sb = o.copyNextSampleBuffer() { sbs.append(sb) }
            guard let first = sbs.first, let fd = CMSampleBufferGetFormatDescription(first) else {
                log("\(name) audio#\(i) renderer: no samples (reader status \(r.status.rawValue) \(r.error.map { "\($0)" } ?? ""))", to: &out); continue
            }
            let rend = AVSampleBufferAudioRenderer()
            rend.isMuted = true
            let sync = AVSampleBufferRenderSynchronizer()
            sync.addRenderer(rend)
            for sb in sbs { rend.enqueue(sb) }
            let start = CMSampleBufferGetPresentationTimeStamp(first)
            sync.setRate(1, time: start)
            Thread.sleep(forTimeInterval: 1.5)
            let played = CMTimeGetSeconds(CMTimeSubtract(sync.currentTime(), start))
            let err = rend.error.map { " error=\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? ""
            log(String(format: "%@ audio#%d %@ renderer: status=%d played=%.2fs%@", name, i,
                       fourCC(CMFormatDescriptionGetMediaSubType(fd)), rend.status.rawValue, played, err), to: &out)
            sync.setRate(0, time: .zero)
            rend.flush()
            sync.removeRenderer(rend, at: .zero)
        }
    }

    /// Does VideoToolbox's own deinterlacer work on the software decoder?
    /// Comb = mean |Y(2k)-Y(2k+1)| / mean |Y(2k)-Y(2k+2)| over frames 100..109:
    /// ~1 for a clean frame, >1 when fields from different instants interleave.
    static func deinterlace(_ url: URL, _ out: inout [String]) {
        let name = url.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let fd = track.formatDescriptions.first.map({ $0 as! CMVideoFormatDescription }),
              CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_H264 else { return }
        let fields = readSamples(asset, track)
        let samples = pairFields(fields).count < fields.count ? pairFields(fields) : fields
        let configs: [(String, [CFString: CFString])] = [
            ("none", [:]),
            ("fieldsDeinterlace", [kVTDecompressionPropertyKey_FieldMode: kVTDecompressionProperty_FieldMode_DeinterlaceFields]),
            ("temporal", [kVTDecompressionPropertyKey_FieldMode: kVTDecompressionProperty_FieldMode_DeinterlaceFields,
                          kVTDecompressionPropertyKey_DeinterlaceMode: kVTDecompressionProperty_DeinterlaceMode_Temporal]),
            ("vertical", [kVTDecompressionPropertyKey_FieldMode: kVTDecompressionProperty_FieldMode_DeinterlaceFields,
                          kVTDecompressionPropertyKey_DeinterlaceMode: kVTDecompressionProperty_DeinterlaceMode_VerticalFilter]),
        ]
        for (label, props) in configs {
            var session: VTDecompressionSession?
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                               imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                               decompressionSessionOut: &session) == noErr, let s = session else { continue }
            var supported: CFDictionary?
            VTSessionCopySupportedPropertyDictionary(s, supportedPropertyDictionaryOut: &supported)
            let sup = (supported as? [String: Any]) ?? [:]
            let has = "fieldMode=\(sup[kVTDecompressionPropertyKey_FieldMode as String] != nil) deintMode=\(sup[kVTDecompressionPropertyKey_DeinterlaceMode as String] != nil)"
            var sets: [String] = []
            for (k, v) in props { sets.append("\(VTSessionSetProperty(s, key: k, value: v))") }
            var outputs = 0, w = 0, h = 0, combSum = 0.0, combN = 0
            for sb in samples {
                VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { st, _, img, _, _ in
                    guard st == noErr, let img else { return }
                    outputs += 1; w = CVPixelBufferGetWidth(img); h = CVPixelBufferGetHeight(img)
                    if outputs >= 100 && outputs < 110 { combSum += comb(img); combN += 1 }
                }
            }
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            log(String(format: "%@ deint %@: %@ set=[%@] in=%d out=%d %dx%d comb=%.2f", name, label, has,
                       sets.joined(separator: ","), samples.count, outputs, w, h, combN > 0 ? combSum / Double(combN) : 0), to: &out)
        }
    }

    static func comb(_ px: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let w = CVPixelBufferGetWidthOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0)
        var adj = 0, same = 0
        for r in stride(from: 0, to: h - 2, by: 2) {
            for x in stride(from: 0, to: w, by: 4) {
                let a = Int(y[r * ys + x]), b = Int(y[(r + 1) * ys + x]), c = Int(y[(r + 2) * ys + x])
                adj += abs(a - b); same += abs(a - c)
            }
        }
        return Double(adj) / Double(max(same, 1))
    }

    // MARK: Video

    static func video(_ url: URL, _ out: inout [String]) {
        let name = url.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let fd = track.formatDescriptions.first.map({ $0 as! CMVideoFormatDescription }) else {
            log("\(name) video: no track", to: &out); return
        }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let refs = Set((try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("md5"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? [])
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))

        let fieldSamples = readSamples(asset, track)
        let pairedSamples = pairFields(fieldSamples)
        for mode in ["default", "requireHW", "forceSW", "paired"] {
            // "paired": both fields of a field-coded frame in one sample, as a
            // TS demuxer would hand them over if it grouped PES by frame.
            if mode == "paired" && pairedSamples.count == fieldSamples.count { continue }
            var spec: [CFString: Any] = [:]
            if mode == "requireHW" { spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true }
            if mode == "forceSW" { spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = false }
            var session: VTDecompressionSession?
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &session)
            guard st == noErr, let s = session else {
                log("\(name) \(codec) \(dims.width)x\(dims.height) \(mode): create failed \(st)", to: &out); continue
            }
            var hw: CFBoolean?
            VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hw)

            // Pass 1: timing only (async, no hashing).
            let samples = mode == "paired" ? pairedSamples : fieldSamples
            var ok = 0, bad = 0
            let lock = NSLock()
            let t0 = CFAbsoluteTimeGetCurrent()
            for sb in samples {
                VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, img, _, _ in
                    lock.lock(); if status == noErr && img != nil { ok += 1 } else { bad += 1 }; lock.unlock()
                }
            }
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            let secs = CFAbsoluteTimeGetCurrent() - t0
            let mediaSecs = CMTimeGetSeconds(asset.duration)

            // Pass 2: bit-exactness vs ffmpeg reference (sync, hash every output).
            var matched = 0, hashed = 0
            var pattern = ""  // per output in decode order: M = matches a reference frame
            VTDecompressionSessionInvalidate(s)
            var s2: VTDecompressionSession?
            VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec as CFDictionary,
                                         imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s2)
            if let s2 {
                for sb in samples {
                    VTDecompressionSessionDecodeFrame(s2, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
                        guard status == noErr, let img else { return }
                        hashed += 1
                        let hit = refs.contains(i420MD5(img, Int(dims.width), Int(dims.height)))
                        if hit { matched += 1 }
                        if pattern.count < 24 { pattern += hit ? "M" : "." }
                    }
                }
                VTDecompressionSessionWaitForAsynchronousFrames(s2)
                VTDecompressionSessionInvalidate(s2)
            }
            log(String(format: "%@ %@ %dx%d %@: usingHW=%@ samples=%d ok=%d bad=%d decode=%.2fs media=%.2fs realtime=%.1fx bitexact=%d/%d (ref %d) pattern=%@",
                       name, codec, dims.width, dims.height, mode, hw.map { CFBooleanGetValue($0) ? "yes" : "no" } ?? "nil",
                       samples.count, ok, bad, secs, mediaSecs, mediaSecs / max(secs, 0.001), matched, hashed, refs.count, pattern), to: &out)
        }
    }

    static func readSamples(_ asset: AVAsset, _ track: AVAssetTrack) -> [CMSampleBuffer] {
        guard let r = try? AVAssetReader(asset: asset) else { return [] }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        r.add(o); r.startReading()
        var v: [CMSampleBuffer] = []
        while let sb = o.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sb) > 0 { v.append(sb) }
        }
        return v
    }

    /// Merge field pairs: a sample whose successor is presented exactly half a
    /// frame later is the first field; concatenate both into one sample.
    static func pairFields(_ v: [CMSampleBuffer]) -> [CMSampleBuffer] {
        var out: [CMSampleBuffer] = []
        var i = 0
        while i < v.count {
            let a = v[i]
            if i + 1 < v.count {
                let b = v[i + 1]
                let d = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(b)) - CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(a))
                let half = CMTimeGetSeconds(CMSampleBufferGetDuration(a))
                if half > 0, abs(d - half) < 0.001, let m = concat(a, b) { out.append(m); i += 2; continue }
            }
            out.append(a); i += 1
        }
        return out
    }

    static func concat(_ a: CMSampleBuffer, _ b: CMSampleBuffer) -> CMSampleBuffer? {
        func bytes(_ sb: CMSampleBuffer) -> Data? {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
            var d = Data(count: CMBlockBufferGetDataLength(bb))
            let st = d.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            return st == noErr ? d : nil
        }
        guard var d = bytes(a), let db = bytes(b) else { return nil }
        d.append(db)
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: d.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: d.count, flags: 0,
                                                 blockBufferOut: &bb) == noErr, let bb else { return nil }
        _ = d.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: d.count) }
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(a, at: 0, timingInfoOut: &timing)
        timing.duration = CMTimeMultiply(timing.duration, multiplier: 2)
        var size = d.count
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: CMSampleBufferGetFormatDescription(a),
                                  sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                  sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        return sb
    }

    /// MD5 of the frame as planar yuv420p (Y, then U, then V), cropped to
    /// width×height — the same bytes ffmpeg's framemd5 hashes.
    static func i420MD5(_ px: CVPixelBuffer, _ w: Int, _ h: Int) -> String {
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        var md5 = Insecure.MD5()
        let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        for r in 0..<h { md5.update(bufferPointer: UnsafeRawBufferPointer(start: y + r * ys, count: w)) }
        let c = CVPixelBufferGetBaseAddressOfPlane(px, 1)!.assumingMemoryBound(to: UInt8.self)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(px, 1)
        var row = [UInt8](repeating: 0, count: w / 2)
        for plane in 0..<2 {
            for r in 0..<(h / 2) {
                let base = c + r * cs
                for x in 0..<(w / 2) { row[x] = base[2 * x + plane] }
                row.withUnsafeBytes { md5.update(bufferPointer: $0) }
            }
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .ascii) ?? "\(v)"
    }

    static func deviceModel() -> String {
        var s = utsname(); uname(&s)
        return withUnsafeBytes(of: &s.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
