//! Non-secret configuration contract. Wire catalog is shared with playback.
use crate::{
    aa_channels::DisplayConfig,
    ipc::{Message, PayloadReader, PayloadWriter},
};
use std::path::PathBuf;

pub const MODES: [(u16, u16); 3] = [(800, 480), (1280, 720), (1920, 1080)];
pub const FPS: [u8; 2] = [30, 60];
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AudioFormat {
    pub channel: u8,
    pub role: u8,
    pub rate: u16,
    pub bits: u8,
    pub channels: u8,
    pub pipewire_role: &'static str,
}
pub const AUDIO: [AudioFormat; 3] = [
    AudioFormat {
        channel: 4,
        role: 3,
        rate: 48000,
        bits: 16,
        channels: 2,
        pipewire_role: "Music",
    },
    AudioFormat {
        channel: 5,
        role: 1,
        rate: 16000,
        bits: 16,
        channels: 1,
        pipewire_role: "Navigation",
    },
    AudioFormat {
        channel: 6,
        role: 2,
        rate: 16000,
        bits: 16,
        channels: 1,
        pipewire_role: "Notification",
    },
];
pub fn audio_format(channel: u8) -> Result<AudioFormat, String> {
    AUDIO
        .into_iter()
        .find(|f| f.channel == channel)
        .ok_or_else(|| "unsupported audio channel".into())
}
pub fn endpoint(name: &str, filename: &str) -> Result<PathBuf, String> {
    resolve_endpoint(
        std::env::var(name).ok().as_deref(),
        std::env::var("XDG_RUNTIME_DIR").ok().as_deref(),
        filename,
    )
}
pub fn resolve_endpoint(
    value: Option<&str>,
    runtime: Option<&str>,
    filename: &str,
) -> Result<PathBuf, String> {
    let path = match value {
        Some(value) => value.to_owned(),
        None => format!("{}/argo/{filename}", runtime.unwrap_or("/run")),
    };
    if !path.starts_with('/')
        || path.trim() != path
        || path.contains('\0')
        || path.len() >= 108
        || path.ends_with('/')
    {
        return Err("Projection socket must be an absolute nonempty Unix path under 108 bytes, without surrounding whitespace".into());
    }
    Ok(path.into())
}
pub fn write_display(w: &mut PayloadWriter, d: &DisplayConfig) {
    w.u16(d.width);
    w.u16(d.height);
    w.u16(d.dpi);
    w.u8(d.fps);
    w.u8(u8::from(d.right_driver));
}
pub fn read_display(r: &mut PayloadReader<'_>) -> Option<DisplayConfig> {
    let width = r.u16()?;
    let height = r.u16()?;
    let dpi = r.u16()?;
    let fps = r.u8()?;
    let side = r.u8()?;
    if side > 1 {
        return None;
    }
    Some(DisplayConfig {
        width,
        height,
        dpi,
        fps,
        right_driver: side == 1,
    })
}
pub fn capabilities(readiness: u8, detail: &str) -> Message {
    let mut w = PayloadWriter::default();
    w.u8(readiness);
    w.string(detail).unwrap();
    w.u8(MODES.len() as u8);
    for (width, height) in MODES {
        w.u16(width);
        w.u16(height);
    }
    w.u8(FPS.len() as u8);
    for fps in FPS {
        w.u8(fps);
    }
    w.u16(80);
    w.u16(640);
    write_display(&mut w, &DisplayConfig::default());
    w.u8(AUDIO.len() as u8);
    for (role, f) in AUDIO.iter().enumerate() {
        w.u8(role as u8);
        w.u16(f.rate);
        w.u8(f.bits);
        w.u8(f.channels);
    }
    Message {
        kind: 9,
        payload: w.finish(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_v2_catalog_fixture_and_endpoint_contract() {
        let hex =
            include_str!("../../../../test/fixtures/projection/ipc_v2_capabilities.hex").trim();
        let bytes: Vec<u8> = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect();
        assert_eq!(
            crate::ipc::encode(&capabilities(0, "Ready")).unwrap(),
            bytes
        );
        for f in AUDIO {
            assert_eq!(audio_format(f.channel).unwrap(), f);
            assert_eq!(f.bits, 16);
        }
        assert_eq!(
            resolve_endpoint(None, Some("/run/user/1000"), "projection.sock").unwrap(),
            PathBuf::from("/run/user/1000/argo/projection.sock")
        );
        assert_eq!(
            resolve_endpoint(None, None, "projection-video.sock").unwrap(),
            PathBuf::from("/run/argo/projection-video.sock")
        );
        for value in ["", "relative", " /tmp/test.sock", "/tmp/test.sock "] {
            assert!(resolve_endpoint(Some(value), None, "projection.sock").is_err());
        }
    }
}
