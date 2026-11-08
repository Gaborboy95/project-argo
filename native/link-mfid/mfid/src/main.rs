// SPDX-License-Identifier: GPL-3.0-or-later
// Based on LIVI by Lasse Heitgres (https://github.com/f-io/LIVI).
// Additional terms: see the workspace NOTICE.

use std::{net::SocketAddr, path::PathBuf, process::ExitCode};

const UPSTREAM: &str = "bfbea31ee624ddce84bfa96ce49d4663e6cdeca7";
const ATTRIBUTION: &str = "Based on LIVI by Lasse Heitgres (https://github.com/f-io/LIVI)";
const USAGE: &str = "Usage: argo-mfi-physical --bus <u32> --power-gpio <i32> --bind <SocketAddr> [--state <absolute-path>]\n       argo-mfi-physical --help\n       argo-mfi-physical --version\n\nPhysical Linux I2C coprocessor only. Bus, power and bind arguments are required.\nA negative --power-gpio leaves the existing power line untouched.\nThe upstream USB-link client filter remains enabled.";

#[derive(Debug, PartialEq, Eq)]
struct Options {
    bus: u32,
    power_gpio: i32,
    bind: SocketAddr,
    state: Option<PathBuf>,
}

#[derive(Debug, PartialEq, Eq)]
enum Command {
    Run(Options),
    Help,
    Version,
}

fn parse(arguments: impl IntoIterator<Item = String>) -> Result<Command, String> {
    let arguments: Vec<_> = arguments.into_iter().collect();
    if arguments == ["--help"] || arguments == ["-h"] {
        return Ok(Command::Help);
    }
    if arguments == ["--version"] {
        return Ok(Command::Version);
    }
    let (mut bus, mut power_gpio, mut bind, mut state) = (None, None, None, None);
    let mut arguments = arguments.into_iter();
    while let Some(flag) = arguments.next() {
        if !matches!(
            flag.as_str(),
            "--bus" | "--power-gpio" | "--bind" | "--state"
        ) {
            return Err(format!("Unknown argument: {flag}"));
        }
        let value = arguments
            .next()
            .ok_or_else(|| format!("Missing value for {flag}"))?;
        match flag.as_str() {
            "--bus" => {
                if bus.is_some() {
                    return Err("Duplicate --bus".into());
                }
                bus = Some(value.parse::<u32>().map_err(|_| "--bus requires a u32")?);
            }
            "--power-gpio" => {
                if power_gpio.is_some() {
                    return Err("Duplicate --power-gpio".into());
                }
                power_gpio = Some(
                    value
                        .parse::<i32>()
                        .map_err(|_| "--power-gpio requires an i32")?,
                );
            }
            "--bind" => {
                if bind.is_some() {
                    return Err("Duplicate --bind".into());
                }
                bind = Some(
                    value
                        .parse::<SocketAddr>()
                        .map_err(|_| "--bind requires an IP address and port")?,
                );
            }
            "--state" => {
                if state.is_some() {
                    return Err("Duplicate --state".into());
                }
                let path = PathBuf::from(value);
                if !path.is_absolute() || path.file_name().is_none() {
                    return Err("--state requires an absolute file path".into());
                }
                state = Some(path);
            }
            _ => unreachable!(),
        }
    }
    Ok(Command::Run(Options {
        bus: bus.ok_or("Missing --bus")?,
        power_gpio: power_gpio.ok_or("Missing --power-gpio")?,
        bind: bind.ok_or("Missing --bind")?,
        state,
    }))
}

#[cfg(target_os = "linux")]
fn write_state(path: &std::path::Path, bus: u32, major: u8) -> std::io::Result<()> {
    use std::{fs, io::Write, os::unix::fs::OpenOptionsExt};
    if !matches!(major, 2 | 3) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Unknown physical MFi generation",
        ));
    }
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::other("Missing state directory"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".argo-mfi-state-{}", std::process::id()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .open(&temporary)?;
    let result = (|| {
        writeln!(file, "Gen{major} @ /dev/i2c-{bus}")?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(target_os = "linux")]
fn run(options: Options) -> Result<(), Box<dyn std::error::Error>> {
    // Refuse an occupied/invalid bind before accessing the physical bus or GPIO.
    let listener = std::net::TcpListener::bind(options.bind)?;
    let mut chip = iap2_mfi::I2cCoprocessor::open(options.bus, options.power_gpio)?;
    if let Some(path) = &options.state {
        let major = iap2_mfi::server::protocol_major(&mut chip)
            .ok_or("Physical MFi protocol generation unavailable")?;
        write_state(path, options.bus, major)?;
    }
    eprintln!(
        "argo-mfi-physical: physical coprocessor ready; listening on {}",
        listener.local_addr()?
    );
    iap2_mfi::server::listen(listener, chip);
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn run(_: Options) -> Result<(), Box<dyn std::error::Error>> {
    Err("Physical I2C operation requires Linux".into())
}

fn main() -> ExitCode {
    match parse(std::env::args().skip(1)) {
        Ok(Command::Help) => {
            println!("{USAGE}\n\n{ATTRIBUTION}");
            ExitCode::SUCCESS
        }
        Ok(Command::Version) => {
            println!(
                "argo-mfi-physical {} upstream={UPSTREAM}\n{ATTRIBUTION}",
                env!("CARGO_PKG_VERSION")
            );
            ExitCode::SUCCESS
        }
        Ok(Command::Run(options)) => {
            eprintln!("{ATTRIBUTION}");
            match run(options) {
                Ok(()) => ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("argo-mfi-physical: {error}");
                    ExitCode::FAILURE
                }
            }
        }
        Err(error) => {
            eprintln!("{error}\n\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn command(arguments: &[&str]) -> Result<Command, String> {
        parse(arguments.iter().map(|value| (*value).to_owned()))
    }
    #[test]
    fn explicit_physical_options_preserve_negative_gpio_and_allow_reordering() {
        assert_eq!(
            command(&["--bind", "0.0.0.0:5000", "--power-gpio", "-1", "--bus", "1"]).unwrap(),
            Command::Run(Options {
                bus: 1,
                power_gpio: -1,
                bind: "0.0.0.0:5000".parse().unwrap(),
                state: None
            })
        );
        assert!(command(&["--bus", "0", "--power-gpio", "4", "--bind", "[::1]:5000"]).is_ok());
    }
    #[test]
    fn missing_unknown_duplicate_or_invalid_options_are_rejected() {
        for arguments in [
            vec![],
            vec!["--bus"],
            vec!["--bus", "1", "--bind", "127.0.0.1:5000"],
            vec!["--power-gpio", "-1", "--bind", "127.0.0.1:5000"],
            vec!["--bus", "1", "--power-gpio", "-1"],
            vec![
                "--bus",
                "-1",
                "--power-gpio",
                "-1",
                "--bind",
                "127.0.0.1:5000",
            ],
            vec![
                "--bus",
                "1",
                "--power-gpio",
                "2147483648",
                "--bind",
                "127.0.0.1:5000",
            ],
            vec![
                "--bus",
                "1",
                "--power-gpio",
                "-1",
                "--bind",
                "localhost:5000",
            ],
            vec!["--bus", "1", "--power-gpio", "-1", "--bind", "127.0.0.1"],
            vec![
                "--bus",
                "1",
                "--bus",
                "2",
                "--power-gpio",
                "-1",
                "--bind",
                "127.0.0.1:5000",
            ],
            vec![
                "--bus",
                "1",
                "--power-gpio",
                "-1",
                "--power-gpio",
                "3",
                "--bind",
                "127.0.0.1:5000",
            ],
            vec![
                "--bus",
                "1",
                "--power-gpio",
                "-1",
                "--bind",
                "127.0.0.1:5000",
                "--bind",
                "127.0.0.1:5001",
            ],
            vec!["--chip-file", "/tmp/fake"],
            vec!["--emulate"],
            vec!["--help", "--bus", "1"],
        ] {
            assert!(command(&arguments).is_err(), "accepted {arguments:?}");
        }
    }
    #[test]
    fn help_and_version_need_no_physical_options() {
        assert_eq!(command(&["--help"]).unwrap(), Command::Help);
        assert_eq!(command(&["-h"]).unwrap(), Command::Help);
        assert_eq!(command(&["--version"]).unwrap(), Command::Version);
    }

    #[test]
    fn optional_state_path_is_explicit_absolute_and_unique() {
        let base = ["--bus", "1", "--power-gpio", "-1", "--bind", "0.0.0.0:5000"];
        let mut arguments = base.to_vec();
        arguments.extend(["--state", "/tmp/livi/mfi"]);
        let Command::Run(options) = command(&arguments).unwrap() else {
            panic!("Expected run");
        };
        assert_eq!(options.state, Some(PathBuf::from("/tmp/livi/mfi")));
        for suffix in [
            vec!["--state", "relative"],
            vec!["--state", "/"],
            vec!["--state", "/tmp/one", "--state", "/tmp/two"],
        ] {
            let mut invalid = base.to_vec();
            invalid.extend(suffix);
            assert!(command(&invalid).is_err());
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn generation_marker_is_atomic_and_never_follows_an_existing_symlink() {
        use std::{
            fs,
            os::unix::fs::{DirBuilderExt, symlink},
        };
        let directory = std::env::temp_dir().join(format!(
            "argo-mfi-marker-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let marker = directory.join("mfi");
        assert!(write_state(&marker, 1, 99).is_err());
        assert!(!marker.exists());
        let target = directory.join("unchanged");
        fs::write(&target, "fixture").unwrap();
        symlink(&target, &marker).unwrap();
        write_state(&marker, 1, 2).unwrap();
        assert_eq!(fs::read_to_string(&marker).unwrap(), "Gen2 @ /dev/i2c-1\n");
        assert_eq!(fs::read_to_string(&target).unwrap(), "fixture");
        assert!(!marker.symlink_metadata().unwrap().file_type().is_symlink());
        write_state(&marker, 3, 3).unwrap();
        assert_eq!(fs::read_to_string(&marker).unwrap(), "Gen3 @ /dev/i2c-3\n");
        fs::remove_dir_all(directory).unwrap();
    }
}
