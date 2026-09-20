//! Explicit local USB attachment check. Does not send CarPlay StartSession,
//! alter USB configurations, or print phone identities/pairing credentials.
use argo_carplay::{
    link::{LinkClient, LinkConfig},
    protocol::{csm, usbmux, wired},
};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let authenticate = args == ["--authenticate"];
    if args != ["--open-carkit"] && !authenticate {
        eprintln!(
            "Usage: wired_probe --open-carkit | --authenticate\nOpens and closes the trusted local iPhone carkit service; no CarPlay session is started."
        );
        return ExitCode::FAILURE;
    }
    let devices = match usbmux::devices().await {
        Ok(devices) => devices,
        Err(error) => {
            eprintln!("USB inventory: {error}");
            return ExitCode::FAILURE;
        }
    };
    println!("Local USB devices reported by usbmuxd: {}", devices.len());
    if devices.len() != 1 {
        eprintln!("Connect exactly one unlocked iPhone for this test.");
        return ExitCode::FAILURE;
    }
    match usbmux::open_carkit(&devices[0]).await {
        Ok(stream) => {
            if authenticate {
                let link = LinkClient::new(LinkConfig::default()).unwrap();
                let (state, mut receiver) =
                    tokio::sync::watch::channel(wired::State::Synchronizing);
                let monitor = tokio::spawn(async move {
                    while receiver.changed().await.is_ok() {
                        eprintln!("Wired state: {:?}", *receiver.borrow_and_update());
                    }
                });
                let identity = csm::AccessoryIdentity {
                    name: "Argo".into(),
                    model: "LattePanda Mu".into(),
                    manufacturer: "Argo".into(),
                    serial: "argo-development".into(),
                    firmware: "0.1.0".into(),
                    hardware: "1".into(),
                    language: "en".into(),
                    usb_interface: 1,
                };
                let result = wired::authenticate_only(stream, &link, identity, state).await;
                monitor.await.ok();
                return match result {
                    Ok(()) => {
                        println!("Real phone accepted MFi authentication. No StartSession sent.");
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("Phone authentication: {e}");
                        ExitCode::FAILURE
                    }
                };
            }
            drop(stream);
            println!(
                "Trusted carkit service opened and closed. iAP2/MFi authentication and AirPlay were not started."
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("Carkit attachment: {error}");
            ExitCode::FAILURE
        }
    }
}
