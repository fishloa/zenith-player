//! Rust side of the decode probe: MPEG audio Layer I/II (MP2) decode via
//! nanomp3-core (MIT/Apache-2.0), exposed over a C ABI. Proves both the
//! decoder and the Rust -> tvOS static-link path.

use nanomp3_core::{Decoder, MAX_SAMPLES_PER_FRAME};

/// Decode an MPEG audio elementary stream to interleaved s16.
/// Writes at most `cap` samples to `out`; stores channel count, layer and
/// frame count. Returns the number of samples written, or -1 on bad args.
///
/// # Safety
/// `input` must be valid for `len` bytes and `out` for `cap` i16s.
#[no_mangle]
pub unsafe extern "C" fn probe_mpa_decode(
    input: *const u8,
    len: usize,
    out: *mut i16,
    cap: usize,
    channels: *mut u32,
    layer: *mut u32,
    frames: *mut u32,
) -> isize {
    if input.is_null() || out.is_null() {
        return -1;
    }
    let mut es = std::slice::from_raw_parts(input, len);
    let out = std::slice::from_raw_parts_mut(out, cap);
    let mut dec = Decoder::new();
    let mut pcm = [0i16; MAX_SAMPLES_PER_FRAME];
    let (mut n, mut ch, mut ly, mut fr) = (0usize, 0u32, 0u32, 0u32);
    while !es.is_empty() {
        let (used, res) = dec.decode(es, &mut pcm);
        if used == 0 {
            break;
        }
        es = &es[used..];
        if let Ok(info) = res {
            ch = info.channels.num() as u32;
            ly = info.layer as u32;
            fr += 1;
            let k = info.samples_produced * ch as usize;
            let k = k.min(cap - n);
            out[n..n + k].copy_from_slice(&pcm[..k]);
            n += k;
        }
    }
    *channels = ch;
    *layer = ly;
    *frames = fr;
    n as isize
}
