use crate::frame::{b64, Frame, MAX_COUNTER};
use crate::platform::Platform;
use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305,
};
use ed25519_dalek::{Signer, SigningKey};
use sha2::{Digest, Sha256};
use snow::{
    params::{CipherChoice, DHChoice, HashChoice},
    resolvers::{CryptoResolver, DefaultResolver},
    types::{Cipher, Dh, Hash, Random},
};
use std::sync::Arc;

struct PlatformRandom(Arc<dyn Platform>);
impl Random for PlatformRandom {
    fn try_fill_bytes(&mut self, bytes: &mut [u8]) -> Result<(), snow::Error> {
        self.0.random_bytes(bytes);
        Ok(())
    }
}
struct PlatformResolver(Arc<dyn Platform>);
impl CryptoResolver for PlatformResolver {
    fn resolve_rng(&self) -> Option<Box<dyn Random>> {
        Some(Box::new(PlatformRandom(self.0.clone())))
    }
    fn resolve_dh(&self, choice: &DHChoice) -> Option<Box<dyn Dh>> {
        DefaultResolver.resolve_dh(choice)
    }
    fn resolve_hash(&self, choice: &HashChoice) -> Option<Box<dyn Hash>> {
        DefaultResolver.resolve_hash(choice)
    }
    fn resolve_cipher(&self, choice: &CipherChoice) -> Option<Box<dyn Cipher>> {
        DefaultResolver.resolve_cipher(choice)
    }
}

pub fn signing_public(ed: &[u8; 32]) -> [u8; 32] {
    SigningKey::from_bytes(ed).verifying_key().to_bytes()
}
pub fn static_public(x: &[u8; 32]) -> [u8; 32] {
    x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(*x)).to_bytes()
}
pub fn sign(ed: &[u8; 32], text: &str) -> String {
    b64(SigningKey::from_bytes(ed).sign(text.as_bytes()).to_bytes())
}
pub fn proof(secret: &str, x: &[u8; 32], ed: &[u8; 32]) -> String {
    b64(Sha256::digest(format!(
        "{secret}.{}.{}",
        b64(static_public(x)),
        b64(signing_public(ed))
    )))
}

pub struct ClientHandshake {
    noise: snow::HandshakeState,
    pub frame: Frame,
    pub sid: [u8; 8],
}
impl ClientHandshake {
    pub fn new(
        x: &[u8; 32],
        ed: &[u8; 32],
        host: &[u8; 32],
        room: &str,
        now: u64,
        secret: Option<&str>,
        platform: Arc<dyn Platform>,
    ) -> Result<Self, snow::Error> {
        let builder = snow::Builder::with_resolver(
            "Noise_IK_25519_ChaChaPoly_SHA256".parse()?,
            Box::new(PlatformResolver(platform)),
        );
        Self::build(x, ed, host, room, now, secret, builder)
    }
    #[doc(hidden)]
    pub fn with_ephemeral_for_testing(
        x: &[u8; 32],
        ed: &[u8; 32],
        host: &[u8; 32],
        room: &str,
        now: u64,
        ephemeral: &[u8; 32],
    ) -> Result<Self, snow::Error> {
        let builder = snow::Builder::new("Noise_IK_25519_ChaChaPoly_SHA256".parse()?)
            .fixed_ephemeral_key_for_testing_only(ephemeral);
        Self::build(x, ed, host, room, now, None, builder)
    }
    fn build(
        x: &[u8; 32],
        ed: &[u8; 32],
        host: &[u8; 32],
        room: &str,
        now: u64,
        secret: Option<&str>,
        builder: snow::Builder<'_>,
    ) -> Result<Self, snow::Error> {
        let signing = signing_public(ed);
        let prologue = format!("yorozu|{room}|{}", b64(signing));
        let builder = builder
            .local_private_key(x)?
            .remote_public_key(host)?
            .prologue(prologue.as_bytes())?;
        let mut noise = builder.build_initiator()?;
        // ts first matches both existing wire implementations and the published vector.
        let payload = match secret {
            Some(s) => format!(r#"{{"ts":{now},"proof":"{}"}}"#, proof(s, x, ed)),
            None => format!(r#"{{"ts":{now}}}"#),
        };
        let mut message = vec![0; 65535];
        let n = noise.write_message(payload.as_bytes(), &mut message)?;
        message.truncate(n);
        let sid = message[..8].try_into().unwrap();
        Ok(Self {
            noise,
            frame: Frame::Init { signing, message },
            sid,
        })
    }
    pub fn finish(&mut self, frame: &Frame) -> Option<Session> {
        let Frame::Response { sid, message } = frame else {
            return None;
        };
        if *sid != self.sid {
            return None;
        }
        self.noise.read_message(message, &mut [0; 65535]).ok()?;
        let (send, recv) = self.noise.dangerously_get_raw_split();
        Some(Session::new(self.sid, send, recv))
    }
}
pub struct Session {
    pub sid: [u8; 8],
    send: [u8; 32],
    recv: [u8; 32],
    pub send_counter: u64,
    pub last_received: Option<u64>,
}
impl Session {
    pub fn new(sid: [u8; 8], send: [u8; 32], recv: [u8; 32]) -> Self {
        Self {
            sid,
            send,
            recv,
            send_counter: 0,
            last_received: None,
        }
    }
    pub fn seal(&mut self, plaintext: &[u8]) -> Option<Frame> {
        let counter = self.send_counter;
        if counter > MAX_COUNTER {
            return None;
        }
        let ciphertext = ChaCha20Poly1305::new((&self.send).into())
            .encrypt((&nonce(counter)).into(), plaintext)
            .ok()?;
        self.send_counter += 1;
        Some(Frame::Box {
            sid: self.sid,
            counter,
            ciphertext,
        })
    }
    pub fn open(&mut self, frame: &Frame) -> Option<Vec<u8>> {
        let Frame::Box {
            sid,
            counter,
            ciphertext,
        } = frame
        else {
            return None;
        };
        if *sid != self.sid
            || *counter > MAX_COUNTER
            || self.last_received.is_some_and(|last| *counter <= last)
        {
            return None;
        }
        let plaintext = ChaCha20Poly1305::new((&self.recv).into())
            .decrypt((&nonce(*counter)).into(), ciphertext.as_slice())
            .ok()?;
        self.last_received = Some(*counter);
        Some(plaintext)
    }
}
fn nonce(counter: u64) -> [u8; 12] {
    let mut n = [0; 12];
    n[4..].copy_from_slice(&counter.to_le_bytes());
    n
}
