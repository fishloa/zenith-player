//! zenith-media: C ABI for the zenith-tv Apple player.
//! Pointers handed out by `zm_demux_poll` stay valid until the next
//! `zm_demux_poll` or `zm_demux_free` on the same handle. Handles are not
//! thread-safe; use each from one queue.

pub mod demux;
pub mod mpa;
pub mod session;

use demux::{Demux, Event};
use session::Client;
use std::ffi::{CStr, CString};

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
    pub status: u32,
    pub status_value: u64,
    pub http_status: u16,
    pub starved_with_data: u8,
    pub pause_reason: u8,
    pub auth_scheme: *const std::ffi::c_char,
    pub auth_realm: *const std::ffi::c_char,
    pub auth_origin: *const std::ffi::c_char,
    pub auth_metadata: *const std::ffi::c_char,
    pub text: *const std::ffi::c_char,
}

#[repr(C)]
pub struct ZmBufferStats {
    pub stalls: u32,
    pub reprimes: u32,
    pub discontinuities: u32,
    pub longest_freeze_us: u64,
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
    let Some(held) = d.held.as_ref() else {
        return false;
    };
    let mut out = zeroed_zm_event();
    fill_demux_event(&mut out, held);
    *ev = out;
    true
}

fn zeroed_zm_event() -> ZmEvent {
    ZmEvent {
        kind: 0, track_id: 0, codec: 0, timescale: 0, width: 0, height: 0, channels: 0, pid: 0,
        sample_rate: 0, config: std::ptr::null(), config_len: 0, descriptors: std::ptr::null(),
        descriptors_len: 0, pts: 0, dts: 0, duration: 0, is_sync: false, is_rap: false,
        data: std::ptr::null(), data_len: 0,
        role: 0, scan: 0, bitrate: 0, language: [0; 4], join: 0, fields: 0, bottom_field_first: -1,
        pixel_aspect_h: 0, pixel_aspect_v: 0,
        colour_primaries: 0, colour_transfer: 0, colour_matrix: 0, full_range: 0,
        status: 0, status_value: 0, http_status: 0, starved_with_data: 0, pause_reason: 0,
        auth_scheme: std::ptr::null(), auth_realm: std::ptr::null(),
        auth_origin: std::ptr::null(), auth_metadata: std::ptr::null(),
        text: std::ptr::null(),
    }
}

fn put_geometry(out: &mut ZmEvent, g: &demux::Geometry) {
    if let Some((h, v)) = g.pixel_aspect {
        (out.pixel_aspect_h, out.pixel_aspect_v) = (h, v);
    }
    if let Some(c) = g.colour {
        (out.colour_primaries, out.colour_transfer, out.colour_matrix) = (c.primaries, c.transfer, c.matrix);
        out.full_range = u8::from(c.full_range);
    }
}

fn fill_demux_event(out: &mut ZmEvent, ev: &Event) {
    match ev {
        Event::TrackAdded(t) => {
            out.kind = 1;
            fill_track(out, t);
        }
        Event::TrackUpdated(t) => {
            out.kind = 2;
            fill_track(out, t);
        }
        Event::TrackRemoved(id) => {
            out.kind = 3;
            out.track_id = *id;
        }
        Event::Sample(s) => {
            out.kind = 4;
            out.track_id = s.track_id;
            (out.pts, out.dts, out.duration, out.is_sync, out.is_rap) = (s.pts, s.dts, s.duration, s.is_sync, s.is_rap);
            (out.data, out.data_len) = (s.data.as_ptr(), s.data.len());
            (out.join, out.fields) = (s.join as u32, s.fields);
            out.bottom_field_first = s.bottom_field_first.map_or(-1, |b| b as i8);
        }
        Event::Discontinuity(t) => {
            out.kind = 5;
            out.track_id = t.unwrap_or(0);
        }
        Event::DisplayChanged { track_id, pts, geometry } => {
            out.kind = 6;
            out.track_id = *track_id;
            out.pts = pts.unwrap_or(0);
            if let Some(g) = geometry {
                put_geometry(out, g);
            }
        }
    }
}

fn fill_track(out: &mut ZmEvent, t: &demux::TrackInfo) {
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
    put_geometry(out, &demux::Geometry { pixel_aspect: t.pixel_aspect, colour: t.colour });
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

#[repr(C)]
pub struct ZmAction {
    pub kind: u32,
    pub conn: u32,
    pub method: *const std::ffi::c_char,
    pub url: *const std::ffi::c_char,
    pub headers: *const std::ffi::c_char,
    pub has_range: bool,
    pub range_start: u64,
    pub range_len: u64,
    pub wake_us: u64,
}

pub struct ZmSession {
    client: Client,
    held_action: Option<HeldAction>,
    held_event: Option<HeldEvent>,
}

struct HeldAction {
    method: Option<CString>,
    url: Option<CString>,
    headers: Option<CString>,
    kind: u32,
    conn: u32,
    has_range: bool,
    range_start: u64,
    range_len: u64,
    wake_us: u64,
}

struct HeldEvent {
    client_event: session::ClientEvent,
    auth_scheme: Option<CString>,
    auth_realm: Option<CString>,
    auth_origin: Option<CString>,
    auth_metadata: Option<CString>,
    text: Option<CString>,
}

impl HeldEvent {
    fn new(ce: session::ClientEvent) -> Self {
        let mut h = HeldEvent {
            client_event: ce,
            auth_scheme: None,
            auth_realm: None,
            auth_origin: None,
            auth_metadata: None,
            text: None,
        };
        if let session::ClientEvent::AuthRequired {
            scheme,
            realm,
            origin,
            resource_metadata,
        } = &h.client_event
        {
            h.auth_scheme = CString::new(scheme.clone()).ok();
            h.auth_realm = realm.as_ref().and_then(|r| CString::new(r.clone()).ok());
            h.auth_origin = CString::new(origin.clone()).ok();
            h.auth_metadata = resource_metadata.as_ref().and_then(|m| CString::new(m.clone()).ok());
        }
        if let session::ClientEvent::Variants { lines, .. } = &h.client_event {
            h.text = CString::new(lines.join("\n")).ok();
        }
        if let session::ClientEvent::Error { name, .. } = &h.client_event {
            h.text = CString::new(name.clone()).ok();
        }
        h
    }
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_open(url: *const std::ffi::c_char, now_us: u64) -> *mut ZmSession {
    if url.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(s) = CStr::from_ptr(url).to_str() else {
        return std::ptr::null_mut();
    };
    match Client::open(s, now_us) {
        Ok(client) => Box::into_raw(Box::new(ZmSession {
            client,
            held_action: None,
            held_event: None,
        })),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_open_with_memory(
    url: *const std::ffi::c_char,
    now_us: u64,
    peak_us: u64,
    age_us: u64,
) -> *mut ZmSession {
    if url.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(s) = CStr::from_ptr(url).to_str() else {
        return std::ptr::null_mut();
    };
    match Client::open_with_memory(s, now_us, peak_us, age_us) {
        Ok(client) => Box::into_raw(Box::new(ZmSession {
            client,
            held_action: None,
            held_event: None,
        })),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
/// # Safety
/// `url` is a NUL-terminated string or null.
pub unsafe extern "C" fn zm_session_open_ex(
    url: *const std::ffi::c_char,
    now_us: u64,
    start_us: u64,
    peak_us: u64,
    age_us: u64,
) -> *mut ZmSession {
    if url.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(s) = CStr::from_ptr(url).to_str() else {
        return std::ptr::null_mut();
    };
    match Client::open_with(s, now_us, start_us, peak_us, age_us) {
        Ok(client) => Box::into_raw(Box::new(ZmSession {
            client,
            held_action: None,
            held_event: None,
        })),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_free(p: *mut ZmSession) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_poll_action(
    s: *mut ZmSession,
    now_us: u64,
    out: *mut ZmAction,
) -> bool {
    if s.is_null() || out.is_null() {
        return false;
    }
    let zs = &mut *s;
    let held = loop {
        let Some(action) = zs.client.poll_action(now_us) else {
            zs.held_action = None;
            return false;
        };
        match action {
            broadcast_client::Action::HttpRequest {
                conn,
                method,
                url,
                headers,
                byte_range,
            } => {
                let mut hs = String::new();
                for (k, v) in &headers {
                    hs.push_str(k);
                    hs.push_str(": ");
                    hs.push_str(v);
                    hs.push('\n');
                }
                let (has_range, range_start, range_len) = match byte_range {
                    Some((a, b)) => (true, a, b),
                    None => (false, 0, 0),
                };
                break HeldAction {
                    method: CString::new(method).ok(),
                    url: CString::new(url).ok(),
                    headers: CString::new(hs).ok(),
                    kind: 1,
                    conn,
                    has_range,
                    range_start,
                    range_len,
                    wake_us: 0,
                };
            }
            broadcast_client::Action::Close { conn } => {
                break HeldAction {
                    method: None,
                    url: None,
                    headers: None,
                    kind: 2,
                    conn,
                    has_range: false,
                    range_start: 0,
                    range_len: 0,
                    wake_us: 0,
                };
            }
            broadcast_client::Action::WakeAt(us) => {
                break HeldAction {
                    method: None,
                    url: None,
                    headers: None,
                    kind: 3,
                    conn: 0,
                    has_range: false,
                    range_start: 0,
                    range_len: 0,
                    wake_us: us,
                };
            }
            _ => continue,
        }
    };
    let outref = &mut *out;
    outref.kind = held.kind;
    outref.conn = held.conn;
    outref.method = held.method.as_ref().map_or(std::ptr::null(), |c| c.as_ptr());
    outref.url = held.url.as_ref().map_or(std::ptr::null(), |c| c.as_ptr());
    outref.headers = held.headers.as_ref().map_or(std::ptr::null(), |c| c.as_ptr());
    outref.has_range = held.has_range;
    outref.range_start = held.range_start;
    outref.range_len = held.range_len;
    outref.wake_us = held.wake_us;
    zs.held_action = Some(held);
    true
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_poll(s: *mut ZmSession, ev: *mut ZmEvent) -> bool {
    if s.is_null() || ev.is_null() {
        return false;
    }
    let zs = &mut *s;
    let Some(ce) = zs.client.poll_event() else {
        zs.held_event = None;
        return false;
    };
    let held = HeldEvent::new(ce);
    let mut out = zeroed_zm_event();
    fill_session_event(&mut out, &held);
    zs.held_event = Some(held);
    *ev = out;
    true
}

fn fill_session_event(out: &mut ZmEvent, held: &HeldEvent) {
    use broadcast_client::Status;
    match &held.client_event {
        session::ClientEvent::Media(m) => fill_demux_event(out, m),
        session::ClientEvent::Status(s) => {
            out.kind = 7;
            match s {
                Status::Establishing => out.status = 1,
                Status::Live => out.status = 2,
                Status::Stalled { secs } => {
                    out.status = 3;
                    out.status_value = *secs;
                }
                Status::Reconnecting { attempt } => {
                    out.status = 4;
                    out.status_value = *attempt;
                }
                Status::NotFound => out.status = 5,
                Status::WaitingForCredentials => out.status = 6,
                Status::Ended => out.status = 7,
                _ => {}
            }
        }
        session::ClientEvent::AuthRequired { .. } => {
            out.kind = 8;
            out.auth_scheme = held
                .auth_scheme
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr());
            out.auth_realm = held
                .auth_realm
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr());
            out.auth_origin = held
                .auth_origin
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr());
            out.auth_metadata = held
                .auth_metadata
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr());
        }
        session::ClientEvent::AuthRejected(status) => {
            out.kind = 9;
            out.http_status = *status;
        }
        session::ClientEvent::Forbidden(status) => {
            out.kind = 10;
            out.http_status = *status;
        }
        session::ClientEvent::Starved { with_data } => {
            out.kind = 11;
            out.starved_with_data = u8::from(*with_data);
        }
        session::ClientEvent::Finite { expected_bytes } => {
            out.kind = 12;
            out.status_value = *expected_bytes;
        }
        session::ClientEvent::Buffer(b) => {
            out.kind = 13;
            match b {
                session::Buffer::Start { at_27mhz } => {
                    out.status = 1;
                    out.status_value = *at_27mhz;
                }
                session::Buffer::Pause {
                    hold_at_27mhz,
                    starving_track,
                    reason,
                } => {
                    out.status = 2;
                    out.status_value = *hold_at_27mhz;
                    out.track_id = starving_track.unwrap_or(0);
                    out.pause_reason = *reason as u8;
                }
                session::Buffer::Resume { at_27mhz } => {
                    out.status = 3;
                    out.status_value = *at_27mhz;
                }
            }
        }
        session::ClientEvent::Variants { chosen, lines } => {
            out.kind = 14;
            out.status = *chosen as u32;
            out.status_value = lines.len() as u64;
            out.text = held
                .text
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr());
        }
        session::ClientEvent::Error { name: _, fatal } => {
            out.kind = 15;
            out.status = if *fatal { 1 } else { 0 };
            out.text = held
                .text
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr());
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_on_response(
    s: *mut ZmSession,
    conn: u32,
    status: u16,
    headers: *const std::ffi::c_char,
    now_us: u64,
) {
    if s.is_null() {
        return;
    }
    let zs = &mut *s;
    let mut parsed: Vec<(String, String)> = Vec::new();
    if !headers.is_null() {
        let txt = CStr::from_ptr(headers).to_string_lossy();
        for line in txt.split('\n') {
            if line.trim().is_empty() {
                continue;
            }
            if let Some((k, v)) = line.split_once(':') {
                parsed.push((k.trim().to_string(), v.trim().to_string()));
            }
        }
    }
    zs.client.on_response(conn, status, &parsed, now_us);
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_on_data(
    s: *mut ZmSession,
    conn: u32,
    bytes: *const u8,
    len: usize,
    now_us: u64,
) {
    if s.is_null() {
        return;
    }
    let zs = &mut *s;
    let slice = if len == 0 {
        &[] as &[u8]
    } else if bytes.is_null() {
        return;
    } else {
        std::slice::from_raw_parts(bytes, len)
    };
    zs.client.on_data(conn, slice, now_us);
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_on_closed(
    s: *mut ZmSession,
    conn: u32,
    error: *const std::ffi::c_char,
    now_us: u64,
) {
    if s.is_null() {
        return;
    }
    let zs = &mut *s;
    let err = if error.is_null() {
        None
    } else {
        Some(CStr::from_ptr(error).to_string_lossy().into_owned())
    };
    zs.client.on_closed(conn, err, now_us);
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_set_password(
    s: *mut ZmSession,
    user: *const std::ffi::c_char,
    password: *const std::ffi::c_char,
) -> bool {
    if s.is_null() || user.is_null() || password.is_null() {
        return false;
    }
    let zs = &mut *s;
    let u = CStr::from_ptr(user).to_string_lossy().into_owned();
    let p = CStr::from_ptr(password).to_string_lossy().into_owned();
    zs.client
        .set_credentials(broadcast_client::Credentials::new(u, p))
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_set_bearer(s: *mut ZmSession, token: *const std::ffi::c_char) -> bool {
    if s.is_null() || token.is_null() {
        return false;
    }
    let zs = &mut *s;
    let t = CStr::from_ptr(token).to_string_lossy().into_owned();
    zs.client
        .set_credentials(broadcast_client::Credentials::bearer(t))
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_reconnect(s: *mut ZmSession, now_us: u64) {
    if s.is_null() {
        return;
    }
    (*s).client.reconnect(now_us);
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_rejoin(s: *mut ZmSession, track_id: u32) {
    if s.is_null() {
        return;
    }
    (*s).client.rejoin(track_id);
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_stall_memory(
    s: *mut ZmSession,
    peak_us: *mut u64,
    age_us: *mut u64,
) -> bool {
    if s.is_null() || peak_us.is_null() || age_us.is_null() {
        return false;
    }
    let (p, a) = (*s).client.stall_memory();
    *peak_us = p;
    *age_us = a;
    true
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_buffer_stats(s: *mut ZmSession, out: *mut ZmBufferStats) {
    if s.is_null() || out.is_null() {
        return;
    }
    let bs = (*s).client.buffer_stats();
    (*out).stalls = bs.stalls;
    (*out).reprimes = bs.reprimes;
    (*out).discontinuities = bs.discontinuities;
    (*out).longest_freeze_us = bs.longest_freeze_us;
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_on_playback_position(
    s: *mut ZmSession,
    now_us: u64,
    has_pos: bool,
    pts_27mhz: u64,
) {
    if s.is_null() {
        return;
    }
    (*s).client.on_playback_position(now_us, if has_pos { Some(pts_27mhz) } else { None });
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_set_rendered_tracks(
    s: *mut ZmSession,
    ids: *const u32,
    n: usize,
) {
    if s.is_null() {
        return;
    }
    let slice = if n == 0 || ids.is_null() {
        &[] as &[u32]
    } else {
        std::slice::from_raw_parts(ids, n)
    };
    (*s).client.set_rendered_tracks(slice);
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_hint(s: *mut ZmSession, code: u32) {
    if s.is_null() {
        return;
    }
    (*s).client.hint(code);
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_select_variant(s: *mut ZmSession, index: usize) -> bool {
    if s.is_null() {
        return false;
    }
    (*s).client.select_variant(index)
}

#[no_mangle]
pub unsafe extern "C" fn zm_session_close(s: *mut ZmSession) {
    if s.is_null() {
        return;
    }
    (*s).client.close();
}

#[cfg(test)]
mod ffi_tests {
    use super::*;
    use std::ffi::{CStr, CString};

    #[test]
    fn session_round_trip() {
        let url = CString::new("http://a.example/live.ts").unwrap();
        let s = unsafe { zm_session_open(url.as_ptr(), 0) };
        assert!(!s.is_null());
        let mut a: ZmAction = unsafe { std::mem::zeroed() };
        unsafe {
            assert!(zm_session_poll_action(s, 0, &mut a));
            assert_eq!(a.kind, 1);
            assert_eq!(CStr::from_ptr(a.url).to_str().unwrap(), "http://a.example/live.ts");
            assert_eq!(CStr::from_ptr(a.method).to_str().unwrap(), "GET");
            let h = CString::new("WWW-Authenticate: Bearer realm=\"z\"\n").unwrap();
            zm_session_on_response(s, a.conn, 401, h.as_ptr(), 0);
            let mut e: ZmEvent = std::mem::zeroed();
            let mut seen = false;
            while unsafe { zm_session_poll(s, &mut e) } {
                if e.kind == 8 {
                    seen = true;
                    assert_eq!(CStr::from_ptr(e.auth_scheme).to_str().unwrap(), "bearer");
                    assert_eq!(CStr::from_ptr(e.auth_realm).to_str().unwrap(), "z");
                }
            }
            assert!(seen);
            zm_session_free(s);
        }
        let bad = CString::new("rtmp://x/y").unwrap();
        assert!(unsafe { zm_session_open(bad.as_ptr(), 0) }.is_null());
    }

    #[test]
    fn session_password_and_inputs() {
        let url = CString::new("http://a.example/live.ts").unwrap();
        let s = unsafe { zm_session_open(url.as_ptr(), 0) };
        assert!(!s.is_null());
        unsafe {
            let mut a: ZmAction = std::mem::zeroed();
            assert!(zm_session_poll_action(s, 0, &mut a));
            let h = CString::new("WWW-Authenticate: Basic realm=\"tv\"\n").unwrap();
            zm_session_on_response(s, a.conn, 401, h.as_ptr(), 0);
            let mut e: ZmEvent = std::mem::zeroed();
            while zm_session_poll(s, &mut e) {}
            let u = CString::new("u").unwrap();
            let p = CString::new("p").unwrap();
            zm_session_set_password(s, u.as_ptr(), p.as_ptr());
            while !(zm_session_poll_action(s, 0, &mut a) && a.kind == 1) {}
            let headers = if a.headers.is_null() { "" } else { CStr::from_ptr(a.headers).to_str().unwrap() };
            assert!(headers.to_lowercase().contains("authorization: basic"));
            let ids = [1u32];
            zm_session_set_rendered_tracks(s, ids.as_ptr(), ids.len());
            zm_session_on_playback_position(s, 0, false, 0);
            zm_session_hint(s, 1);
            zm_session_free(s);
        }
    }
}
