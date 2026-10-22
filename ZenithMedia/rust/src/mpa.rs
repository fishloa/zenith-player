//! MPEG-1/2 audio Layer II → interleaved s16, via oxideav-mp2 (MIT).
//! A stream is classified once, on its first frame: if it carries the
//! ISO/IEC 13818-3 multichannel extension it is decoded with the MC decoder
//! (presentation channels + LFE), otherwise as plain Layer II.

use oxideav_mp2::frame::{decode_frame_with, FrameDecodeState};
use oxideav_mp2::mc::{decode_mc_frame_with, has_mc_extension, McChannel, McDecodeState};

#[derive(Debug)]
pub struct MpaError;

pub struct PcmFrame<'a> {
    pub samples: &'a [i16],
    pub channels: u32,
    pub sample_rate: u32,
    pub labels: &'a [u32],
}

pub struct Mpa {
    base: FrameDecodeState,
    mc: McDecodeState,
    is_mc: Option<bool>,
    pcm: Vec<i16>,
    labels: Vec<u32>,
}

impl Default for Mpa {
    fn default() -> Self {
        Self::new()
    }
}

/// Linear interpolation of the LFE channel (decoded at Fs/96, 12 samples per
/// frame, ISO/IEC 13818-3 §2.5.3.2.4) up to `n` samples at Fs.
pub fn upsample_lfe(lfe: &[f64], n: usize) -> Vec<f64> {
    if lfe.is_empty() || n == 0 {
        return vec![0.0; n];
    }
    let step = n as f64 / lfe.len() as f64;
    (0..n)
        .map(|i| {
            let pos = i as f64 / step;
            let k = pos.floor() as usize;
            let frac = pos - k as f64;
            let a = lfe[k.min(lfe.len() - 1)];
            let b = lfe[(k + 1).min(lfe.len() - 1)];
            a + (b - a) * frac
        })
        .collect()
}

fn label(c: &McChannel) -> u32 {
    match c {
        McChannel::Left => 1,
        McChannel::Right => 2,
        McChannel::Centre => 3,
        McChannel::LeftSurround => 5,
        McChannel::RightSurround => 6,
        McChannel::MonoSurround => 9,
        _ => 0,
    }
}

impl Mpa {
    pub fn new() -> Self {
        Mpa { base: FrameDecodeState::new(), mc: McDecodeState::new(), is_mc: None, pcm: Vec::new(), labels: Vec::new() }
    }

    pub fn decode(&mut self, frame: &[u8]) -> Result<PcmFrame<'_>, MpaError> {
        let is_mc = *self.is_mc.get_or_insert_with(|| has_mc_extension(frame));
        let (planes, rate): (Vec<Vec<f64>>, u32) = if is_mc {
            let (f, _) = decode_mc_frame_with(frame, None, &mut self.mc).map_err(|_| MpaError)?;
            self.labels = f.layout.iter().map(label).collect();
            let mut planes = f.channels;
            if planes.is_empty() || planes.iter().any(|p| p.len() != planes[0].len()) {
                return Err(MpaError);
            }
            if let Some(lfe) = f.lfe {
                planes.push(upsample_lfe(&lfe, planes[0].len()));
                self.labels.push(4);
            }
            (planes, f.base_header.sample_rate)
        } else {
            let f = decode_frame_with(frame, &mut self.base).map_err(|_| MpaError)?;
            self.labels = if f.pcm.len() == 1 { vec![42] } else { vec![1, 2] };
            (f.pcm, f.header.sample_rate)
        };
        if planes.is_empty() || planes.iter().any(|p| p.len() != planes[0].len()) {
            return Err(MpaError);
        }
        let n = planes[0].len();
        self.pcm.clear();
        self.pcm.reserve(n * planes.len());
        for i in 0..n {
            for p in &planes {
                self.pcm.push((p[i] * 32768.0).round().clamp(-32768.0, 32767.0) as i16);
            }
        }
        Ok(PcmFrame { samples: &self.pcm, channels: planes.len() as u32, sample_rate: rate, labels: &self.labels })
    }
}
