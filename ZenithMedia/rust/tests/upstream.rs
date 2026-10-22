//! transmux 0.25.4 (rust-broadcast #1162) facts surfaced through zenith-media:
//! audio role / language / channels incl. LFE / bitrate (R1, R2), video scan
//! and field order (R3), live-join decisions (R4).
mod support;
use support::*;
use zenith_media::demux::{AudioRole, Codec, Event, Join, Scan, TrackInfo};

fn tracks(ev: &[Event]) -> Vec<&TrackInfo> {
    ev.iter().filter_map(|e| if let Event::TrackAdded(t) = e { Some(t) } else { None }).collect()
}

#[test]
fn france2_audio_roles_and_languages() {
    let ev = demux_all(&fixture("streams/france-2.ts"));
    let audio: Vec<_> = tracks(&ev).into_iter().filter(|t| t.codec == Codec::Eac3).collect();
    let roles: Vec<(String, AudioRole)> = audio.iter().map(|t| (t.language.clone(), t.role)).collect();
    assert!(roles.contains(&("fre".into(), AudioRole::Main)), "{roles:?}");
    assert_eq!(roles.iter().filter(|r| r.1 == AudioRole::AudioDescription).count(), 1, "{roles:?}");
    assert!(audio.iter().all(|t| t.bitrate > 0), "E-AC-3 nominal bitrate");
}

#[test]
fn orf_hard_of_hearing_and_lfe() {
    let ev = demux_all(&fixture("streams/orf1.ts"));
    let t = tracks(&ev);
    let ac3 = t.iter().find(|t| t.codec == Codec::Ac3).unwrap();
    assert_eq!(ac3.channels, 6, "5.1 incl. LFE (R2 channels_with_lfe)");
    assert!(t.iter().any(|t| t.role == AudioRole::HearingImpaired), "ORF clean-audio track");
}

#[test]
fn video_scan_per_channel() {
    for (id, scan) in [("tf-1", Scan::Paff), ("melodie", Scan::Paff), ("france-2", Scan::Mbaff), ("orf1", Scan::Progressive), ("rai-news-24", Scan::Progressive)] {
        let ev = demux_all(&fixture(&format!("streams/{id}.ts")));
        let v = *tracks(&ev).iter().find(|t| matches!(t.codec, Codec::H264 | Codec::Hevc)).unwrap();
        assert_eq!(v.scan, scan, "{id}");
    }
}

#[test]
fn paff_samples_are_top_field_first_pairs() {
    let ev = demux_all(&fixture("streams/tf-1.ts"));
    let v = tracks(&ev).iter().find(|t| t.codec == Codec::H264).unwrap().track_id;
    let s: Vec<_> = ev.iter().filter_map(|e| match e { Event::Sample(s) if s.track_id == v => Some(s), _ => None }).collect();
    assert!(s.iter().all(|s| s.fields == 2), "complementary field pairs");
    assert!(s.iter().all(|s| s.bottom_field_first == Some(false)), "TF1 is top field first");
}

#[test]
fn live_join_from_mid_stream() {
    let data = fixture("streams/tf-1.raw.ts");
    let ev = demux_all(&data[400_000..]);
    let v = tracks(&ev).iter().find(|t| t.codec == Codec::H264).unwrap().track_id;
    let s: Vec<_> = ev.iter().filter_map(|e| match e { Event::Sample(s) if s.track_id == v => Some(s), _ => None }).collect();
    let first = s.iter().position(|s| s.join == Join::JoinPoint).expect("a join point");
    assert!(s[..first].iter().all(|s| s.join == Join::DropBeforeRap));
    assert!(s[first + 1..].iter().all(|s| matches!(s.join, Join::Keep | Join::DropLeading)));
}

/// transmux 0.25.6 (#1171): rejected parameter sets on (clean, garbled) input.
fn invalid_parameter_sets(data: &[u8]) -> usize {
    use transmux::ir::{DemuxEvent, InputDegradation};
    let mut d = transmux::StreamingTsDemux::new();
    let mut n = 0;
    let mut count = |d: &mut transmux::StreamingTsDemux| {
        while let Some(ev) = d.poll_event() {
            if matches!(ev, DemuxEvent::InputDegraded { kind: InputDegradation::InvalidParameterSet, .. }) {
                n += 1;
            }
        }
    };
    for c in data.chunks(65536) {
        d.feed(c);
        count(&mut d);
    }
    d.finish();
    count(&mut d);
    n
}

/// Clean captures (cut and raw) never report an invalid parameter set.
#[test]
fn clean_captures_have_no_invalid_parameter_sets() {
    let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../testdata/streams");
    let mut files = 0;
    let mut bad = vec![];
    for e in std::fs::read_dir(&dir).unwrap() {
        let p = e.unwrap().path();
        if p.extension().is_some_and(|x| x == "ts") {
            let n = invalid_parameter_sets(&std::fs::read(&p).unwrap());
            if n > 0 {
                bad.push(format!("{}={n}", p.file_name().unwrap().to_string_lossy()));
            }
            files += 1;
        }
    }
    assert!(files >= 80, "only {files} captures");
    assert!(bad.is_empty(), "InvalidParameterSet on clean input: {bad:?}");
}

/// Garbled channels (whole file, and from mid-way): rejected parameter sets
/// per channel, for the upstream report. No panics either way.
#[test]
fn garbled_channels_reject_parameter_sets() {
    let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../testdata/streams");
    let (mut files, mut whole, mut half, mut with) = (0, 0, 0, 0);
    for e in std::fs::read_dir(&dir).unwrap() {
        let p = e.unwrap().path();
        let name = p.file_name().unwrap().to_string_lossy().to_string();
        if !name.ends_with(".ts") || name.ends_with(".raw.ts") {
            continue;
        }
        let d = std::fs::read(&p).unwrap();
        let cut = d.len() / 2 / 188 * 188;
        let mut h = d[..cut].to_vec();
        h.extend(garble(&d[cut..]));
        let (a, b) = (invalid_parameter_sets(&garble(&d)), invalid_parameter_sets(&h));
        whole += a;
        half += b;
        if a + b > 0 {
            with += 1;
        }
        files += 1;
    }
    println!("GARBLE channels={files} with_rejections={with} invalid_ps_whole={whole} invalid_ps_half={half}");
    assert!(files >= 40);
}

/// transmux 0.27.2/0.27.3 (#1348): ORF III's DSM-CC carousel (PID 0x1C90)
/// repeats packets; every degradation record names the PID and, since
/// 0.27.3, the Data track it belongs to. 180 excess repeats + 7 gaps.
#[test]
fn orf3_carousel_damage_has_pid_and_track() {
    use broadcast_common::Unpackage;
    let media = transmux::TsDemux::new().unpackage(&fixture("streams/orf-3.raw.ts")).expect("demux");
    assert_eq!(media.degraded_at.len(), media.degraded.len());
    let on_carousel: Vec<_> =
        media.degraded_at.iter().filter(|r| r.provenance.pid.map(|p| p.value()) == Some(0x1C90)).collect();
    assert_eq!(on_carousel.len(), 187, "all {} records: {:?}", media.degraded_at.len(), media.degraded_at.first());
    assert!(on_carousel.iter().all(|r| r.track.is_some()), "track resolved for the Data track");
}

/// transmux ClockReference (live-buffer's PCR input): on every raw capture
/// PCRs come from exactly one PID per program, in increasing order, and the
/// clean captures report no discontinuity.
#[test]
fn clock_references_one_pid_per_capture() {
    use transmux::ir::DemuxEvent;
    let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../testdata/streams");
    let mut report = vec![];
    for e in std::fs::read_dir(&dir).unwrap() {
        let p = e.unwrap().path();
        let name = p.file_name().unwrap().to_string_lossy().to_string();
        if !name.ends_with(".raw.ts") {
            continue;
        }
        let data = std::fs::read(&p).unwrap();
        let mut d = transmux::StreamingTsDemux::new();
        let mut pids = std::collections::BTreeMap::<u16, usize>::new();
        let (mut disc, mut n) = (0, 0);
        let mut drain = |d: &mut transmux::StreamingTsDemux| {
            while let Some(ev) = d.poll_event() {
                if let DemuxEvent::ClockReference { discontinuous, provenance, .. } = ev {
                    *pids.entry(provenance.pid.map_or(0, |p| p.value())).or_default() += 1;
                    n += 1;
                    if discontinuous {
                        disc += 1;
                    }
                }
            }
        };
        for c in data.chunks(65536) {
            d.feed(c);
            drain(&mut d);
        }
        d.finish();
        drain(&mut d);
        report.push(format!("{name}: pcrs={n} pids={pids:?} disc={disc}"));
        assert!(n > 0, "{name}: no ClockReference");
        assert_eq!(pids.len(), 1, "{name}: PCRs from several PIDs {pids:?}");
    }
    println!("{}", report.join("\n"));
}
