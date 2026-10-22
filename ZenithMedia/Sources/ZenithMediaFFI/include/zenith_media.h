#ifndef ZENITH_MEDIA_H
#define ZENITH_MEDIA_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Mirrors ZenithMedia/rust/src/lib.rs. Event payload pointers stay valid
// until the next zm_demux_poll / zm_demux_free on the same handle.
typedef struct zm_demux zm_demux;
typedef struct zm_mpa zm_mpa;

enum { ZM_EV_NONE = 0, ZM_EV_TRACK_ADDED = 1, ZM_EV_TRACK_UPDATED = 2,
       ZM_EV_TRACK_REMOVED = 3, ZM_EV_SAMPLE = 4, ZM_EV_DISCONTINUITY = 5,
       ZM_EV_DISPLAY_CHANGED = 6 };

typedef struct {
    uint32_t kind;
    uint32_t track_id;
    uint32_t codec;      // 0 other, 1 h264, 2 hevc, 3 aac, 4 ac3, 5 eac3, 6 mpeg audio
    uint32_t timescale;
    uint16_t width, height, channels, pid;
    uint32_t sample_rate;
    const uint8_t *config; size_t config_len;
    const uint8_t *descriptors; size_t descriptors_len;
    int64_t pts, dts;
    uint32_t duration;
    bool is_sync, is_rap;
    const uint8_t *data; size_t data_len;
    // transmux 0.25.4 facts (R1-R4)
    uint32_t role;        // 0 unknown, 1 main, 2 audio description, 3 hearing impaired
    uint32_t scan;        // 0 unknown, 1 progressive, 2 PAFF, 3 MBAFF, 4 field sequence
    uint32_t bitrate;     // nominal audio bit/s, 0 unknown
    char language[4];     // ISO 639-2, NUL-terminated
    uint32_t join;        // 0 keep, 1 join point, 2 drop before RAP, 3 drop not self-contained, 4 drop leading
    uint8_t fields;       // 0 frame, 1 lone field, 2 field pair
    int8_t bottom_field_first; // -1 unknown, 0 top first, 1 bottom first
    // SPS VUI sample aspect ratio (width:height); 0 = unspecified
    uint16_t pixel_aspect_h, pixel_aspect_v;
    // Display geometry: track events carry the track's signalled colour
    // (0 = not signalled); sample and display-changed events the access
    // unit's state (0 = not signalled). Wire H.264/H.265 code points.
    uint8_t colour_primaries, colour_transfer, colour_matrix;
    uint8_t full_range;   // 1 = signalled full range
} zm_event;

zm_demux *zm_demux_new(void);
void zm_demux_free(zm_demux *d);
void zm_demux_feed(zm_demux *d, const uint8_t *bytes, size_t len);
void zm_demux_finish(zm_demux *d);
bool zm_demux_poll(zm_demux *d, zm_event *ev);
void zm_demux_rejoin(zm_demux *d, uint32_t track_id);

zm_mpa *zm_mpa_new(void);
void zm_mpa_free(zm_mpa *m);
ptrdiff_t zm_mpa_decode(zm_mpa *m, const uint8_t *frame, size_t len, int16_t *out, size_t cap,
                        uint32_t *channels, uint32_t *rate, uint32_t labels[8]);

/* ---- live-buffer (rust-broadcast, ABI v2): playout buffer controller ---- */
typedef struct zm_live_buffer zm_live_buffer;

/* live-buffer EventRecord, ABI v2 (40 bytes). kind: 1 start playing,
   2 pause, 3 resume, 4 target changed, 5 over max, 6 rebaselined,
   7 events dropped. Positions are PTS-domain 27 MHz ticks. */
typedef struct {
    uint32_t kind;
    uint32_t reason;
    uint64_t media_27mhz;
    uint64_t a_us;
    uint64_t b_us;
    uint32_t track;
    uint32_t track_valid;
} zm_lb_event;

typedef struct {
    uint32_t state;      /* 0 buffering, 1 playing, 2 starved */
    int64_t  lead_us;
    uint64_t target_us;
    uint32_t stalls;
    uint32_t limiting_track;
    uint32_t limiting_valid;
} zm_lb_stats;

zm_live_buffer *zm_lb_new(uint64_t initial_us, uint64_t seed_peak_us, uint64_t seed_age_us);
void zm_lb_free(zm_live_buffer *p);
void zm_lb_on_chunk(zm_live_buffer *p, uint64_t arrival_us, uint32_t bytes, bool has_pcr, uint64_t pcr_27mhz);
void zm_lb_register_track(zm_live_buffer *p, uint32_t track);
void zm_lb_unregister_track(zm_live_buffer *p, uint32_t track);
void zm_lb_on_track_media(zm_live_buffer *p, uint64_t now_us, uint32_t track, uint64_t media_end_27mhz);
void zm_lb_on_tick(zm_live_buffer *p, uint64_t now_us, bool has_pos, uint64_t playback_27mhz);
bool zm_lb_on_hint(zm_live_buffer *p, uint64_t now_us, uint32_t hint);
bool zm_lb_poll(zm_live_buffer *p, zm_lb_event *out);
bool zm_lb_get_stats(zm_live_buffer *p, zm_lb_stats *out);
bool zm_lb_snapshot(zm_live_buffer *p, uint64_t *peak_us, uint64_t *age_us);

/* Newest PCR seen by the demuxer since the last call (27 MHz ticks). */
bool zm_demux_take_pcr(zm_demux *p, uint64_t *out);

#endif
