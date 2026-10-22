mod support;
use support::*;
use zenith_media::demux::{Codec, Event};
use zenith_media::mpa::{upsample_lfe, Mpa};

/// Decode every MPEG-audio sample of `track_index` (0-based among MP2 tracks) in mux-aligned.ts.
fn decode_track(track_index: usize) -> (u32, u32, Vec<u32>, Vec<i16>) {
    let ev = demux_all(&fixture("audio/mux-aligned.ts"));
    let ids: Vec<u32> = ev
        .iter()
        .filter_map(|e| match e {
            Event::TrackAdded(t) if t.codec == Codec::MpegAudio => Some(t.track_id),
            _ => None,
        })
        .collect();
    let id = ids[track_index];
    let mut m = Mpa::new();
    let (mut ch, mut rate, mut labels, mut pcm) = (0, 0, Vec::new(), Vec::new());
    for e in &ev {
        if let Event::Sample(s) = e {
            if s.track_id == id {
                let f = m.decode(&s.data).expect("frame decodes");
                (ch, rate, labels) = (f.channels, f.sample_rate, f.labels.to_vec());
                pcm.extend_from_slice(f.samples);
            }
        }
    }
    (ch, rate, labels, pcm)
}

#[test]
fn stereo_matches_reference_and_source() {
    let (ch, rate, labels, pcm) = decode_track(0);
    assert_eq!((ch, rate, labels), (2, 48000, vec![1, 2]));
    let (_, _, reference) = read_wav(&fixture("audio/mp2-st.ref.wav"));
    let (_, _, source) = read_wav(&fixture("audio/src-st.wav"));
    assert_eq!(pcm.len(), 417 * 1152 * 2);
    let s = snr_db(&pcm, &reference);
    assert!(s >= 60.0, "vs ffmpeg reference decode: {s:.1} dB");
    // Lossy codec vs original: an encoder-delay-aligned comparison is out of
    // scope; require only that the output is real audio of similar energy.
    let e = |v: &[i16]| v.iter().map(|x| (*x as f64).powi(2)).sum::<f64>() / v.len() as f64;
    let ratio = e(&pcm) / e(&source);
    assert!((0.5..2.0).contains(&ratio), "energy ratio vs source {ratio:.2}");
}

#[test]
fn mono_matches_reference() {
    let (ch, _, labels, pcm) = decode_track(1);
    assert_eq!((ch, labels), (1, vec![42]));
    let (_, _, reference) = read_wav(&fixture("audio/mp2-mono.ref.wav"));
    let s = snr_db(&pcm, &reference);
    assert!(s >= 60.0, "{s:.1} dB");
}

#[test]
fn rejects_garbage() {
    let mut m = Mpa::new();
    assert!(m.decode(&[0u8; 32]).is_err());
}

#[test]
fn lfe_upsample_is_linear_and_full_length() {
    let up = upsample_lfe(&[0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, -1.0], 1152);
    assert_eq!(up.len(), 1152);
    assert!((up[0] - 0.0).abs() < 1e-9);
    assert!((up[96] - 1.0).abs() < 1e-9, "sample 1 lands at 96");
    assert!((up[48] - 0.5).abs() < 1e-9, "linear in between");
}

/// Review M4: malformed multichannel data must never panic (panic = abort kills the app).
#[test]
fn lfe_upsample_handles_empty_input() {
    assert_eq!(upsample_lfe(&[], 1152), vec![0.0; 1152]);
    assert!(upsample_lfe(&[0.5], 0).is_empty());
}
