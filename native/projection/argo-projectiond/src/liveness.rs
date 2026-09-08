//! Wireless operational policy, independent of presentation and setup deadlines.
use crate::{
    aa_channels::{Proto, numbers},
    failure::{Failure, Kind},
};
use std::{
    collections::VecDeque,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{sync::watch, time::Instant};

/// Development target, not a protocol-mandated timeout. USB does not use it.
pub const WIRELESS_PEER_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_PENDING: usize = 8;
#[derive(Clone, Copy, Default)]
struct Activity {
    valid: Option<Instant>,
    matched: Option<Instant>,
}
pub(crate) struct Liveness {
    activity: watch::Sender<Activity>,
    pending: VecDeque<(u64, Instant)>,
}
impl Default for Liveness {
    fn default() -> Self {
        Self {
            activity: watch::channel(Activity::default()).0,
            pending: VecDeque::new(),
        }
    }
}
impl Liveness {
    pub fn establish(&self) {
        self.activity.send_if_modified(|a| {
            if a.valid.is_some() {
                false
            } else {
                a.valid = Some(Instant::now());
                true
            }
        });
    }
    pub fn valid(&self) {
        self.activity.send_if_modified(|a| {
            if a.valid.is_none() {
                false
            } else {
                a.valid = Some(Instant::now());
                true
            }
        });
    }
    pub fn request(&mut self) -> Vec<u8> {
        // Preserve the existing microsecond timestamp field. Strict uniqueness also
        // prevents a previous session's response from matching after clock rollback.
        static LAST: AtomicU64 = AtomicU64::new(0);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros() as u64;
        let old = LAST
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |old| {
                Some(now.max(old + 1))
            })
            .unwrap();
        let timestamp = now.max(old + 1);
        self.pending
            .retain(|(_, sent)| sent.elapsed() < WIRELESS_PEER_TIMEOUT);
        if self.pending.len() == MAX_PENDING {
            self.pending.pop_front();
        }
        self.pending.push_back((timestamp, Instant::now()));
        Proto::default().number(1, timestamp).finish()
    }
    pub fn response(&mut self, body: &[u8]) -> bool {
        let Ok(fields) = numbers(body) else {
            return false;
        };
        let Some(timestamp) = fields.get(&1) else {
            return false;
        };
        let Some(index) = self
            .pending
            .iter()
            .position(|(t, sent)| t == timestamp && sent.elapsed() < WIRELESS_PEER_TIMEOUT)
        else {
            return false;
        };
        self.pending.remove(index);
        self.activity.send_modify(|a| {
            a.matched = Some(Instant::now());
            if a.valid.is_some() {
                a.valid = Some(Instant::now());
            }
        });
        true
    }
    /// A separate future, not a task: polled alongside *all* reads and writes.
    pub fn watchdog(&self) -> impl std::future::Future<Output = Failure> + Send + use<> {
        let mut activity = self.activity.subscribe();
        async move {
            let mut diagnostic = tokio::time::interval(Duration::from_secs(5));
            loop {
                let current = *activity.borrow_and_update();
                let deadline = current.valid.map(|v| v + WIRELESS_PEER_TIMEOUT);
                tokio::select! { biased;
                    _ = async { match deadline { Some(d) => tokio::time::sleep_until(d).await, None => std::future::pending().await } } => {
                        crate::daemon_log!(Warn, "aa-liveness", "Wireless AA peer unresponsive: no valid inbound activity for 10 seconds; detection only, cleanup follows");
                        return Failure::new(Kind::TransportLoss, "Wireless AA peer unresponsive: no valid inbound activity for 10 seconds");
                    }
                    _ = diagnostic.tick() => {
                        if let Some(valid) = current.valid {
                            crate::daemon_log!(Debug, "aa-liveness", "valid_rx_age_ms={} matched_response_age_ms={:?} timeout_ms={}", valid.elapsed().as_millis(), current.matched.map(|v| v.elapsed().as_millis()), WIRELESS_PEER_TIMEOUT.as_millis());
                        }
                    }
                    changed = activity.changed() => { if changed.is_err() { return Failure::cancelled(); } }
                }
            }
        }
    }
}
