#[cfg(unix)]
fn main() -> std::io::Result<()> {
    use argo_projectiond::identity::AndroidAutoIdentity;
    use argo_projectiond::ipc::{encode, string_payload, Decoder, Message, PayloadReader};
    use std::fs;
    use std::io::{Read, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;

    const HELLO: u16 = 1;
    const ERROR: u16 = 6;

    let socket_path = std::env::var("ARGO_PROJECTION_SOCKET")
        .unwrap_or_else(|_| "/run/argo/projection.sock".to_owned());
    let path = PathBuf::from(&socket_path);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    if path.exists() {
        fs::remove_file(&path)?;
    }
    let listener = UnixListener::bind(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o660))?;
    println!("argo-projectiond: control socket {socket_path}");

    for client in listener.incoming() {
        let mut client = match client {
            Ok(value) => value,
            Err(error) => {
                eprintln!("argo-projectiond: accept failed: {error}");
                continue;
            }
        };
        let mut decoder = Decoder::default();
        let mut buffer = [0_u8; 16 * 1024];
        loop {
            let count = match client.read(&mut buffer) {
                Ok(0) => break,
                Ok(value) => value,
                Err(error) => {
                    eprintln!("argo-projectiond: client read failed: {error}");
                    break;
                }
            };
            let messages = match decoder.push(&buffer[..count]) {
                Ok(value) => value,
                Err(error) => {
                    eprintln!("argo-projectiond: malformed IPC: {error:?}");
                    break;
                }
            };
            for message in messages {
                if message.kind != HELLO {
                    continue;
                }
                let mut payload = PayloadReader::new(&message.payload);
                let parsed = (|| {
                    let _width = payload.u16()?;
                    let _height = payload.u16()?;
                    let _dpi = payload.u16()?;
                    let _fps = payload.u8()?;
                    let _driver_side = payload.u8()?;
                    let certificate = payload.string()?;
                    let private_key = payload.string()?;
                    payload.done().then_some(AndroidAutoIdentity {
                        certificate: certificate.into(),
                        private_key: private_key.into(),
                    })
                })();
                let response = match parsed {
                    Some(identity) => match identity.validate_files() {
                        Ok(()) => Message {
                            kind: HELLO,
                            payload: Vec::new(),
                        },
                        Err(error) => Message {
                            kind: ERROR,
                            payload: string_payload(&format!(
                                "Android Auto identity validation failed: {error:?}"
                            ))
                            .unwrap_or_default(),
                        },
                    },
                    None => Message {
                        kind: ERROR,
                        payload: string_payload("Malformed projection hello").unwrap_or_default(),
                    },
                };
                if client.write_all(&encode(&response).unwrap_or_default()).is_err() {
                    break;
                }
            }
        }
    }
    Ok(())
}

#[cfg(not(unix))]
fn main() {
    eprintln!("argo-projectiond is currently supported only on Unix hosts");
}
