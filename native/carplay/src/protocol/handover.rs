//! Session-scoped, bounded iAP2 transport between authenticated AirPlay and control.
use tokio::sync::{mpsc, watch};

pub const MAX_CHUNK: usize = 65535;
pub const IAP_UUID: &str = "E9459FD0-BCAD-4C45-820F-1E72447EF2F2";

pub struct ReceiverSide {
    pub peer: [u8; 6],
    pub controller: [u8; 6],
    pub recorded: watch::Sender<bool>,
    pub disable: watch::Sender<bool>,
    pub failure: watch::Sender<bool>,
    pub incoming: mpsc::Sender<Vec<u8>>,
    pub outgoing: mpsc::Receiver<Vec<u8>>,
}
pub struct ControlSide {
    pub recorded: watch::Receiver<bool>,
    pub disable: watch::Receiver<bool>,
    pub failure: watch::Receiver<bool>,
    pub failed: watch::Sender<bool>,
    pub incoming: mpsc::Receiver<Vec<u8>>,
    pub outgoing: mpsc::Sender<Vec<u8>>,
}

pub fn channel(peer: [u8; 6], controller: [u8; 6]) -> (ReceiverSide, ControlSide) {
    let (recorded, recording) = watch::channel(false);
    let (disable, disabling) = watch::channel(false);
    let (failure, failed) = watch::channel(false);
    let (incoming, received) = mpsc::channel(16);
    let (outgoing, sending) = mpsc::channel(16);
    (
        ReceiverSide {
            peer,
            controller,
            recorded,
            disable,
            failure: failure.clone(),
            incoming,
            outgoing: sending,
        },
        ControlSide {
            recorded: recording,
            disable: disabling,
            failure: failed,
            failed: failure,
            incoming: received,
            outgoing,
        },
    )
}
impl ReceiverSide {
    pub fn is_failed(&self) -> bool {
        *self.failure.borrow()
    }
    pub fn request_disable(&self, target: &str) -> bool {
        let Ok(target) = crate::wifi::parse_mac(target) else {
            return false;
        };
        if *self.failure.borrow()
            || !*self.recorded.borrow()
            || (target != self.peer && target != self.controller)
        {
            return false;
        }
        self.disable.send_replace(true);
        true
    }
    pub fn deliver(&self, data: &[u8]) -> Result<(), super::Error> {
        if *self.failure.borrow() {
            return Ok(());
        }
        if !(1..=MAX_CHUNK).contains(&data.len()) || !*self.recorded.borrow() {
            return Err(super::Error::Bounds);
        }
        self.incoming
            .try_send(data.to_vec())
            .map_err(|_| super::Error::Bounds)
    }
    pub fn fail(&self) -> bool {
        self.failure.send_if_modified(|failed| {
            if *failed {
                false
            } else {
                *failed = true;
                true
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disable_targets_are_bound_to_authenticated_selected_phone_and_real_controller() {
        let (receiver, control) = channel([2, 0, 0, 0, 0, 1], [2, 0, 0, 0, 0, 2]);
        assert!(!receiver.request_disable("02:00:00:00:00:01"));
        receiver.recorded.send_replace(true);
        for wrong in ["", "02:00:00:00:00:03", "private-id", "00:00:00:00:00:00"] {
            assert!(!receiver.request_disable(wrong));
        }
        assert!(!*control.disable.borrow());
        assert!(receiver.request_disable("02:00:00:00:00:02"));
        assert!(*control.disable.borrow());
        assert!(receiver.request_disable("02:00:00:00:00:01"));
    }
    #[test]
    fn relay_requires_recording_and_has_bounded_bytes_and_queue() {
        let (receiver, mut control) = channel([2, 0, 0, 0, 0, 1], [2, 0, 0, 0, 0, 2]);
        assert!(receiver.deliver(&[1]).is_err());
        receiver.recorded.send_replace(true);
        assert!(receiver.deliver(&[]).is_err());
        assert!(receiver.deliver(&vec![0; MAX_CHUNK + 1]).is_err());
        for _ in 0..16 {
            receiver.deliver(&[1]).unwrap();
        }
        assert!(receiver.deliver(&[2]).is_err());
        assert_eq!(control.incoming.try_recv().unwrap(), [1]);
        receiver.deliver(&vec![3; MAX_CHUNK]).unwrap();
    }
}
