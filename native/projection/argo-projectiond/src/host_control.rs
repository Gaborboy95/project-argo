use crate::{
    aa_channels::DisplayConfig,
    identity::AndroidAutoIdentity,
    ipc::{Message, PayloadReader},
};
use std::sync::Arc;
use tokio::sync::{Semaphore, broadcast, watch};

#[derive(Clone, Debug, Default)]
pub struct SessionConfig {
    pub display: DisplayConfig,
    pub active: Option<(String, DisplayConfig)>,
    pub identity: Option<AndroidAutoIdentity>,
    pub media_socket: Option<std::path::PathBuf>,
}
#[derive(Clone, Debug)]
pub enum Command {
    Disconnect(String),
    Activate(String),
    Touch(String, u16, u8, f32, f32),
    Visibility(String, bool),
    Gain(String, String, f32),
}
#[derive(Clone)]
pub struct HostControl {
    pub configuration: watch::Sender<SessionConfig>,
    pub commands: broadcast::Sender<Command>,
    pub client_lease: Arc<Semaphore>,
    pub readiness: u8,
    pub readiness_detail: String,
}
impl Default for HostControl {
    fn default() -> Self {
        let (configuration, _) = watch::channel(SessionConfig::default());
        let (commands, _) = broadcast::channel(64);
        Self {
            configuration,
            commands,
            client_lease: Arc::new(Semaphore::new(1)),
            readiness: 1,
            readiness_detail: "Configure ARGO_ANDROID_AUTO_CERT_FILE and ARGO_ANDROID_AUTO_KEY_FILE on argo-projectiond, then restart it.".into(),
        }
    }
}
impl HostControl {
    pub fn from_environment() -> Self {
        let mut control = Self::default();
        match crate::configuration::endpoint(
            "ARGO_PROJECTION_MEDIA_SOCKET",
            "projection-video.sock",
        ) {
            Ok(path) => control
                .configuration
                .send_modify(|config| config.media_socket = Some(path)),
            Err(error) => {
                control.readiness = 3;
                control.readiness_detail = error;
                return control;
            }
        }
        if let (Ok(certificate), Ok(private_key)) = (
            std::env::var("ARGO_ANDROID_AUTO_CERT_FILE"),
            std::env::var("ARGO_ANDROID_AUTO_KEY_FILE"),
        ) {
            let identity = AndroidAutoIdentity {
                certificate: certificate.into(),
                private_key: private_key.into(),
            };
            match crate::aa_tls::AaTls::new(&identity) {
                Ok(_) => {
                    control.readiness = 0;
                    control.readiness_detail = "Ready".into();
                    control
                        .configuration
                        .send_modify(|config| config.identity = Some(identity));
                }
                Err(error) => {
                    control.readiness = 2;
                    control.readiness_detail = format!(
                        "Daemon identity invalid: {error}. Check daemon identity files and restart."
                    );
                }
            }
        }
        if control.readiness == 0
            && !cfg!(all(
                target_os = "linux",
                feature = "linux-usb",
                feature = "linux-media"
            ))
        {
            control.readiness = 3;
            control.readiness_detail =
                "Rebuild argo-projectiond with linux-usb,linux-media.".into();
        }
        control
    }
    pub fn begin_session(&self, id: &str) -> SessionSelection {
        let mut frozen = None;
        self.configuration.send_modify(|config| {
            let selected = config
                .active
                .as_ref()
                .filter(|(session, _)| session == id)
                .map(|(_, d)| d.clone())
                .unwrap_or_else(|| config.display.clone());
            config.active = Some((id.into(), selected.clone()));
            let mut snapshot = config.clone();
            snapshot.display = selected;
            frozen = Some(snapshot);
        });
        SessionSelection {
            config: frozen.unwrap(),
            control: self.clone(),
            id: id.into(),
        }
    }
    pub fn configuration_message(&self, revision: u32, accepted: bool, reason: &str) -> Message {
        let config = self.configuration.borrow();
        let mut w = crate::ipc::PayloadWriter::default();
        w.u32(revision);
        w.u8(u8::from(accepted));
        w.string(reason).unwrap();
        crate::configuration::write_display(&mut w, &config.display);
        if let Some((id, display)) = &config.active {
            w.string(id).unwrap();
            crate::configuration::write_display(&mut w, display);
        } else {
            w.string("").unwrap();
        }
        Message {
            kind: 10,
            payload: w.finish(),
        }
    }
    pub fn command(&self, message: &Message) -> Result<(), String> {
        let mut reader = PayloadReader::new(&message.payload);
        let target = reader.string().ok_or("missing command target")?;
        let command = match message.kind {
            21 => Command::Disconnect(target),
            22 => Command::Activate(target),
            23 => Command::Touch(
                target,
                reader.u16().ok_or("missing pointer")?,
                reader.u8().ok_or("missing phase")?,
                reader.f32().ok_or("missing x")?,
                reader.f32().ok_or("missing y")?,
            ),
            26 => Command::Visibility(
                target,
                match reader.u8() {
                    Some(0) => false,
                    Some(1) => true,
                    _ => return Err("invalid visibility".into()),
                },
            ),
            27 => {
                let stream = reader.string().ok_or("missing stream")?;
                let gain = reader.f32().ok_or("missing gain")?;
                if !gain.is_finite() || !(0.0..=1.0).contains(&gain) {
                    return Err("invalid gain".into());
                }
                Command::Gain(target, stream, gain)
            }
            _ => return Err("unsupported projection command".into()),
        };
        if !reader.done() {
            return Err("trailing projection command bytes".into());
        }
        // A view's disposal may race unplug. With no live session, discard
        // commands immediately; never retain them for the next phone.
        let _ = self.commands.send(command);
        Ok(())
    }
}

/// Drop also runs when the session future is cancelled on unplug/shutdown.
pub struct SessionSelection {
    pub config: SessionConfig,
    control: HostControl,
    id: String,
}
impl Drop for SessionSelection {
    fn drop(&mut self) {
        self.control.configuration.send_modify(|config| {
            if config.active.as_ref().is_some_and(|(id, _)| id == &self.id) {
                config.active = None;
            }
        });
    }
}
