use argo_carplay::{
    diagnostic,
    discovery::Discovery,
    link::{LinkClient, LinkConfig},
};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments == ["--version"] {
        println!("argo-carplayctl 0.1.0 control=1 (diagnostics only)");
        return ExitCode::SUCCESS;
    }
    if arguments != ["link", "status"] && arguments != ["mfi", "probe"] {
        eprintln!(
            "Usage: argo-carplayctl link status | mfi probe\nRead-only diagnostics; no signing, radio changes or firmware writes."
        );
        return ExitCode::FAILURE;
    }
    let mut config = LinkConfig::default();
    if let Ok(address) = std::env::var("ARGO_LIVI_LINK_ADDRESS") {
        match address.parse() {
            Ok(address) => config.discovery = Discovery::Address(address),
            Err(_) => {
                eprintln!("ARGO_LIVI_LINK_ADDRESS must be a trusted IPv4 address");
                return ExitCode::FAILURE;
            }
        }
    }
    let health =
        diagnostic::probe(&LinkClient::new(config).expect("valid bounded configuration")).await;
    println!(
        "{}",
        serde_json::to_string_pretty(&health).expect("serializable health")
    );
    if health.mfi == "ready" {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
