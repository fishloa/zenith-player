//! zenith-media: C ABI for the zenith-tv Apple player.
//! Pointers handed out by `zm_demux_poll` stay valid until the next
//! `zm_demux_poll` or `zm_demux_free` on the same handle. Handles are not
//! thread-safe; use each from one queue.

pub mod demux;
pub mod lb;
pub mod mpa;

use demux::{Demux, Event};

#[repr(C)]
pub struct ZmEvent {
    // 0 none, 1 track added, 2 track updated, 3 track removed, 4 sample, 5 discontinuity, 6 display changed
    pub kind: u32,
    pub track_id: u32, // 0 = none (discontinuity without a track)
    pub codec: u32,
    pub timescale: u32,
    pub width: u16,
    pub height: u16,
    pub channels: u16,
    pub pid: u16,
    pub sample_rate: u32,
    pub config: *const u8,
    pub config_len: usize,
    pub descriptors: *const u8,
    pub descriptors_len: usize,
    pub pts: i64,
    pub dts: i64,
    pub duration: u32,
    pub is_sync: bool,
    pub is_rap: bool,
    pub data: *const u8,
    pub data_len: usize,
    // transmux 0.25.4 facts (R1-R4)
    pub role: u32,          // 0 unknown, 1 main, 2 audio description, 3 hearing impaired
    pub scan: u32,          // 0 unknown, 1 progressive, 2 PAFF, 3 MBAFF, 4 field sequence
    pub bitrate: u32,       // nominal audio bit/s, 0 unknown
    pub language: [u8; 4],  // ISO 639-2, NUL-terminated ("" if none)
    pub join: u32,          // 0 keep, 1 join point, 2 drop (before RAP), 3 drop (not self-contained), 4 drop (leading)
    pub fields: u8,         // 0 frame, 1 lone field, 2 field pair
    pub bottom_field_first: i8, // -1 unknown, 0 top first, 1 bottom first
    pub pixel_aspect_h: u16, // SPS sample aspect ratio, 0 = unspecified
    pub pixel_aspect_v: u16, //
    // transmux 0.27 display geometry
    pub colour_primaries: u8, // wire colour_primaries, 0 = not signalled
    pub colour_transfer: u8,  // wire transfer_characteristics, 0 = not signalled
    pub colour_matrix: u8,    // wire matrix_coefficients, 0 = not signalled
    pub full_range: u8,       // 1 = signalled full range
}

pub struct ZmDemux {
    demux: Demux,
    held: Option<Event>,
}

#[no_mangle]
pub extern "C" fn zm_demux_new() -> *mut ZmDemux {
    Box::into_raw(Box::new(ZmDemux { demux: Demux::new(), held: None }))
}

/// # Safety
/// `p` must come from `zm_demux_new` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn zm_demux_free(p: *mut ZmDemux) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

/// # Safety
/// `p` valid; `bytes` valid for `len` bytes (or `len == 0`).
#[no_mangle]
pub unsafe extern "C" fn zm_demux_feed(p: *mut ZmDemux, bytes: *const u8, len: usize) {
    if p.is_null() || bytes.is_null() || len == 0 {
        return;
    }
    (*p).demux.feed(std::slice::from_raw_parts(bytes, len));
}

/// # Safety
/// `p` valid.
#[no_mangle]
pub unsafe extern "C" fn zm_demux_finish(p: *mut ZmDemux) {
    if !p.is_null() {
        (*p).demux.finish();
    }
}

/// Restart the live join on a video track (decoder reset, discontinuity).
///
/// # Safety
/// `p` valid.
#[no_mangle]
pub unsafe extern "C" fn zm_demux_rejoin(p: *mut ZmDemux, track_id: u32) {
    if !p.is_null() {
        (*p).demux.rejoin(track_id);
    }
}

/// Fill `*ev` with the next event; false when none is pending.
///
/// # Safety
/// `p` and `ev` valid.
#[no_mangle]
pub unsafe extern "C" fn zm_demux_poll(p: *mut ZmDemux, ev: *mut ZmEvent) -> bool {
    if p.is_null() || ev.is_null() {
        return false;
    }
    let d = &mut *p;
    d.held = d.demux.poll();
    let mut out = ZmEvent {
        kind: 0, track_id: 0, codec: 0, timescale: 0, width: 0, height: 0, channels: 0, pid: 0,
        sample_rate: 0, config: std::ptr::null(), config_len: 0, descriptors: std::ptr::null(),
        descriptors_len: 0, pts: 0, dts: 0, duration: 0, is_sync: false, is_rap: false,
        data: std::ptr::null(), data_len: 0,
        role: 0, scan: 0, bitrate: 0, language: [0; 4], join: 0, fields: 0, bottom_field_first: -1,
        pixel_aspect_h: 0, pixel_aspect_v: 0,
        colour_primaries: 0, colour_transfer: 0, colour_matrix: 0, full_range: 0,
    };
    fn put_geometry(out: &mut ZmEvent, g: &demux::Geometry) {
        if let Some((h, v)) = g.pixel_aspect {
            (out.pixel_aspect_h, out.pixel_aspect_v) = (h, v);
        }
        if let Some(c) = g.colour {
            (out.colour_primaries, out.colour_transfer, out.colour_matrix) = (c.primaries, c.transfer, c.matrix);
            out.full_range = u8::from(c.full_range);
        }
    }
    match &d.held {
        None => return false,
        Some(Event::TrackAdded(t)) | Some(Event::TrackUpdated(t)) => {
            out.kind = if matches!(d.held, Some(Event::TrackAdded(_))) { 1 } else { 2 };
            out.track_id = t.track_id;
            out.codec = t.codec as u32;
            out.timescale = t.timescale;
            (out.width, out.height, out.channels, out.pid, out.sample_rate) =
                (t.width, t.height, t.channels, t.pid, t.sample_rate);
            (out.config, out.config_len) = (t.config.as_ptr(), t.config.len());
            (out.descriptors, out.descriptors_len) = (t.descriptors.as_ptr(), t.descriptors.len());
            (out.role, out.scan, out.bitrate) = (t.role as u32, t.scan as u32, t.bitrate);
            for (i, b) in t.language.bytes().take(3).enumerate() {
                out.language[i] = b;
            }
            put_geometry(&mut out, &demux::Geometry { pixel_aspect: t.pixel_aspect, colour: t.colour });
        }
        Some(Event::TrackRemoved(id)) => {
            out.kind = 3;
            out.track_id = *id;
        }
        Some(Event::Sample(s)) => {
            out.kind = 4;
            out.track_id = s.track_id;
            (out.pts, out.dts, out.duration, out.is_sync, out.is_rap) = (s.pts, s.dts, s.duration, s.is_sync, s.is_rap);
            (out.data, out.data_len) = (s.data.as_ptr(), s.data.len());
            (out.join, out.fields) = (s.join as u32, s.fields);
            out.bottom_field_first = s.bottom_field_first.map_or(-1, |b| b as i8);
        }
        Some(Event::Discontinuity(t)) => {
            out.kind = 5;
            out.track_id = t.unwrap_or(0);
        }
        Some(Event::DisplayChanged { track_id, pts, geometry }) => {
            out.kind = 6;
            out.track_id = *track_id;
            out.pts = pts.unwrap_or(0);
            if let Some(g) = geometry {
                put_geometry(&mut out, g);
            }
        }
    }
    *ev = out;
    true
}

pub struct ZmMpa(mpa::Mpa);

#[no_mangle]
pub extern "C" fn zm_mpa_new() -> *mut ZmMpa {
    Box::into_raw(Box::new(ZmMpa(mpa::Mpa::new())))
}

/// # Safety
/// `p` from `zm_mpa_new`, not used afterwards.
#[no_mangle]
pub unsafe extern "C" fn zm_mpa_free(p: *mut ZmMpa) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

/// Decode one MPEG audio frame into `out` (interleaved s16, `cap` samples).
/// Writes channel count, sample rate and up to 8 CoreAudio channel labels.
/// Returns samples per channel, or -1 on error / insufficient `cap`.
///
/// # Safety
/// All pointers valid; `frame` for `len` bytes, `out` for `cap` i16s,
/// `labels` for 8 u32s.
#[no_mangle]
pub unsafe extern "C" fn zm_mpa_decode(
    p: *mut ZmMpa,
    frame: *const u8,
    len: usize,
    out: *mut i16,
    cap: usize,
    channels: *mut u32,
    rate: *mut u32,
    labels: *mut u32,
) -> isize {
    if p.is_null() || frame.is_null() || out.is_null() || channels.is_null() || rate.is_null() || labels.is_null() {
        return -1;
    }
    let Ok(f) = (*p).0.decode(std::slice::from_raw_parts(frame, len)) else { return -1 };
    if f.samples.len() > cap || f.labels.len() > 8 {
        return -1;
    }
    std::ptr::copy_nonoverlapping(f.samples.as_ptr(), out, f.samples.len());
    *channels = f.channels;
    *rate = f.sample_rate;
    for i in 0..8 {
        *labels.add(i) = f.labels.get(i).copied().unwrap_or(0);
    }
    (f.samples.len() / f.channels.max(1) as usize) as isize
}

/// The newest PCR seen by this demuxer since the last call (27 MHz ticks).
/// # Safety
/// `p` from `zm_demux_new`; `out` valid for a write.
#[no_mangle]
pub unsafe extern "C" fn zm_demux_take_pcr(p: *mut ZmDemux, out: *mut u64) -> bool {
    let (Some(d), Some(o)) = (unsafe { p.as_mut() }, unsafe { out.as_mut() }) else { return false };
    match d.demux.take_last_pcr() {
        Some(v) => {
            *o = v;
            true
        }
        None => false,
    }
}
