//! Portable durable attachment ingress. No UI, Swift, gateway or credential dependency.
//! The surrounding host still owns message admission; assembling files never admits a turn.
pub mod accepted;
pub mod admission;
pub mod crypto;
pub mod history;
mod journal;
pub mod native_queue;
pub mod outbox;
pub mod peers;
pub mod relay;
pub mod sequences;
pub mod steering;
pub mod stops;
pub mod thread_index;
pub mod transport;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const CHUNK_BYTES: u64 = 256 * 1024;
pub const FILE_BYTES: u64 = 5 * 1024 * 1024;
pub const MESSAGE_BYTES: u64 = 20 * 1024 * 1024;
const STAGED_BYTES: u64 = 256 * 1024 * 1024;
const STAGED_UPLOADS: usize = 128;
const SAFE_INTEGER: u64 = 9_007_199_254_740_991;
static TEMP_ID: AtomicU64 = AtomicU64::new(0);

fn invalid_id(s: &str) -> bool {
    s.is_empty() || s.encode_utf16().count() > 128
}
fn valid_hash(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn reason(s: &str) -> Value {
    json!({"reason":s})
}
fn progress(n: u64, reason: Option<&str>) -> Value {
    match reason {
        Some(r) => json!({"nextOffset":n,"reason":r}),
        None => json!({"nextOffset":n}),
    }
}
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn private_open(path: &Path, create_new: bool) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    if create_new {
        options.create_new(true);
    } else {
        options.create(true).truncate(false);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)
}
fn private_dir(path: &Path) -> io::Result<()> {
    if let Ok(meta) = fs::symlink_metadata(path) {
        if !meta.is_dir() || meta.file_type().is_symlink() {
            return Err(io::ErrorKind::InvalidData.into());
        }
        return Ok(());
    }
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)
}
fn sync_dir(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        File::open(path)?.sync_all()?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}
fn read_private(path: &Path, limit: u64) -> io::Result<Vec<u8>> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() || file.metadata()?.len() > limit {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(bytes)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Meta {
    thread_id: String,
    total_bytes: u64,
    sha256: String,
    deadline: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Chunk {
    message_id: String,
    index: u64,
    offset: u64,
    total_bytes: u64,
    sha256: String,
    deadline: u64,
    data: String,
}
#[derive(Deserialize)]
struct Descriptor {
    name: String,
    mime: String,
    bytes: u64,
    sha256: String,
}

/// Exactly one worker owns this staging root. The lock is released by the OS on crash;
/// the lock file is retained so a second owner cannot acquire a replacement inode.
pub struct AttachmentStore {
    root: PathBuf,
    _owner: File,
    last_prune: u64,
}
impl Drop for AttachmentStore {
    fn drop(&mut self) {
        let _ = self._owner.unlock();
    }
}
impl AttachmentStore {
    pub fn open(state_dir: &Path) -> io::Result<Self> {
        let root = state_dir.join("attachment-uploads");
        private_dir(&root)?;
        let owner = private_open(&root.join(".rust-owner.lock"), false)?;
        owner.try_lock().map_err(io::Error::other)?;
        Ok(Self {
            root,
            _owner: owner,
            last_prune: 0,
        })
    }
    fn folder(&self, source: &str, message_id: &str) -> PathBuf {
        let mut hash = Sha256::new();
        hash.update(source.as_bytes());
        hash.update([0]);
        hash.update(message_id.as_bytes());
        self.root.join(format!("{:x}", hash.finalize()))
    }
    fn folders(&self) -> io::Result<Vec<PathBuf>> {
        fs::read_dir(&self.root)?
            .filter_map(|entry| match entry {
                Err(e) => Some(Err(e)),
                Ok(e) => valid_hash(&e.file_name().to_string_lossy()).then_some(Ok(e.path())),
            })
            .collect()
    }
    fn prune(&mut self, now: u64) -> io::Result<()> {
        if self.last_prune != 0 && now.saturating_sub(self.last_prune) < 10 * 60_000 {
            return Ok(());
        }
        self.last_prune = now;
        for path in self.folders()? {
            let meta = fs::symlink_metadata(&path)?;
            if !meta.is_dir() || meta.file_type().is_symlink() {
                return Err(io::ErrorKind::InvalidData.into());
            }
            if SystemTime::now()
                .duration_since(meta.modified()?)
                .unwrap_or_default()
                > Duration::from_secs(45 * 60)
            {
                fs::remove_dir_all(path)?;
            }
        }
        Ok(())
    }
    fn meta(path: &Path) -> io::Result<Meta> {
        let bytes = read_private(path, 4096)?;
        serde_json::from_slice(&bytes).map_err(io::Error::other)
    }
    fn declared_bytes(folder: &Path) -> io::Result<u64> {
        let mut total = 0u64;
        for entry in fs::read_dir(folder)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name
                .strip_suffix(".json")
                .is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
            {
                let meta = Self::meta(&entry.path())?;
                if meta.total_bytes > FILE_BYTES {
                    return Err(io::ErrorKind::InvalidData.into());
                }
                total = total
                    .checked_add(meta.total_bytes)
                    .ok_or(io::ErrorKind::InvalidData)?;
            }
        }
        Ok(total)
    }
    fn reserve(&self, folder: &Path, index: u64, meta: &Meta) -> io::Result<Option<&'static str>> {
        let meta_path = folder.join(format!("{index}.json"));
        match fs::symlink_metadata(&meta_path) {
            Ok(_) => {
                return Ok(
                    (Self::meta(&meta_path)? != *meta).then_some("conflicting-attachment-upload")
                );
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        if Self::declared_bytes(folder)? + meta.total_bytes > MESSAGE_BYTES {
            return Ok(Some("oversized-attachments"));
        }
        let mut total = meta.total_bytes;
        for path in self.folders()? {
            total += Self::declared_bytes(&path)?;
        }
        if total > STAGED_BYTES {
            return Ok(Some("attachment-storage-full"));
        }
        let temp = folder.join(format!(
            "{index}.{}.{}.tmp",
            std::process::id(),
            TEMP_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let result = (|| {
            let mut file = private_open(&temp, true)?;
            file.write_all(&serde_json::to_vec(meta).map_err(io::Error::other)?)?;
            file.sync_all()?;
            // Never replace committed metadata, including from a prior runtime version.
            fs::hard_link(&temp, &meta_path)?;
            sync_dir(folder)
        })();
        let _ = fs::remove_file(&temp);
        result?;
        Ok(None)
    }
    pub fn chunk(&mut self, source: &str, thread_id: &str, data: &Value, now: u64) -> Value {
        let Ok(data) = serde_json::from_value::<Chunk>(data.clone()) else {
            return progress(0, Some("invalid-attachment-chunk"));
        };
        if invalid_id(&data.message_id)
            || invalid_id(thread_id)
            || data.index >= 10
            || data.total_bytes == 0
            || data.total_bytes > FILE_BYTES
            || data.offset > SAFE_INTEGER
            || data.deadline > SAFE_INTEGER
            || data.deadline <= now
            || data.deadline > now.saturating_add(35 * 60_000)
            || !valid_hash(&data.sha256)
            || data.data.len() as u64 > CHUNK_BYTES * 4 / 3 + 4
        {
            return progress(0, Some("invalid-attachment-chunk"));
        }
        let Ok(bytes) = STANDARD.decode(&data.data) else {
            return progress(0, Some("invalid-attachment-chunk"));
        };
        if STANDARD.encode(&bytes) != data.data
            || bytes.is_empty()
            || bytes.len() as u64 > CHUNK_BYTES
            || data.offset.saturating_add(bytes.len() as u64) > data.total_bytes
        {
            return progress(0, Some("invalid-attachment-chunk"));
        }
        self.write_chunk(source, thread_id, &data, &bytes, now)
            .unwrap_or_else(|_| progress(0, Some("attachment-storage-failed")))
    }
    fn write_chunk(
        &mut self,
        source: &str,
        thread_id: &str,
        data: &Chunk,
        bytes: &[u8],
        now: u64,
    ) -> io::Result<Value> {
        self.prune(now)?;
        let folder = self.folder(source, &data.message_id);
        let folders = self.folders()?;
        if !folders.contains(&folder) && folders.len() >= STAGED_UPLOADS {
            return Ok(progress(0, Some("attachment-storage-full")));
        }
        private_dir(&folder)?;
        let meta = Meta {
            thread_id: thread_id.into(),
            total_bytes: data.total_bytes,
            sha256: data.sha256.clone(),
            deadline: data.deadline,
        };
        if let Some(reason) = self.reserve(&folder, data.index, &meta)? {
            return Ok(progress(0, Some(reason)));
        }
        let mut file = private_open(&folder.join(format!("{}.bin", data.index)), false)?;
        let size = file.metadata()?.len();
        if size > data.total_bytes {
            return Ok(progress(0, Some("conflicting-attachment-upload")));
        }
        if data.offset < size {
            file.seek(SeekFrom::Start(data.offset))?;
            let mut prior = vec![0; bytes.len().min((size - data.offset) as usize)];
            file.read_exact(&mut prior)?;
            return Ok(progress(
                size,
                (prior != bytes[..prior.len()]).then_some("conflicting-attachment-upload"),
            ));
        }
        if data.offset > size {
            return Ok(progress(size, None));
        }
        file.seek(SeekFrom::Start(size))?;
        file.write_all(bytes)?;
        file.sync_all()?;
        sync_dir(&folder)?;
        Ok(progress(file.metadata()?.len(), None))
    }
    pub fn assemble(
        &self,
        source: &str,
        message_id: &str,
        thread_id: &str,
        descriptors: &Value,
        deadline: u64,
    ) -> Value {
        let Ok(items) = serde_json::from_value::<Vec<Descriptor>>(descriptors.clone()) else {
            return reason("invalid-attachment-commit");
        };
        if invalid_id(message_id)
            || invalid_id(thread_id)
            || deadline > SAFE_INTEGER
            || items.is_empty()
            || items.len() > 10
            || items.iter().any(|d| {
                d.bytes > FILE_BYTES
                    || !valid_hash(&d.sha256)
                    || d.name.is_empty()
                    || d.name.len() > 256
                    || d.mime.is_empty()
                    || d.mime.len() > 128
            })
            || items.iter().map(|d| d.bytes).sum::<u64>() > MESSAGE_BYTES
        {
            return reason("invalid-attachment-commit");
        }
        self.read_assembly(source, message_id, thread_id, &items, deadline)
            .unwrap_or_else(|e| {
                if e.kind() == io::ErrorKind::NotFound {
                    json!({"missing":{"index":0,"nextOffset":0}})
                } else {
                    reason("attachment-storage-failed")
                }
            })
    }
    fn read_assembly(
        &self,
        source: &str,
        message_id: &str,
        thread_id: &str,
        items: &[Descriptor],
        deadline: u64,
    ) -> io::Result<Value> {
        let folder = self.folder(source, message_id);
        let mut attachments = Vec::new();
        for (index, d) in items.iter().enumerate() {
            if d.bytes == 0 && d.sha256 == digest(b"") {
                attachments.push(json!({"name":d.name,"mime":d.mime,"data":""}));
                continue;
            }
            let loaded = (|| {
                let meta = Self::meta(&folder.join(format!("{index}.json")))?;
                let path = folder.join(format!("{index}.bin"));
                let bytes = read_private(&path, FILE_BYTES)?;
                Ok::<_, io::Error>((meta, bytes))
            })();
            let (meta, bytes) = match loaded {
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    return Ok(json!({"missing":{"index":index,"nextOffset":0}}));
                }
                other => other?,
            };
            if meta.thread_id != thread_id
                || meta.deadline != deadline
                || meta.total_bytes != d.bytes
                || meta.sha256 != d.sha256
            {
                return Ok(reason("conflicting-attachment-upload"));
            }
            if bytes.len() as u64 != d.bytes {
                return Ok(json!({"missing":{"index":index,"nextOffset":bytes.len()}}));
            }
            if digest(&bytes) != d.sha256 {
                return Ok(reason("corrupt-attachment-upload"));
            }
            attachments.push(json!({"name":d.name,"mime":d.mime,"data":STANDARD.encode(bytes)}));
        }
        Ok(json!({"attachments":attachments}))
    }
}
