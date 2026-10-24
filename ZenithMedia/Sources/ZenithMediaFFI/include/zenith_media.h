#ifndef ZENITH_MEDIA_H
#define ZENITH_MEDIA_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Mirrors ZenithMedia/rust/src/lib.rs. Event payload pointers stay valid
// until the next zm_demux_poll / zm_demux_free on the same handle, and
// session action/event pointers stay valid until the next
// zm_session_poll_action / zm_session_poll (respectively) or
// zm_session_free on the same handle. Handles are not thread-safe.
typedef struct zm_demux zm_demux;
typedef struct zm_mpa zm_mpa;
typedef struct zm_session zm_session;

enum { ZM_EV_NONE = 0, ZM_EV_TRACK_ADDED = 1, ZM_EV_TRACK_UPDATED = 2,
       ZM_EV_TRACK_REMOVED = 3, ZM_EV_SAMPLE = 4, ZM_EV_DISCONTINUITY = 5,
       ZM_EV_DISPLAY_CHANGED = 6 };
enum { ZM_EV_STATUS = 7, ZM_EV_AUTH_REQUIRED = 8, ZM_EV_AUTH_REJECTED = 9,
       ZM_EV_FORBIDDEN = 10, ZM_EV_STARVED = 11, ZM_EV_FINITE = 12,
       ZM_EV_BUFFER = 13, ZM_EV_VARIANTS = 14, ZM_EV_ERROR = 15 };

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
    // session events
    uint32_t status;
    uint64_t status_value;
    uint16_t http_status;
    uint8_t starved_with_data;
    const char *auth_scheme;
    const char *auth_realm;
    const char *auth_origin;
    const char *auth_metadata;
    const char *text;
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

/* ---- session (broadcast-client) ---- */
enum { ZM_ACT_NONE = 0, ZM_ACT_HTTP = 1, ZM_ACT_CLOSE = 2, ZM_ACT_WAKE = 3 };

typedef struct {
    uint32_t kind;
    uint32_t conn;
    const char *method;
    const char *url;
    const char *headers;
    bool has_range;
    uint64_t range_start, range_len;
    uint64_t wake_us;
} zm_action;

zm_session *zm_session_open(const char *url, uint64_t now_us);
zm_session *zm_session_open_with_memory(const char *url, uint64_t now_us, uint64_t peak_us, uint64_t age_us);
/* start_us: cold-start buffer target (0 = default); peak_us/age_us: stall memory (0 = none) */
zm_session *zm_session_open_ex(const char *url, uint64_t now_us, uint64_t start_us, uint64_t peak_us, uint64_t age_us);
void zm_session_free(zm_session *s);
void zm_session_close(zm_session *s);
bool zm_session_poll_action(zm_session *s, uint64_t now_us, zm_action *out);
bool zm_session_poll(zm_session *s, zm_event *out);
void zm_session_on_response(zm_session *s, uint32_t conn, uint16_t status, const char *headers, uint64_t now_us);
void zm_session_on_data(zm_session *s, uint32_t conn, const uint8_t *bytes, size_t len, uint64_t now_us);
void zm_session_on_closed(zm_session *s, uint32_t conn, const char *error, uint64_t now_us);
bool zm_session_set_password(zm_session *s, const char *user, const char *password);
bool zm_session_set_bearer(zm_session *s, const char *token);
void zm_session_reconnect(zm_session *s, uint64_t now_us);
void zm_session_rejoin(zm_session *s, uint32_t track_id);
bool zm_session_stall_memory(zm_session *s, uint64_t *peak_us, uint64_t *age_us);
void zm_session_on_playback_position(zm_session *s, uint64_t now_us, bool has_pos, uint64_t pts_27mhz);
void zm_session_set_rendered_tracks(zm_session *s, const uint32_t *ids, size_t n);
void zm_session_hint(zm_session *s, uint32_t code);
bool zm_session_select_variant(zm_session *s, size_t index);
/* Newest PCR seen by the demuxer since the last call (27 MHz ticks). */
bool zm_demux_take_pcr(zm_demux *p, uint64_t *out);

#endif
