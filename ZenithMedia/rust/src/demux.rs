//! StreamingTsDemux → flat events for the Apple side. No parsing of its own:
//! every field comes from transmux (codec config, timing, RAP detection).

use broadcast_common::Serialize;
use transmux::ir::{CodecConfig, DemuxEvent, DisplayGeometry, DisplayInfo, TrackSpec};
use transmux::{
    access_unit_is_rap, video_picture_facts, DropReason, JoinDecision, LiveJoin, NalCodec, StreamingTsDemux,
    VideoScan,
};

/// R1: role of an audio track (transmux AudioRole).
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioRole {
    Unknown = 0,
    Main = 1,
    AudioDescription = 2,
    HearingImpaired = 3,
}

/// R3: how a video track is coded (transmux VideoScan).
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scan {
    Unknown = 0,
    Progressive = 1,
    Paff = 2,
    Mbaff = 3,
    FieldSequence = 4,
}

/// R4: live-join decision for a video sample (transmux JoinDecision).
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Join {
    Keep = 0,
    JoinPoint = 1,
    DropBeforeRap = 2,
    DropNotSelfContained = 3,
    DropLeading = 4,
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    Other = 0,
    H264 = 1,
    Hevc = 2,
    Aac = 3,
    Ac3 = 4,
    Eac3 = 5,
    MpegAudio = 6,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TrackInfo {
    pub track_id: u32,
    pub codec: Codec,
    pub timescale: u32,
    pub width: u16,
    pub height: u16,
    pub channels: u16,
    pub sample_rate: u32,
    pub pid: u16,
    /// avcC / hvcC record (box header stripped), dac3 / dec3 payload,
    /// ES_Descriptor (esds without box/fullbox header); empty for MPEG audio.
    pub config: Vec<u8>,
    /// Raw PMT ES_info descriptor loop (ISO/IEC 13818-1 §2.4.4.8).
    pub descriptors: Vec<u8>,
    /// Audio: first ISO 639 language code ("" if none) and role (R1).
    pub language: String,
    pub role: AudioRole,
    /// Audio: nominal bitrate in bit/s, 0 if unknown (R2).
    pub bitrate: u32,
    /// Video: coding scan type (R3).
    pub scan: Scan,
    /// Video: sample (pixel) aspect ratio from the SPS VUI, as signalled;
    /// None when unspecified (no VUI, idc 0, reserved, zero term).
    pub pixel_aspect: Option<(u16, u16)>,
    /// Video: the signalled colour description (H.264/H.265 VUI video signal
    /// type with colour_description_present_flag); None when not signalled.
    /// Unsignalled is not BT.709: the player falls back by resolution.
    pub colour: Option<Colour>,
}

/// A wire colour description: primaries / transfer / matrix code points
/// (H.264 Table E-2..E-5) and the full-range flag.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Colour {
    pub primaries: u8,
    pub transfer: u8,
    pub matrix: u8,
    pub full_range: bool,
}

/// Pixel aspect and colour of one access unit (transmux DisplayInfo).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Geometry {
    pub pixel_aspect: Option<(u16, u16)>,
    pub colour: Option<Colour>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SampleOut {
    pub track_id: u32,
    pub pts: i64,
    pub dts: i64,
    pub duration: u32,
    pub is_sync: bool,
    pub is_rap: bool,
    /// Video: live-join decision (R4); audio: Keep.
    pub join: Join,
    /// Video: coded fields in the sample (0 frame, 1 lone field, 2 pair) and
    /// field order when known (R3).
    pub fields: u8,
    pub bottom_field_first: Option<bool>,
    pub data: Vec<u8>,
    /// Video: the display state in force for this access unit.
    pub geometry: Option<Geometry>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    TrackAdded(TrackInfo),
    TrackUpdated(TrackInfo),
    TrackRemoved(u32),
    Sample(SampleOut),
    Discontinuity(Option<u32>),
    /// A video track's display state changed (or was first known, `initial`),
    /// emitted right before the first sample it applies to; dts/pts are that
    /// sample's. The sample's own geometry travels in `SampleOut.geometry`.
    DisplayChanged {
        track_id: u32,
        pts: Option<i64>,
        /// None: outside the join, when this precedes the first sample.
        geometry: Option<Geometry>,
    },
}

pub struct Demux {
    inner: StreamingTsDemux,
    codecs: std::collections::HashMap<u32, Codec>,
    configs: std::collections::HashMap<u32, CodecConfig>,
    joins: std::collections::HashMap<u32, LiveJoin>,
    /// Display geometry announced by the last DisplayChanged of each video
    /// track (transmux DisplayInfo), until its TrackUpdated carries it.
    geometries: std::collections::HashMap<u32, DisplayGeometry>,
    /// Newest PCR seen (27 MHz), for the live-buffer jitter estimator.
    last_pcr_27mhz: Option<u64>,
}

impl Default for Demux {
    fn default() -> Self {
        Self::new()
    }
}

impl Demux {
    pub fn new() -> Self {
        Demux {
            inner: StreamingTsDemux::new(),
            codecs: Default::default(),
            configs: Default::default(),
            joins: Default::default(),
            geometries: Default::default(),
            last_pcr_27mhz: None,
        }
    }
    pub fn feed(&mut self, bytes: &[u8]) {
        self.inner.feed(bytes);
    }
    pub fn finish(&mut self) {
        self.inner.finish();
    }
    /// Restart the live join on a video track (after a decoder reset or a
    /// discontinuity): samples are dropped again until the next join point.
    pub fn rejoin(&mut self, track_id: u32) {
        if let Some(j) = self.joins.get_mut(&track_id) {
            j.rejoin();
        }
    }

    /// The newest PCR seen since the last call, in 27 MHz ticks (taken: a
    /// second call returns None until another PCR arrives).
    pub fn take_last_pcr(&mut self) -> Option<u64> {
        self.last_pcr_27mhz.take()
    }

    pub fn poll(&mut self) -> Option<Event> {
        while let Some(ev) = self.inner.poll_event() {
            if let Some(e) = self.convert(ev) {
                return Some(e);
            }
        }
        None
    }

    fn convert(&mut self, ev: DemuxEvent) -> Option<Event> {
        match ev {
            DemuxEvent::TrackAdded(spec) => {
                let t = track_info(&spec)?;
                self.remember(&spec, &t);
                Some(Event::TrackAdded(t))
            }
            DemuxEvent::TrackUpdated(spec) => {
                let t = track_info(&spec)?;
                self.remember(&spec, &t);
                Some(Event::TrackUpdated(t))
            }
            DemuxEvent::TrackRemoved { track_id, .. } => {
                let track_id = track_id.value();
                self.codecs.remove(&track_id);
                self.geometries.remove(&track_id);
                Some(Event::TrackRemoved(track_id))
            }
            DemuxEvent::DisplayChanged { track_id, pts, .. } => {
                let track_id = track_id.value();
                let sample_pts = pts;
                let geometry = self.geometries.get(&track_id).map(geometry_of_geometry);
                Some(Event::DisplayChanged { track_id, pts: sample_pts, geometry })
            }
            DemuxEvent::Sample { track_id, sample, .. } => {
                let track_id = track_id.value();
                let codec = *self.codecs.get(&track_id).unwrap_or(&Codec::Other);
                let is_rap = match codec {
                    Codec::H264 => access_unit_is_rap(NalCodec::Avc, &sample.data, true),
                    Codec::Hevc => access_unit_is_rap(NalCodec::Hevc, &sample.data, true),
                    _ => true,
                };
                let pts = sample.pts.or(sample.dts)?;
                let join = match self.joins.get_mut(&track_id).map(|j| j.push(&sample)) {
                    None | Some(JoinDecision::Keep) => Join::Keep,
                    Some(JoinDecision::JoinPoint(_)) => Join::JoinPoint,
                    Some(JoinDecision::Drop(DropReason::LeadingPicture)) => Join::DropLeading,
                    Some(JoinDecision::Drop(DropReason::NotSelfContained)) => Join::DropNotSelfContained,
                    Some(JoinDecision::Drop(_)) => Join::DropBeforeRap,
                    Some(_) => Join::Keep,
                };
                let facts = self.configs.get(&track_id).and_then(|c| video_picture_facts(c, &sample.data));
                Some(Event::Sample(SampleOut {
                    track_id,
                    pts,
                    dts: sample.dts.unwrap_or(pts),
                    duration: sample.duration.unwrap_or(0),
                    is_sync: sample.flags.is_sync,
                    is_rap,
                    join,
                    fields: facts.map_or(0, |f| f.fields),
                    bottom_field_first: facts.and_then(|f| f.bottom_field_first),
                    data: sample.data.to_vec(),
                    geometry: Some(geometry_of(sample.display.as_deref())),
                }))
            }
            DemuxEvent::Discontinuity { track, .. } => Some(Event::Discontinuity(track.map(|t| t.value()))),
            DemuxEvent::ClockReference { ticks, clock_hz, .. } => {
                if clock_hz > 0 {
                    self.last_pcr_27mhz = Some(((ticks as u128) * 27_000_000 / clock_hz as u128) as u64);
                }
                None
            }
            _ => None,
        }
    }
}

impl Demux {
    fn remember(&mut self, spec: &TrackSpec, t: &TrackInfo) {
        self.codecs.insert(t.track_id, t.codec);
        match spec.display.clone() {
            Some(g) => self.geometries.insert(t.track_id, g),
            None => self.geometries.remove(&t.track_id),
        };
        if matches!(t.codec, Codec::H264 | Codec::Hevc) {
            self.configs.insert(t.track_id, spec.config.clone());
            if !self.joins.contains_key(&t.track_id) {
                if let Some(j) = LiveJoin::for_config(&spec.config) {
                    self.joins.insert(t.track_id, j);
                }
            }
        }
    }
}

/// None when the codec configuration can't be serialized (damaged input,
/// e.g. a garbage parameter set over 64 KB): the event is dropped and the
/// track keeps its previous configuration.
fn track_info(spec: &TrackSpec) -> Option<TrackInfo> {
    let mut t = TrackInfo {
        track_id: spec.track_id.value(),
        codec: Codec::Other,
        timescale: spec.timescale,
        width: 0,
        height: 0,
        channels: 0,
        sample_rate: 0,
        pid: spec.source_pid.map_or(0, |p| p.value()),
        config: Vec::new(),
        descriptors: spec.es_info_descriptors.clone(),
        language: String::new(),
        role: AudioRole::Unknown,
        bitrate: spec.config.nominal_bitrate().unwrap_or(0),
        scan: match spec.config.video_scan() {
            Some(VideoScan::Progressive) => Scan::Progressive,
            Some(VideoScan::Paff) => Scan::Paff,
            Some(VideoScan::Mbaff) => Scan::Mbaff,
            Some(VideoScan::FieldSequence) => Scan::FieldSequence,
            _ => Scan::Unknown,
        },
        pixel_aspect: spec.display.as_ref().and_then(|d| d.sample_aspect_ratio()),
        colour: spec.display.as_ref().and_then(colour_of),
    };
    let meta = spec.audio_metadata();
    t.language = meta.languages.first().map(|l| l.language.clone()).unwrap_or_default();
    t.role = match meta.role {
        transmux::AudioRole::Main => AudioRole::Main,
        transmux::AudioRole::AudioDescription => AudioRole::AudioDescription,
        transmux::AudioRole::HearingImpaired => AudioRole::HearingImpaired,
        _ => AudioRole::Unknown,
    };
    match &spec.config {
        CodecConfig::Avc { config, width, height, .. } => {
            t.codec = Codec::H264;
            (t.width, t.height) = (*width, *height);
            t.config = config.try_to_bytes().ok()?[8..].to_vec(); // strip 8-byte box header
        }
        CodecConfig::Hevc { config, width, height, .. } => {
            t.codec = Codec::Hevc;
            (t.width, t.height) = (*width, *height);
            t.config = config.try_to_bytes().ok()?[8..].to_vec();
        }
        CodecConfig::Aac { esds, channel_count, sample_rate, .. } => {
            t.codec = Codec::Aac;
            (t.channels, t.sample_rate) = (*channel_count, *sample_rate);
            t.config = esds.try_to_bytes().ok()?[12..].to_vec(); // strip box (8) + fullbox (4) header
        }
        CodecConfig::Ac3 { config, sample_rate, .. } => {
            t.codec = Codec::Ac3;
            (t.channels, t.sample_rate) = (spec.config.channels_with_lfe().unwrap_or(0), *sample_rate);
            t.config = config.try_to_bytes().ok()?;
        }
        CodecConfig::Eac3 { config, sample_rate, .. } => {
            t.codec = Codec::Eac3;
            (t.channels, t.sample_rate) = (spec.config.channels_with_lfe().unwrap_or(0), *sample_rate);
            t.config = config.try_to_bytes().ok()?;
        }
        CodecConfig::MpegAudio { channel_count, sample_rate, .. } => {
            t.codec = Codec::MpegAudio;
            (t.channels, t.sample_rate) = (*channel_count, *sample_rate);
        }
        _ => {}
    }
    Some(t)
}

/// The signalled colour description of a track (None: no video signal type or
/// no colour description present). Inferred VUI defaults are not signalled.
fn colour_of(g: &DisplayGeometry) -> Option<Colour> {
    let vst = g.video_signal?;
    let c = vst.colour?;
    Some(Colour {
        primaries: c.primaries.code(),
        transfer: c.transfer.code(),
        matrix: c.matrix.code(),
        full_range: vst.full_range,
    })
}

/// Pixel aspect and colour of a display state (sample's own, else the
/// track's static geometry, else nothing signalled).
fn geometry_of(display: Option<&DisplayInfo>) -> Geometry {
    display.and_then(|d| d.geometry.as_ref()).map_or(Geometry { pixel_aspect: None, colour: None }, geometry_of_geometry)
}

fn geometry_of_geometry(g: &DisplayGeometry) -> Geometry {
    Geometry { pixel_aspect: g.sample_aspect_ratio(), colour: colour_of(g) }
}
