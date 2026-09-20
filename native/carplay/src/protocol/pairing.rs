//! Native AirPlay authentication and encrypted control framing.
//! Wire behavior researched in the pinned LIVI reference (see protocol/mod.rs).
//! Cryptographic operations use OpenSSL; no private MFi key is available here.
use super::Error;
use openssl::{
    bn::{BigNum, BigNumContext},
    derive::Deriver,
    hash::{MessageDigest, hash},
    pkey::{Id, PKey, Private},
    rand::rand_bytes,
    sign::{Signer, Verifier},
    symm::{Cipher, decrypt_aead, encrypt_aead},
};
use std::collections::BTreeMap;

type Result<T> = std::result::Result<T, Error>;
impl From<openssl::error::ErrorStack> for Error {
    fn from(_: openssl::error::ErrorStack) -> Self {
        Self::Rejected
    }
}

pub type Tlv = BTreeMap<u8, Vec<u8>>;
pub fn decode_tlv(bytes: &[u8]) -> Result<Tlv> {
    if bytes.len() > 8192 {
        return Err(Error::Bounds);
    }
    let mut fields = Tlv::new();
    let mut offset = 0;
    let mut previous = None;
    while offset < bytes.len() {
        let head = bytes.get(offset..offset + 2).ok_or(Error::Malformed)?;
        let (kind, len) = (head[0], head[1] as usize);
        offset += 2;
        let value = bytes.get(offset..offset + len).ok_or(Error::Malformed)?;
        if fields.contains_key(&kind) && previous != Some((kind, 255)) {
            return Err(Error::Malformed);
        }
        fields.entry(kind).or_default().extend_from_slice(value);
        if fields.len() > 16 {
            return Err(Error::Bounds);
        }
        previous = Some((kind, len));
        offset += len;
    }
    Ok(fields)
}
pub fn encode_tlv(fields: &[(u8, &[u8])]) -> Result<Vec<u8>> {
    let mut output = Vec::new();
    let mut seen = [false; 256];
    for &(kind, bytes) in fields {
        if seen[kind as usize] {
            return Err(Error::Malformed);
        }
        seen[kind as usize] = true;
        if bytes.is_empty() {
            output.extend_from_slice(&[kind, 0]);
        }
        for part in bytes.chunks(255) {
            output.extend_from_slice(&[kind, part.len() as u8]);
            output.extend_from_slice(part);
        }
    }
    if output.len() > 8192 {
        return Err(Error::Bounds);
    }
    Ok(output)
}
fn field(tlv: &Tlv, kind: u8) -> Result<&[u8]> {
    tlv.get(&kind).map(Vec::as_slice).ok_or(Error::Malformed)
}
fn digest(parts: &[&[u8]]) -> Result<Vec<u8>> {
    let mut h = openssl::hash::Hasher::new(MessageDigest::sha512())?;
    for part in parts {
        h.update(part)?;
    }
    Ok(h.finish()?.to_vec())
}
fn hmac(key: &[u8], bytes: &[u8]) -> Result<Vec<u8>> {
    let key = PKey::hmac(key)?;
    let mut signer = Signer::new(MessageDigest::sha512(), &key)?;
    Ok(signer.sign_oneshot_to_vec(bytes)?)
}
/// HKDF-SHA512 with a single 32-byte output block, per RFC 5869.
pub fn derive_key(secret: &[u8], salt: &str, info: &str) -> Result<[u8; 32]> {
    let extracted = hmac(salt.as_bytes(), secret)?;
    let mut input = info.as_bytes().to_vec();
    input.push(1);
    let expanded = hmac(&extracted, &input)?;
    Ok(expanded[..32].try_into().unwrap())
}
fn label_nonce(label: &[u8; 8]) -> [u8; 12] {
    let mut nonce = [0; 12];
    nonce[4..].copy_from_slice(label);
    nonce
}
pub fn seal(key: &[u8; 32], nonce: &[u8; 12], aad: &[u8], plain: &[u8]) -> Result<Vec<u8>> {
    let mut tag = [0; 16];
    let mut out = encrypt_aead(
        Cipher::chacha20_poly1305(),
        key,
        Some(nonce),
        aad,
        plain,
        &mut tag,
    )?;
    out.extend_from_slice(&tag);
    Ok(out)
}
pub fn open(key: &[u8; 32], nonce: &[u8; 12], aad: &[u8], sealed: &[u8]) -> Result<Vec<u8>> {
    let split = sealed.len().checked_sub(16).ok_or(Error::Malformed)?;
    Ok(decrypt_aead(
        Cipher::chacha20_poly1305(),
        key,
        Some(nonce),
        aad,
        &sealed[..split],
        &sealed[split..],
    )?)
}
fn shared(private: &PKey<Private>, peer: &[u8]) -> Result<Vec<u8>> {
    if peer.len() != 32 {
        return Err(Error::Bounds);
    }
    let peer = PKey::public_key_from_raw_bytes(peer, Id::X25519)?;
    let mut dh = Deriver::new(private)?;
    dh.set_peer(&peer)?;
    let shared = dh.derive_to_vec()?;
    if shared.len() != 32 || shared.iter().all(|b| *b == 0) {
        return Err(Error::Rejected);
    }
    Ok(shared)
}
fn sign(key: &PKey<Private>, bytes: &[u8]) -> Result<Vec<u8>> {
    Ok(Signer::new_without_digest(key)?.sign_oneshot_to_vec(bytes)?)
}
fn verify(key: &[u8], bytes: &[u8], signature: &[u8]) -> Result<()> {
    if key.len() != 32 || signature.len() != 64 {
        return Err(Error::Bounds);
    }
    let key = PKey::public_key_from_raw_bytes(key, Id::ED25519)?;
    if !Verifier::new_without_digest(&key)?.verify_oneshot(signature, bytes)? {
        return Err(Error::Rejected);
    }
    Ok(())
}

/// Head-unit signing identity, distinct from the real MFi coprocessor identity.
/// Private material is never Debug/Serialize; caller owns secure persistence.
pub struct Identity {
    pub identifier: String,
    key: PKey<Private>,
}
impl Identity {
    pub fn generate(identifier: String) -> Result<Self> {
        if identifier.is_empty()
            || identifier.len() > 128
            || identifier.chars().any(char::is_control)
        {
            return Err(Error::Bounds);
        }
        Ok(Self {
            identifier,
            key: PKey::generate_ed25519()?,
        })
    }
    pub fn public_key(&self) -> Result<Vec<u8>> {
        Ok(self.key.raw_public_key()?)
    }
}

/// Bounded pairing store. Registration is permitted only after SRP and controller signature verification.
#[derive(Default)]
pub struct Peers(BTreeMap<Vec<u8>, Vec<u8>>);
impl Peers {
    fn register(&mut self, identifier: &[u8], key: &[u8]) -> Result<()> {
        if identifier.is_empty() || identifier.len() > 128 || key.len() != 32 {
            return Err(Error::Bounds);
        }
        if self.0.len() >= 16 && !self.0.contains_key(identifier) {
            return Err(Error::Bounds);
        }
        self.0.insert(identifier.to_vec(), key.to_vec());
        Ok(())
    }
}

struct Srp {
    modulus: BigNum,
    verifier: BigNum,
    private: BigNum,
    public: Vec<u8>,
    salt: [u8; 16],
}
impl Srp {
    fn new() -> Result<Self> {
        let modulus = BigNum::get_rfc3526_prime_3072()?;
        let generator = BigNum::from_u32(5)?;
        let mut context = BigNumContext::new()?;
        let mut salt = [0; 16];
        rand_bytes(&mut salt)?;
        let mut private_bytes = [0; 32];
        rand_bytes(&mut private_bytes)?;
        let mut private = BigNum::from_slice(&private_bytes)?;
        private.set_const_time();
        let mut exponent = BigNum::from_slice(&digest(&[&salt, &digest(&[b"Pair-Setup:3939"])?])?)?;
        exponent.set_const_time();
        let mut verifier = BigNum::new()?;
        verifier.mod_exp(&generator, &exponent, &modulus, &mut context)?;
        let multiplier = BigNum::from_slice(&digest(&[
            &modulus.to_vec(),
            &generator.to_vec_padded(384)?,
        ])?)?;
        let mut gb = BigNum::new()?;
        gb.mod_exp(&generator, &private, &modulus, &mut context)?;
        let mut kv = BigNum::new()?;
        kv.mod_mul(&multiplier, &verifier, &modulus, &mut context)?;
        let mut public = BigNum::new()?;
        public.mod_add(&kv, &gb, &modulus, &mut context)?;
        Ok(Self {
            modulus,
            verifier,
            private,
            public: public.to_vec_padded(384)?,
            salt,
        })
    }
    fn verify(self, public: &[u8], proof: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
        if public.len() != 384 || proof.len() != 64 {
            return Err(Error::Bounds);
        }
        let a = BigNum::from_slice(public)?;
        let mut context = BigNumContext::new()?;
        let mut reduced = BigNum::new()?;
        reduced.nnmod(&a, &self.modulus, &mut context)?;
        if reduced.num_bits() == 0 {
            return Err(Error::Rejected);
        }
        let u = BigNum::from_slice(&digest(&[public, &self.public])?)?;
        if u.num_bits() == 0 {
            return Err(Error::Rejected);
        }
        let mut vu = BigNum::new()?;
        vu.mod_exp(&self.verifier, &u, &self.modulus, &mut context)?;
        let mut base = BigNum::new()?;
        base.mod_mul(&a, &vu, &self.modulus, &mut context)?;
        let mut secret = BigNum::new()?;
        secret.mod_exp(&base, &self.private, &self.modulus, &mut context)?;
        let key = digest(&[&secret.to_vec()])?;
        let hn = digest(&[&self.modulus.to_vec()])?;
        let hg = digest(&[&[5]])?;
        let xor: Vec<u8> = hn.iter().zip(hg).map(|(a, b)| a ^ b).collect();
        let expected = digest(&[
            &xor,
            &digest(&[b"Pair-Setup"])?,
            &self.salt,
            public,
            &self.public,
            &key,
        ])?;
        if !openssl::memcmp::eq(&expected, proof) {
            return Err(Error::Rejected);
        }
        Ok((key.clone(), digest(&[public, proof, &key])?))
    }
}

#[derive(Default)]
pub struct PairSetup {
    srp: Option<Srp>,
    key: Option<Vec<u8>>,
    step: u8,
}
impl PairSetup {
    pub fn handle(
        &mut self,
        bytes: &[u8],
        identity: &Identity,
        peers: &mut Peers,
    ) -> Result<Vec<u8>> {
        let result = self.advance(bytes, identity, peers);
        if result.is_err() {
            self.srp = None;
            self.key = None;
            self.step = 255;
        }
        result
    }
    fn advance(&mut self, bytes: &[u8], identity: &Identity, peers: &mut Peers) -> Result<Vec<u8>> {
        let fields = decode_tlv(bytes)?;
        match (self.step, field(&fields, 6)?) {
            (0, [1]) => {
                if field(&fields, 0)? != [0] {
                    return Err(Error::Unsupported);
                }
                let srp = Srp::new()?;
                let response = encode_tlv(&[(6, &[2]), (2, &srp.salt), (3, &srp.public)])?;
                self.srp = Some(srp);
                self.step = 2;
                Ok(response)
            }
            (2, [3]) => {
                let (key, proof) = self
                    .srp
                    .take()
                    .ok_or(Error::State)?
                    .verify(field(&fields, 3)?, field(&fields, 4)?)?;
                self.key = Some(key);
                self.step = 4;
                encode_tlv(&[(6, &[4]), (4, &proof)])
            }
            (4, [5]) => {
                let secret = self.key.take().ok_or(Error::State)?;
                let key = derive_key(
                    &secret,
                    "Pair-Setup-Encrypt-Salt",
                    "Pair-Setup-Encrypt-Info",
                )?;
                let controller = decode_tlv(&open(
                    &key,
                    &label_nonce(b"PS-Msg05"),
                    &[],
                    field(&fields, 5)?,
                )?)?;
                let identifier = field(&controller, 1)?;
                let public = field(&controller, 3)?;
                let proof_key = derive_key(
                    &secret,
                    "Pair-Setup-Controller-Sign-Salt",
                    "Pair-Setup-Controller-Sign-Info",
                )?;
                verify(
                    public,
                    &[proof_key.as_slice(), identifier, public].concat(),
                    field(&controller, 10)?,
                )?;
                let own_key = identity.public_key()?;
                let proof_key = derive_key(
                    &secret,
                    "Pair-Setup-Accessory-Sign-Salt",
                    "Pair-Setup-Accessory-Sign-Info",
                )?;
                let signature = sign(
                    &identity.key,
                    &[
                        proof_key.as_slice(),
                        identity.identifier.as_bytes(),
                        &own_key,
                    ]
                    .concat(),
                )?;
                let reply = encode_tlv(&[
                    (1, identity.identifier.as_bytes()),
                    (3, &own_key),
                    (10, &signature),
                ])?;
                let response = encode_tlv(&[
                    (6, &[6]),
                    (5, &seal(&key, &label_nonce(b"PS-Msg06"), &[], &reply)?),
                ])?;
                peers.register(identifier, public)?;
                self.step = 6;
                Ok(response)
            }
            _ => Err(Error::State),
        }
    }
}

struct PendingVerify {
    ours: Vec<u8>,
    theirs: Vec<u8>,
    secret: Vec<u8>,
    key: [u8; 32],
}
#[derive(Default)]
pub struct PairVerify {
    pending: Option<PendingVerify>,
    used: bool,
}
pub struct Verified {
    pub secret: Vec<u8>,
    pub read: [u8; 32],
    pub write: [u8; 32],
}
impl PairVerify {
    pub fn start(&mut self, bytes: &[u8], identity: &Identity) -> Result<Vec<u8>> {
        if self.used {
            return Err(Error::State);
        }
        self.used = true;
        let fields = decode_tlv(bytes)?;
        if field(&fields, 6)? != [1] {
            return Err(Error::State);
        }
        let theirs = field(&fields, 3)?.to_vec();
        let ephemeral = PKey::generate_x25519()?;
        let ours = ephemeral.raw_public_key()?;
        let secret = shared(&ephemeral, &theirs)?;
        let key = derive_key(
            &secret,
            "Pair-Verify-Encrypt-Salt",
            "Pair-Verify-Encrypt-Info",
        )?;
        let signature = sign(
            &identity.key,
            &[ours.as_slice(), identity.identifier.as_bytes(), &theirs].concat(),
        )?;
        let reply = encode_tlv(&[(1, identity.identifier.as_bytes()), (10, &signature)])?;
        let sealed = seal(&key, &label_nonce(b"PV-Msg02"), &[], &reply)?;
        let response = encode_tlv(&[(6, &[2]), (3, &ours), (5, &sealed)])?;
        self.pending = Some(PendingVerify {
            ours,
            theirs,
            secret,
            key,
        });
        Ok(response)
    }
    pub fn finish(&mut self, bytes: &[u8], peers: &Peers) -> Result<(Vec<u8>, Verified)> {
        let pending = self.pending.take().ok_or(Error::State)?;
        let fields = decode_tlv(bytes)?;
        if field(&fields, 6)? != [3] {
            return Err(Error::State);
        }
        let controller = decode_tlv(&open(
            &pending.key,
            &label_nonce(b"PV-Msg03"),
            &[],
            field(&fields, 5)?,
        )?)?;
        let identifier = field(&controller, 1)?;
        let public = peers.0.get(identifier).ok_or(Error::Rejected)?;
        verify(
            public,
            &[pending.theirs.as_slice(), identifier, &pending.ours].concat(),
            field(&controller, 10)?,
        )?;
        let read = derive_key(
            &pending.secret,
            "Control-Salt",
            "Control-Write-Encryption-Key",
        )?;
        let write = derive_key(
            &pending.secret,
            "Control-Salt",
            "Control-Read-Encryption-Key",
        )?;
        Ok((
            encode_tlv(&[(6, &[4])])?,
            Verified {
                secret: pending.secret,
                read,
                write,
            },
        ))
    }
}

/// Each direction has a separate key and counter. A failed authentication poisons the direction.
pub struct ControlCipher {
    key: [u8; 32],
    counter: u64,
    failed: bool,
}
impl ControlCipher {
    pub fn new(key: [u8; 32]) -> Self {
        Self {
            key,
            counter: 0,
            failed: false,
        }
    }
    fn nonce(&self) -> Result<[u8; 12]> {
        if self.failed || self.counter == u64::MAX {
            return Err(Error::State);
        }
        let mut nonce = [0; 12];
        nonce[4..].copy_from_slice(&self.counter.to_le_bytes());
        Ok(nonce)
    }
    pub fn encrypt(&mut self, plain: &[u8]) -> Result<Vec<u8>> {
        if plain.is_empty() || plain.len() > 16384 {
            return Err(Error::Bounds);
        }
        let header = (plain.len() as u16).to_le_bytes();
        let sealed = seal(&self.key, &self.nonce()?, &header, plain)?;
        self.counter += 1;
        Ok([header.as_slice(), &sealed].concat())
    }
    pub fn decrypt(&mut self, frame: &[u8]) -> Result<Vec<u8>> {
        let nonce = self.nonce()?;
        self.failed = true;
        if frame.len() < 18 {
            return Err(Error::Bounds);
        }
        let size = u16::from_le_bytes([frame[0], frame[1]]) as usize;
        if size > 16384 || frame.len() != size + 18 {
            return Err(Error::Bounds);
        }
        let plain = open(&self.key, &nonce, &frame[..2], &frame[2..])?;
        self.counter += 1;
        self.failed = false;
        Ok(plain)
    }
}

/// MFiSAP response; signs only the received phone exchange using the real coprocessor.
pub async fn auth_setup(bytes: &[u8], link: &crate::link::LinkClient) -> Result<Vec<u8>> {
    if bytes.len() != 33 || bytes[0] != 1 {
        return Err(Error::Malformed);
    }
    let ephemeral = PKey::generate_x25519()?;
    let public = ephemeral.raw_public_key()?;
    let secret = shared(&ephemeral, &bytes[1..])?;
    let certificate = link
        .authentication_certificate()
        .await
        .map_err(|_| Error::Rejected)?;
    let major = link.protocol_major().await.map_err(|_| Error::Rejected)?;
    let digest_type = match major {
        2 => MessageDigest::sha1(),
        3 => MessageDigest::sha256(),
        _ => return Err(Error::Unsupported),
    };
    let challenge = hash(digest_type, &[public.as_slice(), &bytes[1..]].concat())?;
    let signature = link.sign(&challenge).await.map_err(|_| Error::Rejected)?;
    let key = hash(
        MessageDigest::sha1(),
        &[b"AES-KEY".as_slice(), &secret].concat(),
    )?;
    let iv = hash(
        MessageDigest::sha1(),
        &[b"AES-IV".as_slice(), &secret].concat(),
    )?;
    let sealed = openssl::symm::encrypt(
        Cipher::aes_128_ctr(),
        &key[..16],
        Some(&iv[..16]),
        &signature,
    )?;
    let mut response = public;
    response.extend_from_slice(&(certificate.len() as u32).to_be_bytes());
    response.extend(certificate);
    response.extend_from_slice(&(sealed.len() as u32).to_be_bytes());
    response.extend(sealed);
    Ok(response)
}

fn private_file(path: &std::path::Path, maximum: u64) -> Result<Vec<u8>> {
    use std::{
        io::Read,
        os::unix::fs::{MetadataExt, OpenOptionsExt},
    };
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| Error::Rejected)?;
    let metadata = file.metadata().map_err(|_| Error::Rejected)?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() > maximum
    {
        return Err(Error::Rejected);
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Rejected)?;
    if bytes.len() as u64 > maximum {
        return Err(Error::Bounds);
    }
    Ok(bytes)
}
fn private_directory(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    match std::fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err(Error::Rejected),
    }
    let metadata = std::fs::symlink_metadata(path).map_err(|_| Error::Rejected)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(Error::Rejected);
    }
    Ok(())
}
impl Identity {
    /// Creates only an Argo Ed25519 pairing identity, never an MFi identity/key.
    pub fn load_or_create(directory: &std::path::Path) -> Result<Self> {
        use std::{io::Write, os::unix::fs::OpenOptionsExt};
        private_directory(directory)?;
        let path = directory.join("identity.pem");
        if !path.try_exists().map_err(|_| Error::Rejected)? {
            let key = PKey::generate_ed25519()?;
            let bytes = key.private_key_to_pem_pkcs8()?;
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&path)
            {
                Ok(mut file) => {
                    if file
                        .write_all(&bytes)
                        .and_then(|_| file.sync_all())
                        .is_err()
                    {
                        let _ = std::fs::remove_file(&path);
                        return Err(Error::Rejected);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(_) => return Err(Error::Rejected),
            }
        }
        let key = PKey::private_key_from_pem(&private_file(&path, 4096)?)?;
        if key.id() != Id::ED25519 {
            return Err(Error::Rejected);
        }
        let digest = hash(MessageDigest::sha256(), &key.raw_public_key()?)?;
        let mut address = digest[..6].to_vec();
        address[0] = (address[0] & 0xfe) | 2;
        let identifier = address
            .iter()
            .map(|byte| format!("{byte:02X}"))
            .collect::<Vec<_>>()
            .join(":");
        Ok(Self { identifier, key })
    }
}
impl Peers {
    pub fn load(directory: &std::path::Path) -> Result<Self> {
        private_directory(directory)?;
        let path = directory.join("peers.json");
        if !path.try_exists().map_err(|_| Error::Rejected)? {
            return Ok(Self::default());
        }
        let entries: Vec<(Vec<u8>, Vec<u8>)> =
            serde_json::from_slice(&private_file(&path, 16384)?).map_err(|_| Error::Malformed)?;
        if entries.len() > 16 {
            return Err(Error::Bounds);
        }
        let mut peers = Self::default();
        for (id, key) in entries {
            if peers.0.contains_key(&id) {
                return Err(Error::Malformed);
            }
            peers.register(&id, &key)?;
        }
        Ok(peers)
    }
    pub fn save(&self, directory: &std::path::Path) -> Result<()> {
        use std::{io::Write, os::unix::fs::OpenOptionsExt};
        private_directory(directory)?;
        let entries: Vec<_> = self.0.iter().collect();
        let bytes = serde_json::to_vec(&entries).map_err(|_| Error::Malformed)?;
        let mut random = [0; 8];
        rand_bytes(&mut random)?;
        let temporary = directory.join(format!("peers-{:016x}.tmp", u64::from_be_bytes(random)));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary)
            .map_err(|_| Error::Rejected)?;
        let result = file
            .write_all(&bytes)
            .and_then(|_| file.sync_all())
            .and_then(|_| std::fs::rename(&temporary, directory.join("peers.json")))
            .and_then(|_| std::fs::File::open(directory)?.sync_all());
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
            return Err(Error::Rejected);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tlv_fragmentation_and_ambiguity() {
        let value = vec![23; 768];
        let encoded = encode_tlv(&[(3, &value), (6, &[1])]).unwrap();
        assert_eq!(decode_tlv(&encoded).unwrap()[&3], value);
        for malformed in [&[6, 1][..], &[6, 1, 1, 6, 1, 1], &[3, 0, 6, 1, 1, 3, 0]] {
            assert!(decode_tlv(malformed).is_err());
        }
        assert!(decode_tlv(&vec![0; 8193]).is_err());
    }

    #[test]
    fn encrypted_control_rejects_tamper_replay_and_counter_exhaustion() {
        let mut sender = ControlCipher::new([18; 32]);
        let mut receiver = ControlCipher::new([18; 32]);
        let first = sender.encrypt(b"GET /info RTSP/1.0\r\n\r\n").unwrap();
        let second = sender.encrypt(&vec![9; 16384]).unwrap();
        assert_eq!(
            receiver.decrypt(&first).unwrap(),
            b"GET /info RTSP/1.0\r\n\r\n"
        );
        assert_eq!(receiver.decrypt(&second).unwrap(), vec![9; 16384]);
        assert_eq!(receiver.decrypt(&first), Err(Error::Rejected));
        assert_eq!(
            receiver.decrypt(&sender.encrypt(b"next").unwrap()),
            Err(Error::State)
        );
        for offset in [0, 2, first.len() - 1] {
            let mut bad = first.clone();
            bad[offset] ^= 1;
            assert!(ControlCipher::new([18; 32]).decrypt(&bad).is_err());
        }
        sender.counter = u64::MAX;
        assert_eq!(sender.encrypt(b"x"), Err(Error::State));
    }

    #[test]
    fn verify_checks_both_identities_and_derives_opposite_direction_keys() {
        let accessory = Identity::generate("test-accessory".into()).unwrap();
        let controller = Identity::generate("synthetic-controller".into()).unwrap();
        let mut peers = Peers::default();
        peers
            .register(
                controller.identifier.as_bytes(),
                &controller.public_key().unwrap(),
            )
            .unwrap();
        let ephemeral = PKey::generate_x25519().unwrap();
        let client_public = ephemeral.raw_public_key().unwrap();
        let mut pairing = PairVerify::default();
        let request = encode_tlv(&[(6, &[1]), (3, &client_public)]).unwrap();
        let reply = decode_tlv(&pairing.start(&request, &accessory).unwrap()).unwrap();
        let server_public = field(&reply, 3).unwrap();
        let secret = shared(&ephemeral, server_public).unwrap();
        let key = derive_key(
            &secret,
            "Pair-Verify-Encrypt-Salt",
            "Pair-Verify-Encrypt-Info",
        )
        .unwrap();
        let signed = decode_tlv(
            &open(
                &key,
                &label_nonce(b"PV-Msg02"),
                &[],
                field(&reply, 5).unwrap(),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(field(&signed, 1).unwrap(), accessory.identifier.as_bytes());
        verify(
            &accessory.public_key().unwrap(),
            &[
                server_public,
                accessory.identifier.as_bytes(),
                &client_public,
            ]
            .concat(),
            field(&signed, 10).unwrap(),
        )
        .unwrap();
        let signature = sign(
            &controller.key,
            &[
                client_public.as_slice(),
                controller.identifier.as_bytes(),
                server_public,
            ]
            .concat(),
        )
        .unwrap();
        let inner = encode_tlv(&[(1, controller.identifier.as_bytes()), (10, &signature)]).unwrap();
        let final_request = encode_tlv(&[
            (6, &[3]),
            (
                5,
                &seal(&key, &label_nonce(b"PV-Msg03"), &[], &inner).unwrap(),
            ),
        ])
        .unwrap();
        let (_, verified) = pairing.finish(&final_request, &peers).unwrap();
        assert_eq!(verified.secret, secret);
        assert_eq!(
            verified.read,
            derive_key(&secret, "Control-Salt", "Control-Write-Encryption-Key").unwrap()
        );
        assert_ne!(verified.read, verified.write);
        assert!(pairing.finish(&final_request, &peers).is_err());
        assert!(pairing.start(&request, &accessory).is_err());
        let mut pairing = PairVerify::default();
        assert!(
            pairing
                .start(
                    &encode_tlv(&[(6, &[1]), (3, &[0; 32])]).unwrap(),
                    &accessory
                )
                .is_err()
        );
    }

    // Independently exercise the controller side of SRP-6a. No canned MFi material.
    fn controller_srp(salt: &[u8], server: &[u8]) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        let n = BigNum::get_rfc3526_prime_3072().unwrap();
        let g = BigNum::from_u32(5).unwrap();
        let mut ctx = BigNumContext::new().unwrap();
        let a = BigNum::from_slice(&[19; 32]).unwrap();
        let mut public = BigNum::new().unwrap();
        public.mod_exp(&g, &a, &n, &mut ctx).unwrap();
        let public_bytes = public.to_vec_padded(384).unwrap();
        let x =
            BigNum::from_slice(&digest(&[salt, &digest(&[b"Pair-Setup:3939"]).unwrap()]).unwrap())
                .unwrap();
        let k =
            BigNum::from_slice(&digest(&[&n.to_vec(), &g.to_vec_padded(384).unwrap()]).unwrap())
                .unwrap();
        let u = BigNum::from_slice(&digest(&[&public_bytes, server]).unwrap()).unwrap();
        let mut gx = BigNum::new().unwrap();
        gx.mod_exp(&g, &x, &n, &mut ctx).unwrap();
        let mut kgx = BigNum::new().unwrap();
        kgx.mod_mul(&k, &gx, &n, &mut ctx).unwrap();
        let mut base = BigNum::new().unwrap();
        base.mod_sub(&BigNum::from_slice(server).unwrap(), &kgx, &n, &mut ctx)
            .unwrap();
        let mut ux = BigNum::new().unwrap();
        ux.checked_mul(&u, &x, &mut ctx).unwrap();
        let mut exponent = BigNum::new().unwrap();
        exponent.checked_add(&a, &ux).unwrap();
        let mut s = BigNum::new().unwrap();
        s.mod_exp(&base, &exponent, &n, &mut ctx).unwrap();
        let key = digest(&[&s.to_vec()]).unwrap();
        let xor: Vec<u8> = digest(&[&n.to_vec()])
            .unwrap()
            .into_iter()
            .zip(digest(&[&[5]]).unwrap())
            .map(|(a, b)| a ^ b)
            .collect();
        let proof = digest(&[
            &xor,
            &digest(&[b"Pair-Setup"]).unwrap(),
            salt,
            &public_bytes,
            server,
            &key,
        ])
        .unwrap();
        (public_bytes, proof, key)
    }

    #[test]
    fn setup_srp_and_signed_key_exchange_register_only_authenticated_controller() {
        let identity = Identity::generate("test-head-unit".into()).unwrap();
        let controller = Identity::generate("test-phone".into()).unwrap();
        let mut peers = Peers::default();
        let mut setup = PairSetup::default();
        let m1 = encode_tlv(&[(6, &[1]), (0, &[0])]).unwrap();
        let m2 = decode_tlv(&setup.handle(&m1, &identity, &mut peers).unwrap()).unwrap();
        let (a, proof, secret) = controller_srp(&m2[&2], &m2[&3]);
        let m3 = encode_tlv(&[(6, &[3]), (3, &a), (4, &proof)]).unwrap();
        let m4 = decode_tlv(&setup.handle(&m3, &identity, &mut peers).unwrap()).unwrap();
        assert_eq!(m4[&4], digest(&[&a, &proof, &secret]).unwrap());
        assert!(peers.0.is_empty());
        let key = derive_key(
            &secret,
            "Pair-Setup-Encrypt-Salt",
            "Pair-Setup-Encrypt-Info",
        )
        .unwrap();
        let signing = derive_key(
            &secret,
            "Pair-Setup-Controller-Sign-Salt",
            "Pair-Setup-Controller-Sign-Info",
        )
        .unwrap();
        let public = controller.public_key().unwrap();
        let signature = sign(
            &controller.key,
            &[
                signing.as_slice(),
                controller.identifier.as_bytes(),
                &public,
            ]
            .concat(),
        )
        .unwrap();
        let payload = encode_tlv(&[
            (1, controller.identifier.as_bytes()),
            (3, &public),
            (10, &signature),
        ])
        .unwrap();
        let m5 = encode_tlv(&[
            (6, &[5]),
            (
                5,
                &seal(&key, &label_nonce(b"PS-Msg05"), &[], &payload).unwrap(),
            ),
        ])
        .unwrap();
        let m6 = decode_tlv(&setup.handle(&m5, &identity, &mut peers).unwrap()).unwrap();
        let response =
            decode_tlv(&open(&key, &label_nonce(b"PS-Msg06"), &[], &m6[&5]).unwrap()).unwrap();
        let signing = derive_key(
            &secret,
            "Pair-Setup-Accessory-Sign-Salt",
            "Pair-Setup-Accessory-Sign-Info",
        )
        .unwrap();
        verify(
            &response[&3],
            &[signing.as_slice(), &response[&1], &response[&3]].concat(),
            &response[&10],
        )
        .unwrap();
        assert_eq!(peers.0[controller.identifier.as_bytes()], public);
        assert!(setup.handle(&m5, &identity, &mut peers).is_err());
        let mut setup = PairSetup::default();
        setup.handle(&m1, &identity, &mut Peers::default()).unwrap();
        let invalid = encode_tlv(&[(6, &[3]), (3, &[0; 384]), (4, &[0; 64])]).unwrap();
        assert!(
            setup
                .handle(&invalid, &identity, &mut Peers::default())
                .is_err()
        );
        assert!(setup.handle(&m1, &identity, &mut peers).is_err());
    }
}
