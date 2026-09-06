//! Session-owned native media. Only descriptors and gains cross Dart IPC.
use std::{path::PathBuf, time::Duration};
use tokio::{io::AsyncWriteExt, net::UnixListener, sync::mpsc, task::JoinHandle};

pub struct VideoFeed {
    tx: mpsc::Sender<Vec<u8>>,
    task: Option<JoinHandle<()>>,
    path: PathBuf,
}
impl VideoFeed {
    pub fn open(path: PathBuf) -> Result<Self, String> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        if let Some(parent) = path.parent() {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .map_err(|e| format!("native video socket directory: {e}"))?;
        }
        let listener =
            UnixListener::bind(&path).map_err(|e| format!("native video socket: {e}"))?;
        if let Err(e) = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)) {
            let _ = std::fs::remove_file(&path);
            return Err(e.to_string());
        }
        crate::daemon_log!(Info, "media", "video socket {}", path.display());
        let (tx, mut rx) = mpsc::channel::<Vec<u8>>(8);
        let task = tokio::spawn(async move {
            let mut client: Option<tokio::net::UnixStream> = None;
            let mut parameters: Vec<Vec<u8>> = Vec::new();
            loop {
                tokio::select! {
                    accepted=listener.accept()=>match accepted {
                        Ok((mut socket, _)) => {
                            crate::daemon_log!(Debug, "native-playback",
                                "Native projection video socket accepted; cached_parameters={}",
                                parameters.len()
                            );

                            let mut healthy = true;

                            for (index, bytes) in parameters.iter().enumerate() {
                                crate::daemon_log!(Debug, "native-playback",
                                    "Native projection video replay parameter {} bytes={}",
                                    index,
                                    bytes.len()
                                );

                                match tokio::time::timeout(
                                    Duration::from_secs(1),
                                    socket.write_all(bytes),
                                )
                                .await
                                {
                                    Ok(Ok(())) => {}
                                    Ok(Err(e)) => {
                                        crate::daemon_log!(Error, "native-playback",
                                            "Native projection parameter replay write failed: {e}"
                                        );
                                        healthy = false;
                                        break;
                                    }
                                    Err(_) => {
                                        crate::daemon_log!(Error, "native-playback",
                                            "Native projection parameter replay timed out"
                                        );
                                        healthy = false;
                                        break;
                                    }
                                }
                            }

                            if healthy {
                                client = Some(socket);
                                crate::daemon_log!(Debug, "native-playback", "Native projection video consumer attached");
                            }
                        },
                        Err(e)=>{crate::daemon_log!(Error, "native-playback", "Native video accept failed: {e}");break;}
                    },
                    bytes=rx.recv()=>{
                        let Some(bytes)=bytes else {break};
                        for nal in annex_b_units(&bytes) {
                            if matches!(nal.0,7|8) && nal.1.len()<=64*1024 {
                                parameters.retain(|old| nal_type(old)!=Some(nal.0));
                                parameters.push(nal.1.to_vec());
                            }
                        }
                        if let Some(socket)=client.as_mut()
                            && !matches!(tokio::time::timeout(Duration::from_secs(1),socket.write_all(&bytes)).await,Ok(Ok(()))) {
                            client=None; crate::daemon_log!(Warn, "native-playback", "Native projection view detached or stalled; waiting for recreation");
                        }
                    }
                }
            }
        });
        Ok(Self {
            tx,
            task: Some(task),
            path,
        })
    }
    pub fn push(&self, bytes: Vec<u8>) -> Result<(), String> {
        self.tx
            .try_send(bytes)
            .map_err(|_| "native video feed stalled (bounded queue full)".into())
    }
    pub async fn close(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
            let _ = task.await;
        }
        let _ = std::fs::remove_file(&self.path);
    }
}
impl Drop for VideoFeed {
    fn drop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
        let _ = std::fs::remove_file(&self.path);
    }
}
fn nal_type(bytes: &[u8]) -> Option<u8> {
    let offset = if bytes.starts_with(&[0, 0, 0, 1]) {
        4
    } else if bytes.starts_with(&[0, 0, 1]) {
        3
    } else {
        return None;
    };
    bytes.get(offset).map(|b| b & 31)
}

/// Kept outside the cancellable wire-engine future so unplug awaits native
/// feed cleanup before a replacement USB session starts.
#[derive(Default)]
pub struct SessionMedia {
    pub video: Option<VideoFeed>,
    pub audio: std::collections::BTreeMap<u8, AudioPlayback>,
}
impl SessionMedia {
    pub async fn close(&mut self) {
        if !self.audio.is_empty() {
            crate::daemon_log!(Info, "media", "session audio streams stopped");
        }
        self.audio.clear();
        if let Some(mut video) = self.video.take() {
            video.close().await;
            crate::daemon_log!(Info, "media", "session video stream stopped");
        }
    }
}
fn annex_b_units(bytes: &[u8]) -> Vec<(u8, &[u8])> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 < bytes.len() {
        let length = if bytes[i..].starts_with(&[0, 0, 0, 1]) {
            4
        } else if bytes[i..].starts_with(&[0, 0, 1]) {
            3
        } else {
            i += 1;
            continue;
        };
        starts.push(i);
        i += length;
    }
    starts
        .iter()
        .enumerate()
        .filter_map(|(i, &start)| {
            let nal = &bytes[start..starts.get(i + 1).copied().unwrap_or(bytes.len())];
            Some((nal_type(nal)?, nal))
        })
        .collect()
}

#[cfg(all(target_os = "linux", feature = "linux-media"))]
mod audio {
    use gstreamer::{self as gst, prelude::*};
    use gstreamer_app::AppSrc;
    pub struct AudioPlayback {
        pipeline: gst::Pipeline,
        input: AppSrc,
        gain: gst::Element,
    }
    impl AudioPlayback {
        pub fn open(channel: u8) -> Result<Self, String> {
            gst::init().map_err(|e| e.to_string())?;
            let format = crate::configuration::audio_format(channel)?;
            let (rate, channels, role) = (
                i32::from(format.rate),
                i32::from(format.channels),
                format.pipewire_role,
            );
            let pipeline=gst::parse::launch(&format!("appsrc name=input is-live=true format=time do-timestamp=true max-bytes=1048576 ! queue max-size-bytes=1048576 max-size-buffers=32 max-size-time=0 ! audioconvert ! audioresample ! volume name=source_gain ! pipewiresink stream-properties=\"props,media.role=(string){role}\""))
                .map_err(|e|format!("native audio pipeline: {e}"))?.downcast::<gst::Pipeline>().map_err(|_|"invalid native audio pipeline")?;
            let input = pipeline
                .by_name("input")
                .ok_or("audio appsrc missing")?
                .downcast::<AppSrc>()
                .map_err(|_| "invalid audio appsrc")?;
            input.set_caps(Some(
                &gst::Caps::builder("audio/x-raw")
                    .field("format", "S16LE")
                    .field("layout", "interleaved")
                    .field("rate", rate)
                    .field("channels", channels)
                    .build(),
            ));
            let gain = pipeline
                .by_name("source_gain")
                .ok_or("audio source gain missing")?;
            pipeline
                .set_state(gst::State::Playing)
                .map_err(|e| e.to_string())?;
            Ok(Self {
                pipeline,
                input,
                gain,
            })
        }
        pub fn push(&self, bytes: Vec<u8>) -> Result<(), String> {
            if let Some(bus) = self.pipeline.bus() {
                while let Some(message) = bus.pop() {
                    if let gst::MessageView::Error(e) = message.view() {
                        return Err(format!("native audio: {}", e.error()));
                    }
                }
            }
            if self.input.current_level_bytes() > 1024 * 1024 {
                return Err("native audio backpressure limit".into());
            }
            self.input
                .push_buffer(gst::Buffer::from_mut_slice(bytes))
                .map_err(|e| e.to_string())?;
            Ok(())
        }
        pub fn gain(&self, value: f64) -> Result<(), String> {
            if !value.is_finite() || !(0.0..=1.0).contains(&value) {
                return Err("invalid source gain".into());
            }
            self.gain.set_property("volume", value);
            Ok(())
        }
    }
    impl Drop for AudioPlayback {
        fn drop(&mut self) {
            let _ = self.pipeline.set_state(gst::State::Null);
        }
    }
}
#[cfg(all(target_os = "linux", feature = "linux-media"))]
pub use audio::AudioPlayback;
#[cfg(not(all(target_os = "linux", feature = "linux-media")))]
pub struct AudioPlayback;
#[cfg(not(all(target_os = "linux", feature = "linux-media")))]
impl AudioPlayback {
    pub fn open(_: u8) -> Result<Self, String> {
        Err("native audio unavailable: build on Linux with --features linux-usb,linux-media".into())
    }
    pub fn push(&self, _: Vec<u8>) -> Result<(), String> {
        Err("native audio unavailable".into())
    }
    pub fn gain(&self, _: f64) -> Result<(), String> {
        Err("native audio unavailable".into())
    }
}
