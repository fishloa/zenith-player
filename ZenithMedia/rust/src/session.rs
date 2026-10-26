use std::collections::{BTreeMap, VecDeque};

use broadcast_client::{Config, Error as BcError, Event as BcEvent, Session};
use transmux::TrackSpec;

use crate::demux::{Converter, Event as DemuxEvent};

pub enum Buffer {
    Start { at_27mhz: u64 },
    Pause { hold_at_27mhz: u64, starving_track: Option<u32> },
    Resume { at_27mhz: u64 },
}

pub enum ClientEvent {
    Media(crate::demux::Event),
    Status(broadcast_client::Status),
    AuthRequired {
        scheme: String,
        realm: Option<String>,
        origin: String,
        resource_metadata: Option<String>,
    },
    AuthRejected(u16),
    Forbidden(u16),
    Error {
        name: String,
        fatal: bool,
    },
    Starved {
        with_data: bool,
    },
    Finite {
        expected_bytes: u64,
    },
    Buffer(Buffer),
    Variants {
        chosen: usize,
        lines: Vec<String>,
    },
}

pub struct Client {
    session: Session,
    conv: Converter,
    known: BTreeMap<u32, TrackSpec>,
    pending: VecDeque<ClientEvent>,
    now_us: u64,
}

impl Client {
    pub fn open(url: &str, now_us: u64) -> Result<Client, BcError> {
        Self::open_with(url, now_us, 0, 0, 0)
    }

    pub fn open_with_memory(url: &str, now_us: u64, peak_us: u64, age_us: u64) -> Result<Client, BcError> {
        Self::open_with(url, now_us, 0, peak_us, age_us)
    }

    /// `start_us`: cold-start buffer target (0 = crate default); `peak_us`/`age_us`:
    /// stall memory of the previous session on this path (both 0 = none).
    pub fn open_with(url: &str, now_us: u64, start_us: u64, peak_us: u64, age_us: u64) -> Result<Client, BcError> {
        if !(url.to_ascii_lowercase().starts_with("http://") || url.to_ascii_lowercase().starts_with("https://")) {
            return Err(BcError::UnsupportedScheme(url.to_string()));
        }
        let mut config = Config::default();
        if start_us > 0 {
            let p = &mut config.buffer.policy;
            p.initial_us = start_us.clamp(p.min_us, p.max_us);
        }
        let seed = (peak_us > 0).then(|| buffering_runtime::StallMemorySnapshot::new(peak_us, age_us));
        let session = Session::open_with_memory(url, config, now_us, seed)?;
        Ok(Client {
            session,
            conv: Converter::new(),
            known: BTreeMap::new(),
            pending: VecDeque::new(),
            now_us,
        })
    }

    pub fn poll_action(&mut self, now_us: u64) -> Option<broadcast_client::Action> {
        self.now_us = now_us;
        self.session.poll(now_us)
    }

    pub fn poll_event(&mut self) -> Option<ClientEvent> {
        while let Some(ev) = self.session.next_event() {
            self.convert_event(ev);
        }
        self.pending.pop_front()
    }

    pub fn on_response(&mut self, conn: u32, status: u16, headers: &[(String, String)], now_us: u64) {
        self.now_us = now_us;
        self.session.on_response(conn, status, headers, now_us);
    }

    pub fn on_data(&mut self, conn: u32, bytes: &[u8], now_us: u64) {
        self.now_us = now_us;
        self.session.on_data(conn, bytes, now_us);
    }

    pub fn on_closed(&mut self, conn: u32, error: Option<String>, now_us: u64) {
        self.now_us = now_us;
        self.session.on_closed(conn, error, now_us);
    }

    pub fn set_credentials(&mut self, c: broadcast_client::Credentials) -> bool {
        self.session.set_credentials(c).is_ok()
    }

    pub fn stall_memory(&self) -> (u64, u64) {
        let s = self.session.stall_memory();
        (s.peak_us, s.age_us)
    }

    pub fn on_playback_position(&mut self, now_us: u64, pos: Option<u64>) {
        self.now_us = now_us;
        self.session.on_playback_position(now_us, pos);
    }

    pub fn set_rendered_tracks(&mut self, ids: &[u32]) {
        let tracks: Vec<transmux::TrackId> = ids.iter().copied().map(transmux::TrackId::new).collect();
        self.session.set_rendered_tracks(&tracks);
    }

    pub fn hint(&mut self, code: u32) {
        let h = match code {
            1 => broadcast_client::Hint::InputDegraded,
            2 => broadcast_client::Hint::InputRecovered,
            3 => broadcast_client::Hint::SyncLoss,
            4 => broadcast_client::Hint::PcrDiscontinuity,
            _ => return,
        };
        self.session.hint(h);
    }

    pub fn select_variant(&mut self, index: usize) -> bool {
        self.session.select_variant(index).is_ok()
    }

    pub fn reconnect(&mut self, now_us: u64) {
        self.now_us = now_us;
        self.session.reconnect(now_us);
    }

    pub fn rejoin(&mut self, track_id: u32) {
        self.session.rejoin();
        self.conv.rejoin(track_id);
    }

    pub fn close(&mut self) {
        self.session.close();
        self.pending.clear();
    }

    fn convert_event(&mut self, ev: BcEvent) {
        match ev {
            BcEvent::Tracks(set) => {
                let new_ids: std::collections::BTreeSet<u32> =
                    set.iter().map(|s| s.track_id.value()).collect();
                let mut removed: Vec<u32> =
                    self.known.keys().copied().filter(|id| !new_ids.contains(id)).collect();
                removed.sort();
                for id in removed {
                    self.conv.removed(id);
                    self.pending
                        .push_back(ClientEvent::Media(DemuxEvent::TrackRemoved(id)));
                    self.known.remove(&id);
                }
                let mut sorted: Vec<TrackSpec> = set.into_iter().collect();
                sorted.sort_by_key(|s| s.track_id.value());
                for spec in sorted {
                    let id = spec.track_id.value();
                    let is_new = !self.known.contains_key(&id);
                    let changed = match self.known.get(&id) {
                        Some(prev) => format!("{prev:?}") != format!("{spec:?}"),
                        None => false,
                    };
                    if is_new {
                        if let Some(ti) = self.conv.track(&spec) {
                            self.pending
                                .push_back(ClientEvent::Media(DemuxEvent::TrackAdded(ti)));
                        }
                    } else if changed {
                        if let Some(ti) = self.conv.track(&spec) {
                            self.pending
                                .push_back(ClientEvent::Media(DemuxEvent::TrackUpdated(ti)));
                        }
                    }
                    self.known.insert(id, spec);
                }
            }
            BcEvent::Sample { track, sample, join } => {
                if let Some(so) = self.conv.sample(track.value(), &sample, join) {
                    self.pending
                        .push_back(ClientEvent::Media(DemuxEvent::Sample(so)));
                }
            }
            BcEvent::DisplayChanged { track, pts, display } => {
                let e = self.conv.display_changed(track.value(), pts, display.geometry.as_ref());
                self.pending.push_back(ClientEvent::Media(e));
            }
            BcEvent::Discontinuity => {
                self.pending
                    .push_back(ClientEvent::Media(DemuxEvent::Discontinuity(None)));
            }
            BcEvent::Finite { expected_bytes } => {
                self.pending
                    .push_back(ClientEvent::Finite { expected_bytes });
            }
            BcEvent::Status(s) => {
                self.pending.push_back(ClientEvent::Status(s));
            }
            BcEvent::Starved(k) => {
                let with_data = matches!(k, broadcast_client::StarveKind::Data);
                self.pending
                    .push_back(ClientEvent::Starved { with_data });
            }
            BcEvent::AuthRequired {
                scheme,
                realm,
                origin,
                resource_metadata,
            } => {
                self.pending.push_back(ClientEvent::AuthRequired {
                    scheme: scheme.name().to_lowercase(),
                    realm,
                    origin: origin.to_string(),
                    resource_metadata: resource_metadata.map(|u| u.to_string()),
                });
            }
            BcEvent::AuthRejected { status } => {
                self.pending
                    .push_back(ClientEvent::AuthRejected(status));
            }
            BcEvent::Forbidden { status } => {
                self.pending.push_back(ClientEvent::Forbidden(status));
            }
            BcEvent::Buffer(be) => {
                let b = match be {
                    broadcast_client::BufferEvent::Start { at_27mhz } => {
                        Buffer::Start { at_27mhz: at_27mhz }
                    }
                    broadcast_client::BufferEvent::Pause {
                        hold_at_27mhz,
                        starving_track,
                    } => Buffer::Pause {
                        hold_at_27mhz: hold_at_27mhz,
                        starving_track: starving_track,
                    },
                    broadcast_client::BufferEvent::Resume { at_27mhz } => {
                        Buffer::Resume { at_27mhz: at_27mhz }
                    }
                    _ => return,
                };
                self.pending.push_back(ClientEvent::Buffer(b));
            }
            BcEvent::Variants(ms) => {
                let lines: Vec<String> = ms
                    .variants
                    .iter()
                    .map(|v| {
                        let bw = if v.bandwidth == 0 {
                            String::new()
                        } else {
                            v.bandwidth.to_string()
                        };
                        let res = v
                            .resolution
                            .map(|(w, h)| format!("{}x{}", w, h))
                            .unwrap_or_default();
                        let codecs = v.codecs.clone().unwrap_or_default();
                        format!("{}\t{}\t{}", bw, res, codecs)
                    })
                    .collect();
                self.pending.push_back(ClientEvent::Variants {
                    chosen: ms.chosen,
                    lines,
                });
            }
            BcEvent::Error { kind, fatal } => {
                self.pending.push_back(ClientEvent::Error {
                    name: kind.name().to_string(),
                    fatal,
                });
            }
            _ => {}
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::demux::{Demux, Event};
    use broadcast_client::Action;

    fn fixture() -> Option<Vec<u8>> {
        let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../testdata/streams/tf-1.ts");
        match std::fs::read(p) { Ok(b) => Some(b), Err(_) => { eprintln!("skip: {p} missing"); None } }
    }

    fn first_request(c: &mut Client) -> (u32, String, Vec<(String, String)>) {
        loop {
            match c.poll_action(0).expect("an action") {
                Action::HttpRequest { conn, url, headers, .. } => return (conn, url, headers),
                _ => continue,
            }
        }
    }

    fn media(c: &mut Client) -> Vec<Event> {
        let mut out = vec![];
        while let Some(e) = c.poll_event() { if let ClientEvent::Media(m) = e { out.push(m) } }
        out
    }

    #[test]
    fn tracks_diff_matches_demux() {
        let Some(bytes) = fixture() else { return };
        let mut d = Demux::new();
        d.feed(&bytes);
        let mut old = vec![];
        while let Some(e) = d.poll() { old.push(e) }

        let mut c = Client::open("http://h/stream/ts/tf-1", 0).unwrap();
        let (conn, _, _) = first_request(&mut c);
        c.on_response(conn, 200, &[("Content-Type".into(), "video/mp2t".into())], 0);
        for chunk in bytes.chunks(64 * 1024) { c.on_data(conn, chunk, 1) }
        let new = media(&mut c);

        let added = |v: &[Event]| v.iter().filter_map(|e| if let Event::TrackAdded(t) = e { Some(t.track_id) } else { None }).collect::<Vec<_>>();
        assert_eq!(added(&old), added(&new));
        let samples = |v: &[Event], id: u32| v.iter().filter(|e| matches!(e, Event::Sample(s) if s.track_id == id)).count();
        for id in added(&old) {
            let (a, b) = (samples(&old, id), samples(&new, id));
            assert_eq!(a, b, "track {id}: demux {a} samples, session {b}");
        }
    }

    #[test]
    fn redirect_issues_the_next_request() {
        let mut c = Client::open("http://a.example/live.ts", 0).unwrap();
        let (conn, _, _) = first_request(&mut c);
        c.on_response(conn, 302, &[("Location".into(), "http://b.example/live.ts".into())], 0);
        let (_, url, _) = first_request(&mut c);
        assert_eq!(url, "http://b.example/live.ts");
    }

    #[test]
    fn buffer_start_arrives_on_a_paced_feed() {
        let Some(bytes) = fixture() else { return };
        let mut c = Client::open("http://h/stream/ts/tf-1", 0).unwrap();
        let (conn, _, _) = first_request(&mut c);
        c.on_response(conn, 200, &[("Content-Type".into(), "video/mp2t".into())], 0);
        let mut started = false;
        let mut now = 0u64;
        for chunk in bytes.chunks(188 * 70) {
            now += 40_000;
            c.on_data(conn, chunk, now);
            c.on_playback_position(now, None);
            while let Some(e) = c.poll_event() {
                if let ClientEvent::Buffer(Buffer::Start { .. }) = e { started = true }
            }
            while c.poll_action(now).is_some() {}
            if started { break }
        }
        assert!(started, "a Buffer Start for a live TS feed");
    }

    #[test]
    fn m3u8_urls_open_an_hls_session() {
        let mut c = Client::open("http://h/live/index.m3u8", 0).unwrap();
        let (_, url, _) = first_request(&mut c);
        assert!(url.ends_with(".m3u8"), "first request is the playlist, got {url}");
    }

    #[test]
    fn first_request_after_credentials_is_authorized() {
        let mut c = Client::open("http://a.example/live.ts", 0).unwrap();
        let (conn, _, _) = first_request(&mut c);
        c.on_response(conn, 401, &[("WWW-Authenticate".into(), "Basic realm=\"tv\"".into())], 0);
        while c.poll_event().is_some() {}
        c.set_credentials(broadcast_client::Credentials::new("u", "p"));
        let (_, _, headers) = first_request(&mut c);
        assert!(headers.iter().any(|(k, v)| k.eq_ignore_ascii_case("authorization") && v.starts_with("Basic ")));
    }

    #[test]
    fn set_credentials_rejects_crlf_injection() {
        let mut c = Client::open("http://example.invalid/x.ts", 0).unwrap();
        assert!(!c.set_credentials(broadcast_client::Credentials::new("u", "p\r\nX: y")));
        assert!(c.set_credentials(broadcast_client::Credentials::new("u", "p")));
    }

    #[test]
    fn open_rejects_rtsp() {
        assert!(Client::open("rtsp://h/x", 0).is_err());
    }
}
