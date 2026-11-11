use crate::{
    frame::{b64, unb64},
    link::Link,
};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Standing {
    CodeOnly,
    Known,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Pairing {
    pub v: u8,
    pub relay: String,
    pub room: String,
    pub host_key: String,
    pub ed_priv: String,
    pub x_priv: String,
    pub standing: Standing,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secret: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub paired_at: Option<u64>,
}
impl Pairing {
    pub fn new(link: &Link, ed: [u8; 32], x: [u8; 32]) -> Self {
        Self {
            v: 1,
            relay: link.relay.clone(),
            room: link.room.clone(),
            host_key: b64(link.host_key),
            ed_priv: b64(ed),
            x_priv: b64(x),
            standing: Standing::CodeOnly,
            token: Some(link.token.clone()),
            secret: Some(link.secret.clone()),
            paired_at: None,
        }
    }
    pub fn keys(&self) -> Option<([u8; 32], [u8; 32], [u8; 32])> {
        Some((
            unb64(&self.ed_priv)?.try_into().ok()?,
            unb64(&self.x_priv)?.try_into().ok()?,
            unb64(&self.host_key)?.try_into().ok()?,
        ))
    }
    pub fn valid(&self) -> bool {
        if self.v != 1
            || self.keys().is_none()
            || (self.standing == Standing::CodeOnly && self.token.is_none())
        {
            return false;
        }
        // Reuse pairing-link validation at the disk trust boundary; known pairings omit both one-time values.
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("relay", &self.relay)
            .append_pair("room", &self.room)
            .append_pair("key", &self.host_key)
            .append_pair("token", self.token.as_deref().unwrap_or("AA"))
            .append_pair("secret", self.secret.as_deref().unwrap_or("AA"))
            .finish();
        Link::parse(&format!("yorozu://pair?{query}")).is_ok()
    }
}
pub trait Protector: Send + Sync {
    fn protect(&self, data: &[u8]) -> io::Result<Vec<u8>>;
    fn unprotect(&self, data: &[u8]) -> io::Result<Vec<u8>>;
}
#[cfg(feature = "insecure-plaintext-store")]
pub struct PlainProtector;
#[cfg(feature = "insecure-plaintext-store")]
impl Protector for PlainProtector {
    fn protect(&self, data: &[u8]) -> io::Result<Vec<u8>> {
        Ok(data.to_vec())
    }
    fn unprotect(&self, data: &[u8]) -> io::Result<Vec<u8>> {
        Ok(data.to_vec())
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Loaded {
    Missing,
    Unreadable,
    Pairing(Pairing),
}
pub struct FileStore {
    pub dir: PathBuf,
    protector: Box<dyn Protector>,
}
impl FileStore {
    pub fn new(dir: impl Into<PathBuf>, protector: Box<dyn Protector>) -> Self {
        Self {
            dir: dir.into(),
            protector,
        }
    }
    pub fn load(&self) -> Loaded {
        let data = match fs::read(self.dir.join("pairing.bin")) {
            Ok(data) => data,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Loaded::Missing,
            Err(_) => return Loaded::Unreadable,
        };
        let pairing = self
            .protector
            .unprotect(&data)
            .ok()
            .and_then(|plain| serde_json::from_slice::<Pairing>(&plain).ok())
            .filter(Pairing::valid);
        pairing.map(Loaded::Pairing).unwrap_or(Loaded::Unreadable)
    }
    pub fn save(&self, pairing: &Pairing) -> io::Result<()> {
        if !pairing.valid() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid pairing",
            ));
        }
        let data = self.protector.protect(&serde_json::to_vec(pairing)?)?;
        fs::create_dir_all(&self.dir)?;
        let tmp = self.dir.join("pairing.bin.tmp");
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp)?;
        file.write_all(&data)?;
        file.sync_all()?;
        drop(file);
        atomic_replace(&tmp, &self.dir.join("pairing.bin"))
    }
    pub fn wipe(&self) -> io::Result<()> {
        for name in ["pairing.bin", "pairing.bin.tmp"] {
            if let Err(e) = fs::remove_file(self.dir.join(name)) {
                if e.kind() != io::ErrorKind::NotFound {
                    return Err(e);
                }
            }
        }
        Ok(())
    }
}
#[cfg(not(windows))]
fn atomic_replace(from: &Path, to: &Path) -> io::Result<()> {
    fs::rename(from, to)
}
#[cfg(windows)]
fn atomic_replace(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows::{
        core::PCWSTR,
        Win32::Storage::FileSystem::{
            MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
        },
    };
    let a: Vec<u16> = from.as_os_str().encode_wide().chain(Some(0)).collect();
    let b: Vec<u16> = to.as_os_str().encode_wide().chain(Some(0)).collect();
    unsafe {
        MoveFileExW(
            PCWSTR(a.as_ptr()),
            PCWSTR(b.as_ptr()),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
        .map_err(io::Error::other)
    }
}
#[cfg(windows)]
pub struct DpapiProtector;
#[cfg(windows)]
impl Protector for DpapiProtector {
    fn protect(&self, data: &[u8]) -> io::Result<Vec<u8>> {
        dpapi(data, true)
    }
    fn unprotect(&self, data: &[u8]) -> io::Result<Vec<u8>> {
        dpapi(data, false)
    }
}
#[cfg(windows)]
fn dpapi(data: &[u8], protect: bool) -> io::Result<Vec<u8>> {
    use windows::Win32::{
        Foundation::{LocalFree, HLOCAL},
        Security::Cryptography::{
            CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        },
    };
    let input = CRYPT_INTEGER_BLOB {
        cbData: data.len().try_into().map_err(io::Error::other)?,
        pbData: data.as_ptr().cast_mut(),
    };
    let mut output = CRYPT_INTEGER_BLOB::default();
    unsafe {
        if protect {
            CryptProtectData(
                &input,
                windows::core::PCWSTR::null(),
                None,
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                None,
                None,
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        }
        .map_err(io::Error::other)?;
        let result = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        let _ = LocalFree(Some(HLOCAL(output.pbData.cast())));
        Ok(result)
    }
}
