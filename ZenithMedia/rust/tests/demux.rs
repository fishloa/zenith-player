mod support;
use support::*;
use zenith_media::demux::{Codec, Event, SampleOut, TrackInfo};

fn tracks(ev: &[Event]) -> Vec<&TrackInfo> {
    ev.iter().filter_map(|e| if let Event::TrackAdded(t) = e { Some(t) } else { None }).collect()
}
fn samples(ev: &[Event], track: u32) -> Vec<&SampleOut> {
    ev.iter()
        .filter_map(|e| match e {
            Event::Sample(s) if s.track_id == track => Some(s),
            _ => None,
        })
        .collect()
}
/// Comparable summary of every sample: (track, pts, dts, len, fnv1a(data)).
fn summary(ev: &[Event]) -> Vec<(u32, i64, i64, usize, u64)> {
    ev.iter()
        .filter_map(|e| match e {
            Event::Sample(s) => {
                let mut h: u64 = 0xcbf29ce484222325;
                for b in &s.data {
                    h = (h ^ *b as u64).wrapping_mul(0x100000001b3);
                }
                Some((s.track_id, s.pts, s.dts, s.data.len(), h))
            }
            _ => None,
        })
        .collect()
}

#[test]
fn france2_tracks_and_counts() {
    let ev = demux_all(&fixture("streams/france-2.ts"));
    let t = tracks(&ev);
    let v = t.iter().find(|t| t.codec == Codec::H264).expect("h264 track");
    assert_eq!((v.width, v.height, v.timescale), (1920, 1080, 90000));
    assert_eq!(v.config[0], 1, "avcC payload starts with configurationVersion 1 (box header stripped)");
    assert_eq!(samples(&ev, v.track_id).len(), manifest_frames("france-2"));
    let eac3: Vec<_> = t.iter().filter(|t| t.codec == Codec::Eac3).collect();
    assert_eq!(eac3.len(), 3);
    assert!(eac3.iter().all(|t| t.channels >= 2 && t.sample_rate == 48000 && !t.config.is_empty()));
    assert!(eac3.iter().all(|t| !t.descriptors.is_empty()), "PMT ES_info passed through");
}

#[test]
fn hevc_track_has_hvcc() {
    let ev = demux_all(&fixture("streams/rai-news-24.ts"));
    let v = *tracks(&ev).iter().find(|t| t.codec == Codec::Hevc).expect("hevc track");
    assert_eq!(v.config[0], 1, "hvcC configurationVersion");
    assert_eq!((v.width, v.height), (1280, 720));
}

#[test]
fn audio_codecs_from_open_fixture() {
    let ev = demux_all(&fixture("audio/mux-aligned.ts"));
    let codecs: Vec<Codec> = tracks(&ev).iter().map(|t| t.codec).collect();
    assert_eq!(codecs, vec![Codec::MpegAudio, Codec::MpegAudio, Codec::Ac3, Codec::Eac3, Codec::Aac]);
    let t = tracks(&ev);
    assert_eq!(t[2].channels, 6);
    assert_eq!(t[2].config.len(), 3, "dac3 payload");
    assert_eq!(t[4].channels, 2);
    let counts: Vec<usize> = t.iter().map(|t| samples(&ev, t.track_id).len()).collect();
    assert_eq!(counts, vec![417, 417, 313, 313, 470]);
}

/// R5: output must not depend on how the byte stream is chunked.
#[test]
fn chunk_size_invariance() {
    for name in ["streams/france-2.ts", "streams/tf-1.ts", "streams/orf1.ts", "streams/rai-news-24.ts", "audio/mux-aligned.ts"] {
        let data = fixture(name);
        let whole = summary(&demux_all(&data));
        assert!(!whole.is_empty(), "{name}: no samples");
        for sizes in [vec![1usize], vec![188], vec![7, 1000, 65536], random_sizes(64)] {
            if sizes == vec![1usize] && data.len() > 3_000_000 {
                continue; // 1-byte feeding of large captures is slow; covered by the smaller ones
            }
            assert_eq!(summary(&demux_chunked(&data, &sizes)), whole, "{name}: chunking {:?}", &sizes[..sizes.len().min(3)]);
        }
    }
}

/// Review Focus 1: an HTTP join starts mid-packet; demux must resync.
/// Uses the unedited server capture: the cut .ts carries PAT/PMT only once.
#[test]
fn starts_mid_packet() {
    let data = fixture("streams/orf1.raw.ts");
    let ev = demux_all(&data[1000..]);
    let v = *tracks(&ev).iter().find(|t| t.codec == Codec::H264).unwrap();
    assert!(samples(&ev, v.track_id).len() > 400, "video recovered after resync");
}

/// Review Focus 2: channels without IDR flag recovery-point access units as RAPs.
#[test]
fn rap_flag_on_recovery_point_streams() {
    for name in ["streams/tf-1.ts", "streams/orf1.ts"] {
        let ev = demux_all(&fixture(name));
        let v = *tracks(&ev).iter().find(|t| t.codec == Codec::H264).unwrap();
        let s = samples(&ev, v.track_id);
        assert!(s[0].is_rap, "{name}: fixture opens on a RAP");
        assert!(s.iter().filter(|s| s.is_rap).count() >= 2, "{name}: periodic RAPs");
        assert!(s.iter().any(|s| !s.is_rap), "{name}: not every AU is a RAP");
    }
}

/// rust-broadcast#1160: frames straddling PES boundaries must survive.
#[test]
fn audio_survives_misaligned_pes() {
    let aligned = demux_all(&fixture("audio/mux-aligned.ts"));
    let split = demux_all(&fixture("audio/mux-split.ts"));
    for (a, b) in tracks(&aligned).iter().zip(tracks(&split)) {
        let (sa, sb) = (samples(&aligned, a.track_id), samples(&split, b.track_id));
        assert_eq!(sa.len(), sb.len(), "{:?} frame count", a.codec);
        for (x, y) in sa.iter().zip(&sb) {
            assert_eq!((x.pts, &x.data), (y.pts, &y.data), "{:?} frame bytes/pts", a.codec);
        }
        for w in sb.windows(2) {
            assert_eq!(w[1].pts - w[0].pts, w[0].duration as i64, "{:?} continuity", a.codec);
        }
    }
}

/// rust-broadcast#1161: one access unit per PAFF frame (both fields).
#[test]
fn paff_pairs_fields() {
    for name in ["paff/tff.ts", "paff/bff.ts"] {
        let ev = demux_all(&fixture(name));
        let v = *tracks(&ev).iter().find(|t| t.codec == Codec::H264).unwrap();
        let s = samples(&ev, v.track_id);
        assert_eq!(s.len(), 12, "{name}: 12 frames, not 24 fields");
        assert!(s.windows(2).all(|w| w[1].pts - w[0].pts == 3600));
    }
}

/// Damaged input (e.g. a garbage "SPS" over 64 KB) must never abort the
/// process: the config is dropped, the demuxer carries on.
#[test]
fn garbled_stream_does_not_panic() {
    let d = fixture("streams/orf1.ts");
    let cut = d.len() / 3 / 188 * 188;
    let mut data = d[..cut].to_vec();
    data.extend(garble(&d[cut..]));
    let ev = demux_all(&data);
    assert!(!tracks(&ev).is_empty());
}

/// Every captured channel, scrambled from the start and from mid-way.
#[test]
fn garbled_channels_do_not_panic() {
    let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../testdata/streams");
    let mut n = 0;
    for e in std::fs::read_dir(&dir).unwrap() {
        let p = e.unwrap().path();
        let name = p.file_name().unwrap().to_string_lossy().to_string();
        if !name.ends_with(".ts") || name.ends_with(".raw.ts") {
            continue;
        }
        let d = std::fs::read(&p).unwrap();
        let cut = d.len() / 2 / 188 * 188;
        let mut half = d[..cut].to_vec();
        half.extend(garble(&d[cut..]));
        demux_all(&half);
        demux_all(&garble(&d));
        n += 1;
    }
    assert!(n >= 40, "only {n} channels");
}
