use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

pub const MAX_COUNTER: u64 = (1 << 53) - 1;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Frame {
    Init {
        signing: [u8; 32],
        message: Vec<u8>,
    },
    Response {
        sid: [u8; 8],
        message: Vec<u8>,
    },
    Box {
        sid: [u8; 8],
        counter: u64,
        ciphertext: Vec<u8>,
    },
}
pub fn b64(bytes: impl AsRef<[u8]>) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}
pub fn unb64(s: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(s).ok()
}
impl Frame {
    pub fn decode(payload: &str) -> Option<Self> {
        Self::from_bytes(&unb64(payload)?)
    }
    pub fn from_bytes(b: &[u8]) -> Option<Self> {
        match b.first()? {
            0x11 if (129..=65568).contains(&b.len()) => Some(Self::Init {
                signing: b[1..33].try_into().ok()?,
                message: b[33..].to_vec(),
            }),
            0x12 if (57..=65544).contains(&b.len()) => Some(Self::Response {
                sid: b[1..9].try_into().ok()?,
                message: b[9..].to_vec(),
            }),
            0x13 if b.len() >= 33 => {
                let counter = u64::from_le_bytes(b[9..17].try_into().ok()?);
                (counter <= MAX_COUNTER).then(|| Self::Box {
                    sid: b[1..9].try_into().unwrap(),
                    counter,
                    ciphertext: b[17..].to_vec(),
                })
            }
            _ => None,
        }
    }
    pub fn bytes(&self) -> Vec<u8> {
        match self {
            Self::Init { signing, message } => {
                [vec![0x11], signing.to_vec(), message.clone()].concat()
            }
            Self::Response { sid, message } => [vec![0x12], sid.to_vec(), message.clone()].concat(),
            Self::Box {
                sid,
                counter,
                ciphertext,
            } => [
                vec![0x13],
                sid.to_vec(),
                counter.to_le_bytes().to_vec(),
                ciphertext.clone(),
            ]
            .concat(),
        }
    }
    pub fn encode(&self) -> String {
        b64(self.bytes())
    }
}
