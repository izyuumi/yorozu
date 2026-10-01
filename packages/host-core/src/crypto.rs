//! Existing Yorozu wire cryptography. Private identity material never leaves this worker.
use crate::{history::publish, private_dir, private_open, read_private, sync_dir};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce, aead::Aead};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fs, fs::File, io, path::Path};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};
const WIRE_BYTES: usize = 700 * 1024;
const MAX_SEQ: u64 = 9_007_199_254_740_991;
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
pub fn encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}
pub fn decode(text: &str) -> io::Result<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(text).map_err(|_| invalid())
}
fn fixed<const N: usize>(text: &str) -> io::Result<[u8; N]> {
    decode(text)?.try_into().map_err(|_| invalid())
}
fn field<'a>(value: &'a Value, key: &str) -> io::Result<&'a str> {
    value[key].as_str().ok_or_else(invalid)
}
fn sequence(value: &Value) -> Option<u64> {
    value
        .as_f64()
        .filter(|seq| {
            seq.is_finite() && seq.fract() == 0.0 && *seq >= 1.0 && *seq <= MAX_SEQ as f64
        })
        .map(|seq| seq as u64)
}
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct WireKeys {
    pub legacy: [u8; 32],
    pub send: [u8; 32],
    pub recv: [u8; 32],
}
impl WireKeys {
    pub fn derive(private: [u8; 32], public: [u8; 32]) -> io::Result<Self> {
        let secret = StaticSecret::from(private).diffie_hellman(&PublicKey::from(public));
        if !secret.was_contributory() {
            return Err(invalid());
        }
        let hkdf = Hkdf::<Sha256>::new(Some(b"yorozu-v1"), secret.as_bytes());
        let derive = |info: &[u8]| -> io::Result<[u8; 32]> {
            let mut key = [0; 32];
            hkdf.expand(info, &mut key).map_err(|_| invalid())?;
            Ok(key)
        };
        Ok(Self {
            legacy: derive(b"yorozu-session")?,
            send: derive(b"yorozu-channel/mac->device")?,
            recv: derive(b"yorozu-channel/device->mac")?,
        })
    }
}
pub fn seal(key: &[u8; 32], nonce: &[u8; 12], bytes: &[u8]) -> io::Result<Vec<u8>> {
    if bytes.len() > WIRE_BYTES {
        return Err(invalid());
    }
    ChaCha20Poly1305::new(key.into())
        .encrypt(Nonce::from_slice(nonce), bytes)
        .map_err(|_| invalid())
}
pub fn open(key: &[u8; 32], nonce: &[u8; 12], bytes: &[u8]) -> io::Result<Vec<u8>> {
    if bytes.len() < 16 || bytes.len() > WIRE_BYTES + 16 {
        return Err(invalid());
    }
    ChaCha20Poly1305::new(key.into())
        .decrypt(Nonce::from_slice(nonce), bytes)
        .map_err(|_| invalid())
}
pub fn verify(public: &[u8; 32], message: &[u8], signature: &[u8; 64]) -> bool {
    VerifyingKey::from_bytes(public).is_ok_and(|key| {
        key.verify_strict(message, &Signature::from_bytes(signature))
            .is_ok()
    })
}
fn event(value: &Value) -> bool {
    value.is_object()
        && ["id", "threadId", "agentId", "kind"]
            .iter()
            .all(|key| value[*key].is_string())
        && value["ts"].is_number()
        && (value["data"].is_object() || value["data"].is_array())
}
fn random<const N: usize>() -> io::Result<[u8; N]> {
    let mut bytes = [0; N];
    OsRng.try_fill_bytes(&mut bytes).map_err(|_| invalid())?;
    Ok(bytes)
}
pub struct HostCrypto {
    session: StaticSecret,
    signing: SigningKey,
    peers: BTreeMap<String, WireKeys>,
    owner: File,
}
impl Drop for HostCrypto {
    fn drop(&mut self) {
        let _ = self.owner.unlock();
    }
}
impl HostCrypto {
    pub fn open(root: &Path) -> io::Result<Self> {
        private_dir(root)?;
        let owner = private_open(&root.join(".rust-crypto-owner.lock"), false)?;
        owner.try_lock().map_err(io::Error::other)?;
        let path = root.join("keys.json");
        match fs::symlink_metadata(&path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                // A missing identity beside saved connections must never silently create a new room.
                for name in ["devices.json", "channel-seq.json"] {
                    let saved = root.join(name);
                    match fs::symlink_metadata(&saved) {
                        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                        _ => return Err(invalid()),
                    }
                }
                let session = StaticSecret::from(random::<32>()?);
                let signing = SigningKey::from_bytes(&random::<32>()?);
                let bytes=Zeroizing::new(serde_json::to_vec(&json!({"session":{"priv":encode(&session.to_bytes()),"pub":encode(PublicKey::from(&session).as_bytes())},"signing":{"priv":encode(&signing.to_bytes()),"pub":encode(signing.verifying_key().as_bytes())}})).map_err(io::Error::other)?);
                publish(&path, &bytes)?;
                sync_dir(root)?;
            }
            meta => {
                let meta = meta?;
                if !meta.is_file() || meta.file_type().is_symlink() {
                    return Err(invalid());
                }
            }
        }
        let bytes = Zeroizing::new(read_private(&path, 1024 * 1024)?);
        let mut value: Value = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        let session = StaticSecret::from(fixed::<32>(field(&value["session"], "priv")?)?);
        let signing = SigningKey::from_bytes(&fixed::<32>(field(&value["signing"], "priv")?)?);
        if fixed::<32>(field(&value["session"], "pub")?)? != PublicKey::from(&session).to_bytes()
            || fixed::<32>(field(&value["signing"], "pub")?)? != signing.verifying_key().to_bytes()
        {
            return Err(invalid());
        }
        for kind in ["session", "signing"] {
            if let Value::String(text) = &mut value[kind]["priv"] {
                text.zeroize();
            }
            value[kind]["priv"] = Value::Null;
        }
        Ok(Self {
            session,
            signing,
            peers: BTreeMap::new(),
            owner,
        })
    }
    fn peer(&mut self, pubkey: &str) -> io::Result<&WireKeys> {
        if !self.peers.contains_key(pubkey) {
            let keys = WireKeys::derive(self.session.to_bytes(), fixed::<32>(pubkey)?)?;
            if self.peers.len() >= 16 {
                self.peers.pop_first();
            }
            self.peers.insert(pubkey.into(), keys);
        }
        Ok(self.peers.get(pubkey).unwrap())
    }
    fn request_inner(&mut self, request: &Value) -> io::Result<Value> {
        match request["op"].as_str() {
            Some("crypto_open") => Ok(
                json!({"sessionPub":encode(PublicKey::from(&self.session).as_bytes()),"signingPub":encode(self.signing.verifying_key().as_bytes())}),
            ),
            Some("crypto_peer") => {
                self.peer(field(request, "pub")?)?;
                Ok(json!({"valid":true}))
            }
            Some("crypto_forget") => {
                self.peers.remove(field(request, "pub")?);
                Ok(json!({"forgotten":true}))
            }
            Some("crypto_sign") => {
                let message = decode(field(request, "message")?)?;
                if message.len() > 2 * 1024 * 1024 {
                    return Err(invalid());
                }
                Ok(json!({"signature":encode(&self.signing.sign(&message).to_bytes())}))
            }
            Some("crypto_hello_proof") => {
                let secret = field(request, "secret")?;
                let public = field(request, "pub")?;
                let signing = field(request, "signingPub")?;
                if secret.len() > 4096 || public.len() > 128 || signing.len() > 128 {
                    return Err(invalid());
                }
                Ok(json!({"proof":encode(&Sha256::digest(format!("{secret}.{public}.{signing}")))}))
            }
            Some("crypto_seal") => {
                let mode = field(request, "mode")?;
                let keys = self.peer(field(request, "pub")?)?;
                let (key, plain) = match mode {
                    "current" => {
                        let seq = sequence(&request["seq"]).ok_or_else(invalid)?;
                        if !event(&request["event"]) {
                            return Err(invalid());
                        }
                        (
                            &keys.send,
                            serde_json::to_vec(&json!({"seq":seq,"event":request["event"]}))
                                .map_err(io::Error::other)?,
                        )
                    }
                    "legacy" => {
                        if !event(&request["event"]) {
                            return Err(invalid());
                        }
                        (
                            &keys.legacy,
                            serde_json::to_vec(&request["event"]).map_err(io::Error::other)?,
                        )
                    }
                    "preview" => (&keys.legacy, decode(field(request, "plaintext")?)?),
                    _ => return Err(invalid()),
                };
                let nonce = random::<12>()?;
                Ok(json!({"nonce":encode(&nonce),"ciphertext":encode(&seal(key,&nonce,&plain)?)}))
            }
            Some("crypto_open_box") => {
                let mode = field(request, "mode")?;
                let Ok(nonce) = fixed::<12>(field(request, "nonce")?) else {
                    return Ok(json!({"status":"unauthenticated"}));
                };
                let Ok(ciphertext) = decode(field(request, "ciphertext")?) else {
                    return Ok(json!({"status":"unauthenticated"}));
                };
                let keys = self.peer(field(request, "pub")?)?;
                let key = match mode {
                    "current" => &keys.recv,
                    "legacy" => &keys.legacy,
                    _ => return Err(invalid()),
                };
                let Ok(plain) = open(key, &nonce, &ciphertext) else {
                    return Ok(json!({"status":"unauthenticated"}));
                };
                let Ok(value) = serde_json::from_slice::<Value>(&plain) else {
                    return Ok(json!({"status":"malformed"}));
                };
                if mode == "legacy" {
                    return Ok(if event(&value) {
                        json!({"status":"opened","event":value})
                    } else {
                        json!({"status":"malformed"})
                    });
                }
                let seq = sequence(&value["seq"]);
                if seq.is_none() || !event(&value["event"]) {
                    return Ok(json!({"status":"malformed"}));
                }
                Ok(json!({"status":"opened","seq":seq.unwrap(),"event":value["event"]}))
            }
            _ => Err(invalid()),
        }
    }
    pub fn request(&mut self, request: &Value) -> Value {
        self.request_inner(request)
            .unwrap_or_else(|_| json!({"error":"crypto-request-failed"}))
    }
}
