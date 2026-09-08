//! Attempt-local, sticky readiness, independent of presentation focus.
use tokio::sync::watch;
#[derive(Clone)]
pub struct Readiness(watch::Sender<bool>);
impl Default for Readiness {
    fn default() -> Self {
        Self(watch::channel(false).0)
    }
}
impl Readiness {
    /// Only the engine's validated video AV START calls this, never focus/TLS.
    pub fn establish(&self) {
        self.0.send_replace(true);
    }
    pub async fn setup_deadline(&self) {
        let mut ready = self.0.subscribe();
        let established = tokio::select! {
            biased;
            _ = async { let _ = ready.wait_for(|value| *value).await; } => true,
            _ = tokio::time::sleep(std::time::Duration::from_secs(180)) => false,
        };
        if established {
            std::future::pending::<()>().await;
        }
    }
}
