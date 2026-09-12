use crate::ring::Ring;
use gstreamer::{self as gst, prelude::*};
use gstreamer_app::AppSink;
use gstreamer_video::{VideoFrameExt, VideoFrameRef, VideoInfo};
use std::time::{Duration, Instant};
struct Probe(gst::Element);
impl Drop for Probe {
    fn drop(&mut self) {
        if let Err(e) = self.0.set_state(gst::State::Null) {
            eprintln!("Camera capability probe cleanup failed: {e}");
        }
    }
}
pub struct Capture {
    pipeline: gst::Pipeline,
    sink: AppSink,
}
impl Capture {
    pub fn start(node: &str) -> Result<Self, String> {
        let source = gst::ElementFactory::make("v4l2src")
            .property("device", node)
            .build()
            .map_err(|e| e.to_string())?;
        let _probe = Probe(source.clone());
        source
            .set_state(gst::State::Ready)
            .map_err(|e| e.to_string())?;
        let modes = source
            .static_pad("src")
            .ok_or("V4L2 source has no pad")?
            .query_caps(None);
        let filter: gst::Caps = "video/x-raw,width=(int)[1,1920],height=(int)[1,1080],framerate=(fraction)[1/1,30/1];image/jpeg,width=(int)[1,1920],height=(int)[1,1080],framerate=(fraction)[1/1,30/1]".parse().map_err(|_| "Invalid camera caps")?;
        let permitted = modes.intersect(&filter);
        let mut candidates = vec![];
        for structure in permitted.iter() {
            let mut s = structure.to_owned();
            s.fixate_field_nearest_int("width", 1920);
            s.fixate_field_nearest_int("height", 1080);
            s.fixate_field_nearest_fraction("framerate", gst::Fraction::new(30, 1));
            let w = s.get::<i32>("width").unwrap_or(0);
            let h = s.get::<i32>("height").unwrap_or(0);
            let fps = s
                .get::<gst::Fraction>("framerate")
                .unwrap_or(gst::Fraction::new(0, 1));
            if w > 0
                && h > 0
                && w <= 1920
                && h <= 1080
                && fps > gst::Fraction::new(0, 1)
                && fps <= gst::Fraction::new(30, 1)
            {
                candidates.push((w * h, fps, s));
            }
        }
        source
            .set_state(gst::State::Null)
            .map_err(|e| e.to_string())?;
        candidates.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
        let (_, _, s) = candidates
            .into_iter()
            .next()
            .ok_or("No advertised raw/MJPEG capture mode at or below 1920x1080/30")?;
        let mut caps = gst::Caps::builder_full().structure(s).build();
        caps.fixate();
        eprintln!("Camera selected advertised mode: {caps}");
        // Only static pipeline text is parsed. Device paths and caps are GObject properties.
        let pipeline = gst::parse::launch("v4l2src name=camera ! capsfilter name=mode ! queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream ! decodebin ! videoconvert ! video/x-raw,format=BGRx ! appsink name=frames sync=false max-buffers=1 drop=true")
        .map_err(|e| e.to_string())?.downcast::<gst::Pipeline>().map_err(|_| "Not a pipeline")?;
        pipeline
            .by_name("camera")
            .ok_or("Missing source")?
            .set_property("device", node);
        pipeline
            .by_name("mode")
            .ok_or("Missing mode")?
            .set_property("caps", &caps);
        let sink = pipeline
            .by_name("frames")
            .ok_or("Missing sink")?
            .downcast::<AppSink>()
            .map_err(|_| "Invalid sink")?;
        let capture = Self { pipeline, sink };
        capture
            .pipeline
            .set_state(gst::State::Playing)
            .map_err(|e| e.to_string())?;
        Ok(capture)
    }
    pub fn frame(&self, ring: &mut Ring) -> Result<Option<Frame>, String> {
        if let Some(bus) = self.pipeline.bus() {
            for _ in 0..16 {
                let Some(message) = bus.pop() else { break };
                match message.view() {
                    gst::MessageView::Error(e) => return Err(e.error().to_string()),
                    gst::MessageView::Eos(_) => return Err("Camera capture ended".into()),
                    _ => {}
                }
            }
        }
        let Some(sample) = self.sink.try_pull_sample(gst::ClockTime::ZERO) else {
            return Ok(None);
        };
        let caps = sample.caps().ok_or("Missing frame caps")?;
        let info = VideoInfo::from_caps(caps).map_err(|e| e.to_string())?;
        let buffer = sample.buffer().ok_or("Missing frame buffer")?;
        let mapped =
            VideoFrameRef::from_buffer_ref_readable(buffer, &info).map_err(|e| e.to_string())?;
        let map = mapped.plane_data(0).map_err(|e| e.to_string())?;
        let seq = ring
            .write(
                map,
                info.width(),
                info.height(),
                mapped.plane_stride()[0] as u32,
                info.fps().numer() as u32,
                info.fps().denom() as u32,
            )
            .map_err(|e| e.to_string())?;
        Ok(Some(Frame {
            width: info.width(),
            height: info.height(),
            stride: mapped.plane_stride()[0],
            fps: f64::from(info.fps().numer()) / f64::from(info.fps().denom()),
            sequence: seq,
        }))
    }
    pub fn stop(&self) -> Result<(), String> {
        self.pipeline
            .set_state(gst::State::Null)
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
}
impl Drop for Capture {
    fn drop(&mut self) {
        if let Err(e) = self.stop() {
            eprintln!("Camera cleanup failed: {e}");
        }
    }
}
#[derive(Clone, Default, serde::Serialize)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub stride: i32,
    pub fps: f64,
    pub sequence: u64,
}
pub const STALE: Duration = Duration::from_millis(750);
pub const RESTART: Duration = Duration::from_secs(2);
pub struct Health {
    pub last: Instant,
    pub retries: u8,
    pub retry_at: Option<Instant>,
}
impl Health {
    pub fn new(now: Instant) -> Self {
        Self {
            last: now,
            retries: 0,
            retry_at: None,
        }
    }
    pub fn stale(&self, now: Instant) -> bool {
        now.duration_since(self.last) >= STALE
    }
    pub fn restart_due(&self, now: Instant) -> bool {
        now.duration_since(self.last) >= RESTART
    }
    pub fn failed(&mut self, now: Instant) -> bool {
        if self.retries >= 3 {
            return false;
        }
        self.retries += 1;
        self.retry_at = Some(now + Duration::from_secs(u64::from(self.retries)));
        true
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_bounded_recovery_and_fresh_start() {
        let now = Instant::now();
        let mut h = Health::new(now);
        assert!(!h.stale(now + Duration::from_millis(749)));
        assert!(h.stale(now + STALE));
        assert!(h.restart_due(now + RESTART));
        for _ in 0..3 {
            assert!(h.failed(now));
        }
        assert!(!h.failed(now));
        assert!(!Health::new(now + Duration::from_secs(99)).stale(now + Duration::from_secs(99)));
    }
}
