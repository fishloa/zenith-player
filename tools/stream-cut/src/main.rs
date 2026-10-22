//! stream-cut: trim a captured MPEG-TS so every track starts at the first
//! clean random-access point of the video track, keep `--seconds` of media,
//! and re-mux to TS. Prints a JSON summary.
//!
//! Start point: the first strict IDR (AVC nal 5) / IRAP (HEVC 16..=23). Some
//! broadcasters (TF1/M6 groups, ORF) never send IDR — open GOPs that open on
//! SPS + I-slice + recovery-point SEI. For those, fall back to the first such
//! RAP and drop the leading pictures (PTS before the RAP), which reference the
//! previous GOP and cannot decode.
//!
//! A recovery-point I is not always self-contained (M6: the first GOP after
//! it still differs); `--rap N` skips to the N-th random-access point so the
//! caller can validate and retry.
//!
//! usage: stream-cut <in.ts> <out.ts> [--seconds N] [--rap N]

use broadcast_common::{Package, Unpackage};
use transmux::ir::{CodecConfig, DegradationRecord};
use transmux::{NalCodec, TsDemux, TsMux, access_unit_is_keyframe, access_unit_is_rap};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: stream-cut <in.ts> <out.ts> [--seconds N]");
        std::process::exit(2);
    }
    let secs: f64 = args
        .iter()
        .position(|a| a == "--seconds")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(1e9);
    let rap_index: usize = args
        .iter()
        .position(|a| a == "--rap")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);

    let input = std::fs::read(&args[1]).expect("read input");
    let mut media = TsDemux::new().unpackage(&input).expect("demux");
    // transmux 0.27 resynchronises over damage and reports it instead of
    // failing: a damaged capture is no fixture, let the caller re-capture.
    // Damage that is stream-wide (no PID) or on a PID of a track we keep is
    // fatal; damage on PIDs we drop (e.g. ORF III's DSM-CC carousel, which
    // repeats packets) is only reported.
    let kept_pids: Vec<u16> = media
        .tracks
        .iter()
        .filter(|t| codec_name(&t.spec.config) != "other") // the audio/video the fixtures are about
        .filter_map(|t| t.spec.source_pid.map(|p| p.value()))
        .collect();
    let (fatal, ignored): (Vec<&DegradationRecord>, Vec<&DegradationRecord>) = media
        .degraded_at
        .iter()
        .partition(|r| r.provenance.pid.is_none_or(|p| kept_pids.contains(&p.value())));
    if !fatal.is_empty() {
        eprintln!("damaged capture: {} degraded unit(s) on kept tracks, first {:?}", fatal.len(), fatal[0]);
        std::process::exit(2);
    }
    let ignored_damage = ignored.len();

    let Some((vi, codec)) = media.tracks.iter().enumerate().find_map(|(i, t)| match t.spec.config {
        CodecConfig::Avc { .. } => Some((i, NalCodec::Avc)),
        CodecConfig::Hevc { .. } => Some((i, NalCodec::Hevc)),
        _ => None,
    }) else {
        fail("no AVC/HEVC video track");
    };

    let vts = media.tracks[vi].spec.timescale as f64;
    let vsamples = &media.tracks[vi].samples;
    let n_idr = vsamples.iter().filter(|s| access_unit_is_keyframe(codec, &s.data, true)).count();
    let n_rap = vsamples.iter().filter(|s| access_unit_is_rap(codec, &s.data, true)).count();
    // Candidates: every RAP in order (IDR or SPS + I + recovery-point SEI).
    let Some(first) = vsamples
        .iter()
        .enumerate()
        .filter(|(_, s)| access_unit_is_rap(codec, &s.data, true))
        .nth(rap_index)
        .map(|(i, _)| i)
    else {
        fail(&format!("no RAP #{rap_index} in {} video samples", vsamples.len()));
    };
    let start_kind = if access_unit_is_keyframe(codec, &vsamples[first].data, true) { "idr" } else { "recovery-point" };
    let cut_dts = vsamples[first].dts.expect("video dts") as f64 / vts; // seconds
    let cut_pts = vsamples[first].pts.expect("video pts") as f64 / vts;
    let end = cut_dts + secs;
    let mut kept = Vec::new();
    let mut leading_dropped = 0usize;
    for (ti, t) in media.tracks.iter_mut().enumerate() {
        let ts = t.spec.timescale as f64;
        let before = t.samples.len();
        let no_dts = t.samples.iter().filter(|s| s.dts.is_none()).count();
        t.samples.retain(|s| match s.dts {
            Some(d) => {
                let d = d as f64 / ts;
                let leading = ti == vi && s.pts.is_some_and(|p| (p as f64 / ts) < cut_pts);
                if d >= cut_dts && d < end && leading {
                    leading_dropped += 1;
                }
                d >= cut_dts && d < end && !leading
            }
            None => false,
        });
        kept.push(serde_json::json!({
            "track": t.spec.track_id,
            "codec": codec_name(&t.spec.config),
            "kept": t.samples.len(),
            "of": before,
            "no_dts": no_dts,
        }));
    }
    let v = &media.tracks[vi].samples;
    if v.is_empty() || !access_unit_is_rap(codec, &v[0].data, true) {
        fail("cut video does not open on a RAP");
    }

    let out = TsMux::new().package(&media).expect("mux");
    std::fs::write(&args[2], &out).expect("write output");
    println!(
        "{}",
        serde_json::json!({
            "ok": true,
            "video": if codec == NalCodec::Hevc { "hevc" } else { "h264" },
            "start": start_kind,
            "rap_index": rap_index,
            "idr_in_capture": n_idr,
            "rap_in_capture": n_rap,
            "leading_dropped": leading_dropped,
            "cut_at_s": cut_dts,
            "tracks": kept,
            "skipped": media.skipped.iter().map(|s| format!("{}: {}", s.fourcc, s.reason)).collect::<Vec<_>>(),
            "bytes": out.len(),
            "damage_on_dropped_pids": ignored_damage,
        })
    );
}

fn codec_name(c: &CodecConfig) -> &'static str {
    match c {
        CodecConfig::Avc { .. } => "h264",
        CodecConfig::Hevc { .. } => "hevc",
        CodecConfig::Ac3 { .. } => "ac3",
        CodecConfig::Eac3 { .. } => "eac3",
        CodecConfig::MpegAudio { .. } => "mpeg-audio",
        CodecConfig::Aac { .. } => "aac",
        _ => "other",
    }
}

fn fail(why: &str) -> ! {
    println!("{}", serde_json::json!({ "ok": false, "why": why }));
    std::process::exit(1);
}
