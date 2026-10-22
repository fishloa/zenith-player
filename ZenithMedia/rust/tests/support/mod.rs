#![allow(dead_code)]
use std::path::PathBuf;
use zenith_media::demux::{Demux, Event};

/// testdata/<rel> from the repo root; panics with the script to run if absent.
pub fn fixture(rel: &str) -> Vec<u8> {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../testdata").join(rel);
    std::fs::read(&p).unwrap_or_else(|_| {
        panic!(
            "missing fixture {} — run scripts/capture-test-streams.sh, scripts/make-audio-fixtures.sh or scripts/make-paff-fixtures.sh",
            p.display()
        )
    })
}

/// Feed `data` in chunks given by `sizes` (cycled), then finish; collect events.
pub fn demux_chunked(data: &[u8], sizes: &[usize]) -> Vec<Event> {
    let mut d = Demux::new();
    let mut out = Vec::new();
    let mut off = 0;
    let mut i = 0;
    while off < data.len() {
        let n = sizes[i % sizes.len()].min(data.len() - off);
        d.feed(&data[off..off + n]);
        off += n;
        i += 1;
        while let Some(e) = d.poll() {
            out.push(e);
        }
    }
    d.finish();
    while let Some(e) = d.poll() {
        out.push(e);
    }
    out
}

pub fn demux_all(data: &[u8]) -> Vec<Event> {
    demux_chunked(data, &[data.len().max(1)])
}

/// Deterministic pseudo-random chunk sizes in 1..=65536 (LCG, fixed seed).
pub fn random_sizes(n: usize) -> Vec<usize> {
    let mut x: u64 = 0x2545_F491_4F6C_DD1D;
    (0..n)
        .map(|_| {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((x >> 33) % 65536) as usize + 1
        })
        .collect()
}

/// Little WAV reader: returns (channels, rate, interleaved s16).
pub fn read_wav(bytes: &[u8]) -> (u16, u32, Vec<i16>) {
    assert_eq!(&bytes[0..4], b"RIFF");
    let mut off = 12;
    let (mut ch, mut rate) = (0u16, 0u32);
    while off + 8 <= bytes.len() {
        let id = &bytes[off..off + 4];
        let len = u32::from_le_bytes(bytes[off + 4..off + 8].try_into().unwrap()) as usize;
        let body = &bytes[off + 8..(off + 8 + len).min(bytes.len())];
        if id == b"fmt " {
            ch = u16::from_le_bytes([body[2], body[3]]);
            rate = u32::from_le_bytes(body[4..8].try_into().unwrap());
        } else if id == b"data" {
            let s = body.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]])).collect();
            return (ch, rate, s);
        }
        off += 8 + len + (len & 1);
    }
    panic!("no data chunk");
}

/// SNR in dB of `a` against reference `r` over their common length.
pub fn snr_db(a: &[i16], r: &[i16]) -> f64 {
    let n = a.len().min(r.len());
    let (mut sig, mut err) = (0f64, 0f64);
    for k in 0..n {
        let (x, y) = (a[k] as f64, r[k] as f64);
        sig += y * y;
        err += (x - y) * (x - y);
    }
    if err == 0.0 { 200.0 } else { 10.0 * (sig / err).log10() }
}

/// Frame count recorded for a capture in testdata/streams/manifest.tsv.
pub fn manifest_frames(id: &str) -> usize {
    let m = String::from_utf8(fixture("streams/manifest.tsv")).unwrap();
    m.lines()
        .find(|l| l.split('\t').next() == Some(id))
        .and_then(|l| l.split('\t').find_map(|c| c.strip_prefix("frames=")))
        .and_then(|n| n.parse().ok())
        .unwrap_or_else(|| panic!("{id} not in manifest"))
}

/// Scrambles every TS payload past the first 32 bytes of each PES, keeping
/// TS/PES framing: what a damaged live feed looks like to the demuxer.
pub fn garble(ts: &[u8]) -> Vec<u8> {
    let mut b = ts.to_vec();
    for p in b.chunks_exact_mut(188) {
        let pusi = p[1] & 0x40 != 0;
        let pid = ((p[1] as usize & 0x1F) << 8) | p[2] as usize;
        let afc = (p[3] >> 4) & 3;
        let mut off = 4;
        if afc == 2 || afc == 3 {
            off += 1 + p[4] as usize;
        }
        if pid > 0x1F && pid != 0x1FFF && afc & 1 == 1 && off < 188 {
            let from = if pusi { (off + 32).min(188) } else { off };
            for k in from..188 {
                p[k] ^= 0x5Au8.wrapping_add(k as u8);
            }
        }
    }
    b
}
