//! C ABI over rust-broadcast's `buffering-runtime` controller: delivery jitter,
//! buffer target and the start / pause / resume decisions. Media positions
//! are PTS-domain 27 MHz ticks; times are monotonic microseconds.

use buffering_runtime::{BufferController, ControllerConfig, EventRecord, Hint, PolicyConfig, StallMemorySnapshot};

pub struct ZmLiveBuffer {
    ctrl: BufferController,
}

#[repr(C)]
pub struct ZmLbStats {
    pub state: u32, // 0 buffering, 1 playing, 2 starved
    pub lead_us: i64,
    pub target_us: u64,
    pub stalls: u32,
    pub limiting_track: u32,
    pub limiting_valid: u32,
}

/// `initial_us` = cold-start target (0 = crate default); `seed_peak_us` /
/// `seed_age_us` restore the session's stall memory (both 0 = none).
#[no_mangle]
pub extern "C" fn zm_lb_new(initial_us: u64, seed_peak_us: u64, seed_age_us: u64) -> *mut ZmLiveBuffer {
    let mut policy = PolicyConfig::DEFAULT;
    if initial_us > 0 {
        policy.initial_us = initial_us.clamp(policy.min_us, policy.max_us);
    }
    let mut cfg = ControllerConfig::DEFAULT;
    cfg.policy = policy;
    let seed = (seed_peak_us > 0).then(|| StallMemorySnapshot::new(seed_peak_us, seed_age_us));
    match BufferController::new(cfg, seed) {
        Ok(ctrl) => Box::into_raw(Box::new(ZmLiveBuffer { ctrl })),
        Err(_) => std::ptr::null_mut(),
    }
}

/// # Safety
/// `p` must come from `zm_lb_new` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_free(p: *mut ZmLiveBuffer) {
    if !p.is_null() {
        drop(unsafe { Box::from_raw(p) });
    }
}

macro_rules! lb {
    ($p:expr) => {
        match unsafe { $p.as_mut() } {
            Some(l) => &mut l.ctrl,
            None => return Default::default(),
        }
    };
}

/// # Safety
/// `p` from `zm_lb_new`.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_on_chunk(p: *mut ZmLiveBuffer, arrival_us: u64, bytes: u32, has_pcr: bool, pcr_27mhz: u64) {
    lb!(p).on_chunk(arrival_us, bytes, has_pcr.then_some(pcr_27mhz));
}

/// # Safety
/// `p` from `zm_lb_new`.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_register_track(p: *mut ZmLiveBuffer, track: u32) {
    lb!(p).register_track(track);
}

/// # Safety
/// `p` from `zm_lb_new`.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_unregister_track(p: *mut ZmLiveBuffer, track: u32) {
    lb!(p).unregister_track(track);
}

/// # Safety
/// `p` from `zm_lb_new`.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_on_track_media(p: *mut ZmLiveBuffer, now_us: u64, track: u32, media_end_27mhz: u64) {
    lb!(p).on_track_media(now_us, track, media_end_27mhz);
}

/// # Safety
/// `p` from `zm_lb_new`.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_on_tick(p: *mut ZmLiveBuffer, now_us: u64, has_pos: bool, playback_27mhz: u64) {
    lb!(p).on_tick(now_us, has_pos.then_some(playback_27mhz));
}

/// `hint`: live-buffer's stable Hint codes (1 input degraded … 7 reconnected).
/// # Safety
/// `p` from `zm_lb_new`.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_on_hint(p: *mut ZmLiveBuffer, now_us: u64, hint: u32) -> bool {
    let c = lb!(p);
    match Hint::from_code(hint) {
        Some(h) => {
            c.on_hint(now_us, h);
            true
        }
        None => false,
    }
}

/// Writes the next decision to `out` (live-buffer's ABI v2 EventRecord).
/// # Safety
/// `p` from `zm_lb_new`; `out` valid for a write.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_poll(p: *mut ZmLiveBuffer, out: *mut EventRecord) -> bool {
    let c = lb!(p);
    match (c.poll_event(), unsafe { out.as_mut() }) {
        (Some(e), Some(o)) => {
            *o = e.to_record();
            true
        }
        _ => false,
    }
}

/// # Safety
/// `p` from `zm_lb_new`; `out` valid for a write.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_get_stats(p: *mut ZmLiveBuffer, out: *mut ZmLbStats) -> bool {
    let c = lb!(p);
    let Some(o) = (unsafe { out.as_mut() }) else { return false };
    let s = c.stats();
    *o = ZmLbStats {
        state: match s.state {
            buffering_runtime::State::Playing => 1,
            buffering_runtime::State::Starved => 2,
            _ => 0,
        },
        lead_us: s.lead_us,
        target_us: s.target_us,
        stalls: s.stalls,
        limiting_track: s.limiting_track.unwrap_or(0),
        limiting_valid: s.limiting_track.is_some() as u32,
    };
    true
}

/// Session stall memory, to seed the next connection's controller.
/// # Safety
/// `p` from `zm_lb_new`; outputs valid for writes.
#[no_mangle]
pub unsafe extern "C" fn zm_lb_snapshot(p: *mut ZmLiveBuffer, peak_us: *mut u64, age_us: *mut u64) -> bool {
    let c = lb!(p);
    let s = c.snapshot_memory();
    if let (Some(a), Some(b)) = (unsafe { peak_us.as_mut() }, unsafe { age_us.as_mut() }) {
        *a = s.peak_us;
        *b = s.age_us;
        return true;
    }
    false
}
