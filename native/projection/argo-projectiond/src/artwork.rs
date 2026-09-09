//! Private, bounded encoded artwork. Control IPC carries only the owned path.
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, OnceLock},
};
pub const MAX_BYTES: usize = 1024 * 1024;
const MAX_SIDE: u32 = 2048;
static ROOT: OnceLock<PathBuf> = OnceLock::new();
pub fn directory() -> Result<&'static Path, String> {
    if let Some(root) = ROOT.get() {
        return Ok(root);
    }
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let root = base.join(format!("argo-artwork-{}-{}", std::process::id(), random()?));
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    builder.mode(0o700);
    builder.create(&root).map_err(|e| e.to_string())?;
    if ROOT.set(root.clone()).is_err() {
        let _ = fs::remove_dir(root);
    }
    Ok(ROOT.get().unwrap())
}
pub(crate) fn random() -> Result<String, String> {
    let mut bytes = [0; 16];
    fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .map_err(|e| e.to_string())?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
#[derive(Debug, PartialEq, Eq)]
pub struct Image {
    path: PathBuf,
    // Never Debug-print or serialize picture bytes.
    data: Encoded,
}
#[derive(PartialEq, Eq)]
struct Encoded(Vec<u8>);
impl std::fmt::Debug for Encoded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "encoded artwork ({} bytes)", self.0.len())
    }
}
impl Image {
    pub fn path(&self) -> String {
        self.path.to_string_lossy().into_owned()
    }
    pub fn matches(&self, data: &[u8]) -> bool {
        self.data.0 == data
    }
}
impl Drop for Image {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}
pub fn store(data: Vec<u8>) -> Result<Arc<Image>, String> {
    validate(&data)?;
    let path = directory()?.join(format!("{}.img", random()?));
    let mut opts = fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    opts.mode(0o600);
    let result = opts.open(&path).and_then(|mut f| f.write_all(&data));
    if let Err(e) = result {
        let _ = fs::remove_file(&path);
        return Err(e.to_string());
    }
    Ok(Arc::new(Image {
        path,
        data: Encoded(data),
    }))
}
pub fn validate(data: &[u8]) -> Result<(), String> {
    if data.len() > MAX_BYTES {
        return Err("Artwork exceeds 1 MiB".into());
    }
    let dimensions =
        if data.starts_with(b"\x89PNG\r\n\x1a\n") && data.len() >= 33 && &data[12..16] == b"IHDR" {
            Some((
                u32::from_be_bytes(data[16..20].try_into().unwrap()),
                u32::from_be_bytes(data[20..24].try_into().unwrap()),
            ))
        } else if data.starts_with(&[0xff, 0xd8]) {
            let mut i = 2;
            let mut found = None;
            while i + 4 <= data.len() {
                if data[i] != 0xff {
                    break;
                }
                let marker = data[i + 1];
                i += 2;
                if marker == 0xff {
                    i -= 1;
                    continue;
                }
                if marker == 0xda || marker == 0xd9 {
                    break;
                }
                if marker == 0x01 || (0xd0..=0xd7).contains(&marker) {
                    continue;
                }
                let len = usize::from(u16::from_be_bytes([data[i], data[i + 1]]));
                if len < 2 || i + len > data.len() {
                    break;
                }
                if matches!(marker,0xc0..=0xc3|0xc5..=0xc7|0xc9..=0xcb|0xcd..=0xcf) && len >= 8 {
                    found = Some((
                        u32::from(u16::from_be_bytes([data[i + 5], data[i + 6]])),
                        u32::from(u16::from_be_bytes([data[i + 3], data[i + 4]])),
                    ));
                    break;
                }
                i += len;
            }
            found
        } else {
            None
        };
    match dimensions {
        Some((w, h)) if w > 0 && h > 0 && w <= MAX_SIDE && h <= MAX_SIDE => Ok(()),
        _ => Err("Artwork requires bounded PNG/JPEG dimensions".into()),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    pub fn png() -> Vec<u8> {
        let mut p = vec![0; 33];
        p[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n");
        p[12..16].copy_from_slice(b"IHDR");
        p[16..20].copy_from_slice(&1u32.to_be_bytes());
        p[20..24].copy_from_slice(&1u32.to_be_bytes());
        p
    }
    #[test]
    fn bounded_owned_artwork_retires_after_last_snapshot() {
        assert!(validate(&vec![0; MAX_BYTES + 1]).is_err());
        assert!(validate(b"https://phone/image").is_err());
        let mut huge = png();
        huge[16..20].copy_from_slice(&4096u32.to_be_bytes());
        assert!(validate(&huge).is_err());
        let image = store(png()).unwrap();
        let path = image.path();
        let retained = image.clone();
        drop(image);
        assert!(Path::new(&path).exists());
        drop(retained);
        assert!(!Path::new(&path).exists());
    }
}
