use crate::{
    aa_channels::DisplayConfig,
    identity::AndroidAutoIdentity,
    ipc::{Message, PayloadReader},
};
use tokio::sync::{broadcast, watch};

#[derive(Clone, Debug, Default)]
pub struct SessionConfig {
    pub display: DisplayConfig,
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
}
impl Default for HostControl {
    fn default() -> Self {
        let (configuration, _) = watch::channel(SessionConfig::default());
        let (commands, _) = broadcast::channel(64);
        Self {
            configuration,
            commands,
        }
    }
}
impl HostControl {
    pub fn from_environment() -> Self {
        let control = Self::default();
        control.configuration.send_modify(|config| {
            config.media_socket = std::env::var_os("ARGO_PROJECTION_MEDIA_SOCKET").map(Into::into)
        });
        if let (Ok(certificate), Ok(private_key)) = (
            std::env::var("ARGO_ANDROID_AUTO_CERT_FILE"),
            std::env::var("ARGO_ANDROID_AUTO_KEY_FILE"),
        ) {
            control.configuration.send_modify(|config| {
                config.identity = Some(AndroidAutoIdentity {
                    certificate: certificate.into(),
                    private_key: private_key.into(),
                })
            });
        }
        control
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
