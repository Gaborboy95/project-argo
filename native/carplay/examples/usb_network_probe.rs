//! Explicit USB configuration test; no dongle access or firmware operations.
use nusb::transfer::{ControlIn, ControlType, Recipient};
use std::time::Duration;
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let select = std::env::args().nth(1).as_deref() == Some("--select-carplay");
    if !select && std::env::args().nth(1).as_deref() != Some("--expose-carplay") {
        return Err("use --expose-carplay".into());
    }
    let phones: Vec<_> = nusb::list_devices()
        .await?
        .filter(|d| d.vendor_id() == 0x05ac && d.product_id() >= 0x1290 && d.product_id() <= 0x12ff)
        .collect();
    if phones.len() != 1 {
        return Err("connect exactly one iPhone".into());
    }
    let device = phones[0].open().await?;
    if select {
        device.set_configuration(6).await?;
        println!("Selected CarPlay USB configuration 6.");
        return Ok(());
    }
    println!(
        "USB configurations before request: {}",
        device.configurations().count()
    );
    device
        .control_in(
            ControlIn {
                control_type: ControlType::Vendor,
                recipient: Recipient::Device,
                request: 0x52,
                value: 0,
                index: 4,
                length: 1,
            },
            Duration::from_secs(1),
        )
        .await?;
    println!(
        "Requested the iPhone's CarPlay USB configurations; no persistent phone or dongle setting written."
    );
    Ok(())
}
