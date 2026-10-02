//! Authoritative immutable event transactions, with replayable thread/transcript projections.
use crate::{
    TEMP_ID, digest, invalid_id, private_dir, private_open, read_private, sync_dir, valid_hash,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
const RECORD_BYTES: u64 = 32 * 1024 * 1024;
const STORE_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const LOG_BYTES: u64 = 1024 * 1024 * 1024;
const RECORDS: usize = 65_536;
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn open_read(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() || file.metadata()?.len() > LOG_BYTES {
        return Err(invalid());
    }
    Ok(file)
}
// Settings are hand-editable; reject special files without a blocking pathname open.
fn settings_sample(path: &Path) -> io::Result<(File, Vec<u8>)> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > RECORD_BYTES {
        return Err(invalid());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Also close the regular-file/FIFO replacement race between precheck and open.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let mut file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > RECORD_BYTES {
        return Err(invalid());
    }
    same_file(path, &file)?;
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take(RECORD_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 != metadata.len() || file.metadata()?.len() != metadata.len() {
        return Err(invalid());
    }
    same_file(path, &file)?;
    Ok((file, bytes))
}
fn prefix(file: &mut File, length: u64) -> io::Result<String> {
    file.seek(SeekFrom::Start(0))?;
    let mut input = Read::by_ref(file).take(length);
    let mut sha = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut read = 0;
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        sha.update(&buffer[..count]);
        read += count as u64;
    }
    if read != length {
        return Err(invalid());
    }
    Ok(format!("{:x}", sha.finalize()))
}
#[cfg(unix)]
fn same_file(path: &Path, file: &File) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let a = fs::symlink_metadata(path)?;
    let b = file.metadata()?;
    if !a.is_file() || a.file_type().is_symlink() || a.dev() != b.dev() || a.ino() != b.ino() {
        return Err(invalid());
    }
    Ok(())
}
#[cfg(not(unix))]
fn same_file(path: &Path, file: &File) -> io::Result<()> {
    let a = fs::symlink_metadata(path)?;
    if !a.is_file() || a.file_type().is_symlink() || a.len() != file.metadata()?.len() {
        return Err(invalid());
    }
    Ok(())
}
// Normalize only a complete legacy row; the journal schema and prior raw bytes stay intact.
fn delimit(path: &Path, original: &File, length: u64, original_hash: &str) -> io::Result<String> {
    let mut options = OpenOptions::new();
    options.read(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path)?;
    same_file(path, &file)?;
    if file.metadata()?.len() != length || prefix(&mut file, length)? != original_hash {
        return Err(invalid());
    }
    same_file(path, &file)?;
    same_file(path, original)?;
    if file.seek(SeekFrom::End(0))? != length {
        return Err(invalid());
    }
    // Append mode preserves a concurrent writer's bytes; changed length fails closed below.
    file.write_all(b"\n")?;
    file.sync_all()?;
    same_file(path, &file)?;
    if file.metadata()?.len() != length + 1 || prefix(&mut file, length)? != original_hash {
        return Err(invalid());
    }
    file.seek(SeekFrom::Start(length))?;
    let mut delimiter = [0u8; 1];
    file.read_exact(&mut delimiter)?;
    if delimiter != *b"\n" {
        return Err(invalid());
    }
    let hash = prefix(&mut file, length + 1)?;
    same_file(path, &file)?;
    if file.metadata()?.len() != length + 1 {
        return Err(invalid());
    }
    sync_dir(path.parent().ok_or_else(invalid)?)?;
    Ok(hash)
}
pub(crate) fn publish(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path.parent().ok_or_else(invalid)?;
    let temporary = parent.join(format!(
        ".pending.{}.{}",
        std::process::id(),
        TEMP_ID.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = private_open(&temporary, true)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    fs::hard_link(&temporary, path)?;
    let _ = fs::remove_file(temporary);
    sync_dir(parent)
}
fn day(value: &Value) -> io::Result<String> {
    let ts = value
        .as_f64()
        .filter(|ts| ts.is_finite() && ts.abs() <= 8_640_000_000_000_000.0)
        .ok_or_else(invalid)?;
    let z = (ts.trunc() as i64).div_euclid(86_400_000) + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let date = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    if !(0..=9999).contains(&year) {
        return Err(invalid());
    }
    Ok(format!("{year:04}-{month:02}-{date:02}"))
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Target {
    folder: String,
    name: String,
    offset: u64,
    original_length: u64,
    before_hash: String,
    original_hash: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    key: String,
    operation_id: String,
    line: String,
    targets: Vec<Target>,
}
#[derive(Clone)]
struct Proof {
    targets: Vec<Target>,
    line_hash: String,
    line_bytes: u64,
}
pub struct History {
    root: PathBuf,
    directory: PathBuf,
    owner: File,
    committed: HashMap<String, Proof>,
    pending: Option<Entry>,
    bytes: u64,
    temporaries: usize,
    failed: bool,
    queue: Option<crate::native_queue::NativeQueue>,
    steering: Option<crate::steering::Steering>,
    crypto: Option<crate::crypto::HostCrypto>,
    sequences: Option<crate::sequences::Sequences>,
    catchup: crate::catchup::Catchup,
    paging: crate::paging::Paging,
    accepted: Option<crate::accepted::Accepted>,
    stops: Option<crate::stops::Stops>,
    admissions: Option<crate::admission::Admissions>,
    outbox: Option<crate::outbox::ChannelOutbox>,
    attempts: HashMap<String, (String, String, crate::paging::ProgressAnchor, Value)>,
}
impl Drop for History {
    fn drop(&mut self) {
        let _ = self.owner.unlock();
    }
}
impl History {
    pub fn open(root: &Path) -> io::Result<Self> {
        private_dir(root)?;
        let owner = private_open(&root.join(".rust-history-owner.lock"), false)?;
        owner.try_lock().map_err(io::Error::other)?;
        let directory = root.join(".rust-history");
        private_dir(&directory)?;
        sync_dir(root)?;
        let mut store = Self {
            root: root.into(),
            directory,
            owner,
            committed: HashMap::new(),
            pending: None,
            bytes: 0,
            temporaries: 0,
            failed: false,
            queue: None,
            steering: None,
            crypto: None,
            sequences: None,
            catchup: crate::catchup::Catchup::default(),
            paging: crate::paging::Paging::default(),
            accepted: None,
            stops: None,
            admissions: None,
            outbox: None,
            attempts: HashMap::new(),
        };
        let mut keys = HashSet::new();
        let mut done = HashSet::new();
        let mut pending = Vec::new();
        for item in fs::read_dir(&store.directory)? {
            let item = item?;
            let name = item.file_name().into_string().map_err(|_| invalid())?;
            let meta = fs::symlink_metadata(item.path())?;
            if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > RECORD_BYTES {
                return Err(invalid());
            }
            store.bytes = store.bytes.checked_add(meta.len()).ok_or_else(invalid)?;
            if store.bytes > STORE_BYTES {
                return Err(invalid());
            }
            if name.starts_with(".pending.") {
                store.temporaries += 1;
                if store.temporaries >= 128 {
                    return Err(invalid());
                }
                continue;
            }
            if let Some(key) = name.strip_suffix(".done") {
                if !valid_hash(key) {
                    return Err(invalid());
                }
                done.insert(key.to_owned());
                continue;
            }
            let key = name
                .strip_suffix(".json")
                .filter(|key| valid_hash(key))
                .ok_or_else(invalid)?;
            keys.insert(key.to_owned());
            if keys.len() > RECORDS {
                return Err(invalid());
            }
            let value: Value = serde_json::from_slice(&read_private(&item.path(), RECORD_BYTES)?)
                .map_err(io::Error::other)?;
            let entry: Entry =
                serde_json::from_value(value["entry"].clone()).map_err(io::Error::other)?;
            if value["checksum"] != digest(&serde_json::to_vec(&entry).map_err(io::Error::other)?)
                || entry.key != key
                || !store.valid_entry(&entry)
            {
                return Err(invalid());
            }
            let marker = store.directory.join(format!("{key}.done"));
            match fs::symlink_metadata(&marker) {
                Err(error) if error.kind() == io::ErrorKind::NotFound => pending.push(entry),
                _ => {
                    if read_private(&marker, 128)? != key.as_bytes() {
                        return Err(invalid());
                    }
                    store.committed.insert(
                        key.into(),
                        Proof {
                            targets: entry.targets,
                            line_hash: digest(entry.line.as_bytes()),
                            line_bytes: entry.line.len() as u64,
                        },
                    );
                }
            }
        }
        if !done.is_subset(&keys) || pending.len() > 1 {
            return Err(invalid());
        }
        store.pending = pending.pop();
        store.recover()?;
        Ok(store)
    }
    fn path(&self, target: &Target) -> PathBuf {
        self.root.join(&target.folder).join(&target.name)
    }
    fn valid_entry(&self, entry: &Entry) -> bool {
        if entry.targets.is_empty()
            || entry.targets.len() > 2
            || entry.line.len() as u64 > RECORD_BYTES
            || !entry.line.ends_with('\n')
            || invalid_id(&entry.operation_id)
        {
            return false;
        }
        let Ok(events) = entry
            .line
            .lines()
            .map(serde_json::from_str::<Value>)
            .collect::<Result<Vec<_>, _>>()
        else {
            return false;
        };
        if events.is_empty() || events.len() > 1024 {
            return false;
        }
        let event = &events[0];
        let Some(id) = event["threadId"].as_str().filter(|id| {
            id.encode_utf16().count() <= 128
                && (!entry
                    .targets
                    .iter()
                    .any(|target| target.folder == "threads")
                    || !id.is_empty())
        }) else {
            return false;
        };
        if !events.iter().all(|other| {
            other["threadId"] == event["threadId"]
                && other["id"].is_string()
                && other["kind"].is_string()
                && other["data"].is_object()
        }) {
            return false;
        }
        let mut seen = HashSet::new();
        entry.targets.iter().all(|target| {
            target.offset <= target.original_length
                && target.original_length <= LOG_BYTES
                && target.offset + entry.line.len() as u64 <= LOG_BYTES
                && valid_hash(&target.before_hash)
                && valid_hash(&target.original_hash)
                && seen.insert(&target.folder)
                && match target.folder.as_str() {
                    "threads" => {
                        target.name == format!("{}.jsonl", crate::thread_index::file_name(id))
                    }
                    "transcripts" => day(&event["ts"]).is_ok_and(|date| {
                        target.name == format!("{date}.jsonl")
                            && events
                                .iter()
                                .all(|event| day(&event["ts"]).is_ok_and(|value| value == date))
                    }),
                    _ => false,
                }
        }) && entry.key == digest(entry.operation_id.as_bytes())
    }
    fn prepare(&self, folder: String, name: String, line_length: u64) -> io::Result<Target> {
        let directory = self.root.join(&folder);
        private_dir(&directory)?;
        let path = directory.join(&name);
        let (length, complete, hash, before) = match open_read(&path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                (0, 0, digest(b""), digest(b""))
            }
            file => {
                let mut file = file?;
                let length = file.metadata()?.len();
                let mut complete = 0;
                let mut offset = 0;
                let mut buffer = [0u8; 65536];
                loop {
                    let count = file.read(&mut buffer)?;
                    if count == 0 {
                        break;
                    }
                    if let Some(last) = buffer[..count].iter().rposition(|byte| *byte == b'\n') {
                        complete = offset + last as u64 + 1;
                    }
                    offset += count as u64;
                }
                if offset != length || length - complete > RECORD_BYTES {
                    return Err(invalid());
                }
                same_file(&path, &file)?;
                let hash = prefix(&mut file, length)?;
                if complete < length {
                    file.seek(SeekFrom::Start(complete))?;
                    let mut tail = vec![0; (length - complete) as usize];
                    file.read_exact(&mut tail)?;
                    match serde_json::from_slice::<Value>(&tail) {
                        Ok(_) => {
                            if length + 1 + line_length > LOG_BYTES {
                                return Err(invalid());
                            }
                            same_file(&path, &file)?;
                            let normalized = delimit(&path, &file, length, &hash)?;
                            same_file(&path, &file)?;
                            if file.metadata()?.len() != length + 1
                                || prefix(&mut file, length + 1)? != normalized
                            {
                                return Err(invalid());
                            }
                            return Ok(Target {
                                folder,
                                name,
                                offset: length + 1,
                                original_length: length + 1,
                                before_hash: normalized.clone(),
                                original_hash: normalized,
                            });
                        }
                        Err(error) if crate::paging::unsupported_legacy(&error) => {
                            return Err(invalid());
                        }
                        Err(_) => {}
                    }
                }
                let before = if complete == length {
                    hash.clone()
                } else {
                    prefix(&mut file, complete)?
                };
                (length, complete, hash, before)
            }
        };
        if complete + line_length > LOG_BYTES {
            return Err(invalid());
        }
        Ok(Target {
            folder,
            name,
            offset: complete,
            original_length: length,
            before_hash: before,
            original_hash: hash,
        })
    }
    fn preserve_tail(&self, target: &Target, file: &mut File) -> io::Result<()> {
        let directory = self.root.join(&target.folder);
        let recovery = directory.join(format!(".history-recovery.{}.jsonl", target.original_hash));
        match fs::symlink_metadata(&recovery) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let mut count = 0;
                let mut bytes = 0u64;
                for item in fs::read_dir(&directory)? {
                    let item = item?;
                    if !item
                        .file_name()
                        .to_string_lossy()
                        .starts_with(".history-recovery.")
                    {
                        continue;
                    }
                    let meta = fs::symlink_metadata(item.path())?;
                    if !meta.is_file() || meta.file_type().is_symlink() {
                        return Err(invalid());
                    }
                    count += 1;
                    bytes = bytes.checked_add(meta.len()).ok_or_else(invalid)?;
                }
                if count >= 128 || bytes + target.original_length > STORE_BYTES {
                    return Err(invalid());
                }
                let temporary = directory.join(format!(
                    ".history-recovery.pending.{}.{}",
                    std::process::id(),
                    TEMP_ID.fetch_add(1, Ordering::Relaxed)
                ));
                let mut backup = private_open(&temporary, true)?;
                file.seek(SeekFrom::Start(0))?;
                if io::copy(
                    &mut Read::by_ref(file).take(target.original_length),
                    &mut backup,
                )? != target.original_length
                {
                    return Err(invalid());
                }
                backup.sync_all()?;
                drop(backup);
                fs::hard_link(&temporary, &recovery)?;
                let _ = fs::remove_file(temporary);
                sync_dir(&directory)?;
            }
            _ => {
                let mut backup = open_read(&recovery)?;
                if backup.metadata()?.len() != target.original_length
                    || prefix(&mut backup, target.original_length)? != target.original_hash
                {
                    return Err(invalid());
                }
            }
        }
        Ok(())
    }
    fn apply(&self, target: &Target, line: &[u8]) -> io::Result<()> {
        let path = self.path(target);
        private_dir(path.parent().ok_or_else(invalid)?)?;
        let existed = match fs::symlink_metadata(&path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => false,
            meta => {
                let meta = meta?;
                if !meta.is_file() || meta.file_type().is_symlink() {
                    return Err(invalid());
                }
                true
            }
        };
        let mut file = private_open(&path, !existed)?;
        let mut length = file.metadata()?.len();
        if length < target.offset
            || length > LOG_BYTES
            || prefix(&mut file, target.offset)? != target.before_hash
        {
            return Err(invalid());
        }
        if target.original_length > target.offset
            && length == target.original_length
            && prefix(&mut file, length)? == target.original_hash
        {
            self.preserve_tail(target, &mut file)?;
            same_file(&path, &file)?;
            file.set_len(target.offset)?;
            file.sync_all()?;
            length = target.offset;
        }
        let end = target.offset + line.len() as u64;
        if length > end {
            return Err(invalid());
        }
        file.seek(SeekFrom::Start(target.offset))?;
        let mut existing = vec![0; (length - target.offset) as usize];
        file.read_exact(&mut existing)?;
        if !line.starts_with(&existing) {
            return Err(invalid());
        }
        same_file(&path, &file)?;
        file.seek(SeekFrom::End(0))?;
        file.write_all(&line[existing.len()..])?;
        file.sync_all()?;
        sync_dir(path.parent().unwrap())?;
        same_file(&path, &file)?;
        if file.metadata()?.len() != end {
            return Err(invalid());
        }
        Ok(())
    }
    fn recover(&mut self) -> io::Result<()> {
        let Some(entry) = self.pending.as_ref() else {
            return Ok(());
        };
        for target in &entry.targets {
            self.apply(target, entry.line.as_bytes())?;
        }
        publish(
            &self.directory.join(format!("{}.done", entry.key)),
            entry.key.as_bytes(),
        )?;
        self.bytes += entry.key.len() as u64;
        self.committed.insert(
            entry.key.clone(),
            Proof {
                targets: entry.targets.clone(),
                line_hash: digest(entry.line.as_bytes()),
                line_bytes: entry.line.len() as u64,
            },
        );
        self.pending = None;
        Ok(())
    }
    fn append(&mut self, request: &Value) -> io::Result<Value> {
        self.recover()?;
        let events = if let Some(events) = request.get("events") {
            events
                .as_array()
                .ok_or_else(invalid)?
                .iter()
                .collect::<Vec<_>>()
        } else {
            vec![&request["event"]]
        };
        if events.is_empty() || events.len() > 1024 {
            return Err(invalid());
        }
        let event = events[0];
        let id = event["threadId"]
            .as_str()
            .filter(|id| {
                id.encode_utf16().count() <= 128 && (request["thread"] != true || !id.is_empty())
            })
            .ok_or_else(invalid)?;
        if !events.iter().all(|event| {
            event.is_object()
                && event["threadId"] == id
                && event["id"].is_string()
                && event["kind"].is_string()
                && event["data"].is_object()
        }) {
            return Err(invalid());
        }
        let operation_id = request["operationId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?
            .to_owned();
        let mut line = String::new();
        for event in &events {
            line.push_str(&serde_json::to_string(event).map_err(io::Error::other)?);
            line.push('\n');
            if line.len() as u64 > RECORD_BYTES {
                return Err(invalid());
            }
        }
        let mut destinations = Vec::new();
        if request["thread"] == true {
            destinations.push((
                "threads".into(),
                format!("{}.jsonl", crate::thread_index::file_name(id)),
            ));
        }
        if request["transcript"] == true {
            let expected = day(&event["ts"])?;
            if !events
                .iter()
                .all(|event| day(&event["ts"]).is_ok_and(|date| date == expected))
            {
                return Err(invalid());
            }
            destinations.push((
                "transcripts".into(),
                format!("{}.jsonl", day(&event["ts"])?),
            ));
        }
        if destinations.is_empty() {
            return Err(invalid());
        }
        let key = digest(operation_id.as_bytes());
        if let Some(proof) = self.committed.get(&key) {
            if proof.line_hash != digest(line.as_bytes())
                || proof
                    .targets
                    .iter()
                    .map(|target| (target.folder.clone(), target.name.clone()))
                    .collect::<Vec<_>>()
                    != destinations
            {
                return Ok(json!({"error":"conflicting-history-operation"}));
            }
            for target in &proof.targets {
                let path = self.path(target);
                let mut file = open_read(&path)?;
                if file.metadata()?.len() < target.offset + proof.line_bytes
                    || prefix(&mut file, target.offset)? != target.before_hash
                {
                    return Err(invalid());
                }
                file.seek(SeekFrom::Start(target.offset))?;
                let mut bytes = vec![0; proof.line_bytes as usize];
                file.read_exact(&mut bytes)?;
                if digest(&bytes) != proof.line_hash {
                    return Err(invalid());
                }
            }
            return Ok(json!({"stored":true,"key":key}));
        }
        if self.committed.len() >= RECORDS || self.temporaries >= 128 {
            return Err(invalid());
        }
        let targets = destinations
            .into_iter()
            .map(|(folder, name)| self.prepare(folder, name, line.len() as u64))
            .collect::<io::Result<Vec<_>>>()?;
        let entry = Entry {
            key: key.clone(),
            operation_id,
            line,
            targets,
        };
        let checksum = digest(&serde_json::to_vec(&entry).map_err(io::Error::other)?);
        let bytes = serde_json::to_vec(&json!({"entry":entry,"checksum":checksum}))
            .map_err(io::Error::other)?;
        if bytes.len() as u64 > RECORD_BYTES
            || self.bytes + bytes.len() as u64 + key.len() as u64 > STORE_BYTES
        {
            return Err(invalid());
        }
        publish(&self.directory.join(format!("{key}.json")), &bytes)?;
        self.bytes += bytes.len() as u64;
        self.pending = Some(entry);
        self.recover()?;
        Ok(json!({"stored":true,"key":key}))
    }
    fn queue_request(&mut self, request: &Value) -> Value {
        if self.queue.is_none() {
            match crate::native_queue::NativeQueue::open(&self.root) {
                Ok(queue) => self.queue = Some(queue),
                Err(_) => return json!({"error":"native-queue-storage-failed"}),
            }
        }
        self.queue.as_mut().unwrap().request(request)
    }
    fn steering_operation(record: &Value) -> String {
        format!(
            "native-steer:{}",
            digest(record["attemptId"].as_str().unwrap().as_bytes())
        )
    }
    fn steering_event_matches(record: &Value, event: &Value) -> bool {
        event["id"] == record["eventId"]
            && event["threadId"] == record["threadId"]
            && event["kind"] == "message"
            && event["data"]["role"] == "user"
            && event["data"]["delivery"] == "steer"
            && event["data"]["completionId"] == record["completionId"]
            && event["data"]["runId"] == record["completionId"]
    }
    fn steering_delivered(&mut self, record: &Value) -> io::Result<Value> {
        let result = self.steering.as_mut().unwrap().finish(
            record["eventId"].as_str().unwrap(),
            record["attemptId"].as_str().unwrap(),
            "delivered",
        );
        if result.get("error").is_some() {
            return Err(invalid());
        }
        let removal = self.queue_request(
            &json!({"op":"queue_remove","eventId":record["eventId"],"threadId":record["threadId"]}),
        );
        if removal.get("error").is_some() {
            return Err(invalid());
        }
        Ok(result)
    }
    fn steering_request(&mut self, request: &Value) -> io::Result<Value> {
        if self.steering.is_none() {
            self.steering = Some(crate::steering::Steering::open(&self.root)?);
            // A recovered projection is durable evidence of delivery even if its outcome/queue
            // cleanup was interrupted. Replay cleanup only, never the external SDK call.
            for record in self.steering.as_ref().unwrap().records() {
                if record["status"] == "rejected" {
                    continue;
                }
                let operation = Self::steering_operation(&record);
                let key = digest(operation.as_bytes());
                if !self.committed.contains_key(&key) {
                    if record["status"] == "delivered" {
                        return Err(invalid());
                    }
                    continue;
                }
                let value: Value = serde_json::from_slice(&read_private(
                    &self.directory.join(format!("{key}.json")),
                    RECORD_BYTES,
                )?)
                .map_err(io::Error::other)?;
                let line = value["entry"]["line"].as_str().ok_or_else(invalid)?;
                let event: Value = serde_json::from_str(line).map_err(io::Error::other)?;
                if !Self::steering_event_matches(&record, &event) {
                    return Err(invalid());
                }
                let proof=self.append(&json!({"op":"history_append","operationId":operation,"event":event,"thread":true,"transcript":true}))?;
                if proof.get("error").is_some() {
                    return Err(invalid());
                }
                self.steering_delivered(&record)?;
            }
        }
        if request["op"] != "steering_commit" {
            return Ok(self.steering.as_mut().unwrap().request(request));
        }
        let Some(record) = self
            .steering
            .as_ref()
            .unwrap()
            .get(request["eventId"].as_str().unwrap_or(""))
        else {
            return Ok(json!({"error":"unknown-steering-intent"}));
        };
        if record["attemptId"] != request["attemptId"]
            || record["status"] == "rejected"
            || !Self::steering_event_matches(&record, &request["event"])
        {
            return Ok(json!({"error":"conflicting-steering-outcome"}));
        }
        let proof=self.append(&json!({"op":"history_append","operationId":Self::steering_operation(&record),"event":request["event"],"thread":true,"transcript":true}))?;
        if proof.get("error").is_some() {
            return Ok(proof);
        }
        self.steering_delivered(&record)
    }
    fn run_ready(&mut self, request: &Value) -> io::Result<Value> {
        self.run_ready_with_fifo(request, true)
    }
    // FIFO is mandatory for dispatch. Only interrupted control preflight can defer it.
    fn run_ready_with_fifo(&mut self, request: &Value, fifo: bool) -> io::Result<Value> {
        let thread = request["threadId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?
            .to_owned();
        let origin = request["eventId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?
            .to_owned();
        let blocked = |reason: &str| json!({"ready":false,"reason":reason});
        let accepted = self.request(&json!({"op":"accepted_get","messageId":origin}));
        if accepted.get("error").is_some() {
            return Ok(accepted);
        }
        let entry = &accepted["entry"];
        if entry["threadId"] != thread
            || entry["id"] != origin
            || !["conversation", "legacy"].contains(&entry["purpose"].as_str().unwrap_or(""))
        {
            return Ok(blocked("not-accepted-conversation"));
        }
        for (op, key, result, reason) in [
            ("stop_get", "targetEventId", "record", "stopped"),
            ("admission_get", "messageId", "entry", "expired"),
        ] {
            let mut query = json!({"op":op});
            query[key] = json!(origin);
            let proof = self.request(&query);
            if proof.get("error").is_some() {
                return Ok(proof);
            }
            if !proof[result].is_null() {
                return Ok(blocked(reason));
            }
        }
        let steering = self.request(&json!({"op":"steering_get","eventId":origin}));
        if steering.get("error").is_some() {
            return Ok(steering);
        }
        if ["attempting", "delivered"]
            .contains(&steering["record"]["status"].as_str().unwrap_or(""))
        {
            return Ok(blocked("follow-up-owned"));
        }
        let active =
            self.request(&json!({"op":"steering_active","threadId":thread,"eventId":origin}));
        if active.get("error").is_some() {
            return Ok(active);
        }
        if active["unconfirmed"] == true {
            return Ok(blocked("follow-up-unconfirmed"));
        }
        if fifo {
            let queue = self.request(&json!({"op":"queue_head","threadId":thread}));
            if queue.get("error").is_some() {
                return Ok(queue);
            }
            if queue["eventId"] != origin {
                return Ok(blocked("not-queue-head"));
            }
        }
        let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
        let index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let home = index
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == thread)
            .ok_or_else(invalid)?;
        if home["agent"]
            .as_str()
            .is_none_or(|agent| agent.is_empty() || agent == "yorozu")
        {
            return Ok(blocked("not-native-worker"));
        }
        if home
            .get("nativeTurn")
            .is_some_and(|turn| turn["userEventId"] != origin)
        {
            return Ok(blocked("another-run-owned"));
        }
        let completion = format!("native:{origin}:final");
        let (seen, finished, hidden) =
            crate::paging::run_evidence(&self.root, &thread, entry, &completion)?;
        if hidden {
            return Ok(blocked("rewound-origin"));
        }
        if finished {
            return Ok(blocked("already-completed"));
        }
        if !seen {
            return Ok(blocked("missing-origin-history"));
        }
        Ok(
            json!({"ready":true,"eventId":origin,"threadId":thread,"agent":home["agent"],"completionId":completion}),
        )
    }
    fn run_turn_request(&mut self, request: &Value) -> io::Result<Value> {
        let thread = request["threadId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        if request["op"] == "run_turn_stop_fallback" {
            return self.stop_fallback(request, thread);
        }
        if request["op"] == "run_turn_preflight_finish" {
            return self.preflight_finish(request, thread);
        }
        if request["op"] == "run_turn_recover" {
            return self.boot_reconcile(request, thread);
        }
        if ["run_turn_unissued_pause", "run_turn_unissued_finish"]
            .contains(&request["op"].as_str().unwrap_or(""))
        {
            return self.unissued_turn(request, thread);
        }
        if request["op"] == "run_turn_rewind" {
            return self.rewind_turn(request, thread);
        }
        if request["op"] == "run_turn_stop_clear" {
            return self.stop_clear(request, thread);
        }
        let action = request["op"]
            .as_str()
            .filter(|op| ["run_turn_retry", "run_turn_dismiss"].contains(op))
            .ok_or_else(invalid)?;
        let denied = |reason: &str| json!({"applied":false,"queueRemoved":false,"reason":reason});
        let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
        let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let home = index
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["id"] == thread)
            .ok_or_else(invalid)?;
        let marker = home["nativeTurn"].clone();
        if marker["state"] != "interrupted"
            || marker["id"] != request["turnId"]
            || marker["userEventId"] != request["eventId"]
            || marker["attemptId"] != request["attemptId"]
            || self.attempts.get(thread).is_some_and(|owner| {
                marker["userEventId"] != owner.0
                    || marker["attemptId"] != owner.1
                    || home["agent"] != owner.3
            })
            || home["agent"]
                .as_str()
                .is_none_or(|agent| agent.is_empty() || agent == "yorozu")
        {
            return Ok(denied("another-run-owned"));
        }
        let legacy_stop = marker["id"]
            .as_str()
            .and_then(|id| id.strip_prefix("native:")?.strip_suffix(":final"));
        let origin = marker["userEventId"].as_str();
        if let Some(target) = origin.or(legacy_stop) {
            let stop = self.request(&json!({"op":"stop_get","targetEventId":target}));
            if stop.get("error").is_some() {
                return Ok(stop);
            }
            if !stop["record"].is_null() {
                return Ok(denied("stopped"));
            }
        }
        let mut queue_removed = false;
        let mut queue_repaired = false;
        if action == "run_turn_retry" {
            let Some(origin) = origin else {
                return Ok(denied("missing-origin"));
            };
            if marker["id"] != format!("native:{origin}:final") {
                return Ok(denied("another-run-owned"));
            }
            let query = json!({"op":"run_ready","threadId":thread,"eventId":origin});
            let mut proof = self.run_ready(&query)?;
            if proof["reason"] == "not-queue-head" {
                let eligibility = self.run_ready_with_fifo(&query, false)?;
                if eligibility["ready"] != true {
                    return Ok(eligibility);
                }
                let head = self.queue_request(&json!({"op":"queue_head","threadId":thread}));
                if head.get("error").is_some() {
                    return Ok(head);
                }
                // Legacy interrupted work can lack its row. Never append behind a successor.
                if head["eventId"].is_null() {
                    let stored = self.queue_request(
                        &json!({"op":"queue_enqueue","threadId":thread,"eventId":origin}),
                    );
                    if stored["stored"] != true {
                        return Ok(denied("queue-unconfirmed"));
                    }
                    queue_repaired = true;
                    proof = self
                        .run_ready(&query)
                        .unwrap_or_else(|_| json!({"error":"run-readiness-unconfirmed"}));
                }
            }
            if proof["ready"] != true {
                if queue_repaired {
                    proof["queueRepaired"] = json!(true);
                }
                return Ok(proof);
            }
            home["nativeTurn"]["recoveryAttempts"] = json!(0);
            home["nativeTurn"]
                .as_object_mut()
                .unwrap()
                .remove("pauseReason");
        } else {
            if let Some(origin) = origin {
                let stored = self.queue_request(
                    &json!({"op":"queue_remove","threadId":thread,"eventId":origin}),
                );
                if stored["stored"] != true {
                    return Ok(denied("queue-unconfirmed"));
                }
                queue_removed = true;
            }
            home.as_object_mut().unwrap().remove("nativeTurn");
        }
        // Keep the original checked revision through queue removal; never clear a replacement.
        let stored = crate::thread_index::request_native(
            &self.root,
            &json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}),
        );
        if stored["stored"] != true {
            let mut outcome = json!({"applied":false,"queueRemoved":queue_removed,"reason":"metadata-unconfirmed"});
            if queue_repaired {
                outcome["queueRepaired"] = json!(true);
            }
            return Ok(outcome);
        }
        if action == "run_turn_dismiss"
            && self.attempts.get(thread).is_some_and(|owner| {
                marker["userEventId"] == owner.0 && marker["attemptId"] == owner.1
            })
        {
            self.attempts.remove(thread);
        }
        Ok(
            json!({"applied":true,"queueRemoved":queue_removed,"queueRepaired":queue_repaired,"recoveryAttempts":if action == "run_turn_retry" { Some(0) } else { None }}),
        )
    }
    fn final_operation(
        prefix: &str,
        thread: &str,
        origin: &str,
        reason: &str,
        expected: &Value,
    ) -> io::Result<String> {
        // Match safe JSON.parse numeric notation without rounding opaque large values.
        fn canonical(value: &Value) -> Value {
            match value {
                Value::Array(values) => Value::Array(values.iter().map(canonical).collect()),
                Value::Object(values) => Value::Object(
                    values
                        .iter()
                        .map(|(key, value)| (key.clone(), canonical(value)))
                        .collect::<std::collections::BTreeMap<_, _>>()
                        .into_iter()
                        .collect(),
                ),
                Value::Number(number) => match number.as_f64() {
                    Some(n) if n.fract() == 0.0 && n.abs() <= crate::SAFE_INTEGER as f64 => {
                        json!(n as i64)
                    }
                    _ => value.clone(),
                },
                _ => value.clone(),
            }
        }
        Ok(format!(
            "{prefix}:{}",
            digest(
                &serde_json::to_vec(&json!([thread, origin, reason, canonical(expected)]))
                    .map_err(io::Error::other)?
            )
        ))
    }
    fn append_final(&mut self, operation: &str, event: &Value) -> io::Result<Value> {
        match self.append(&json!({"op":"history_append","operationId":operation,"event":event,"thread":true,"transcript":true})) {
            Ok(proof) => Ok(proof),
            Err(error) => { self.failed = true; Err(error) }
        }
    }
    fn retained_final(&mut self, operation: &str, template: &Value) -> io::Result<Option<Value>> {
        if let Err(error) = self.recover() {
            self.failed = true;
            return Err(error);
        }
        let key = digest(operation.as_bytes());
        if !self.committed.contains_key(&key) {
            return Ok(None);
        }
        let value: Value = serde_json::from_slice(&read_private(
            &self.directory.join(format!("{key}.json")),
            RECORD_BYTES,
        )?)
        .map_err(io::Error::other)?;
        let entry: Entry =
            serde_json::from_value(value["entry"].clone()).map_err(io::Error::other)?;
        if entry.key != key
            || entry.operation_id != operation
            || !self.valid_entry(&entry)
            || value["checksum"] != digest(&serde_json::to_vec(&entry).map_err(io::Error::other)?)
        {
            return Err(invalid());
        }
        let events: Vec<Value> = entry
            .line
            .lines()
            .map(serde_json::from_str)
            .collect::<Result<_, _>>()
            .map_err(io::Error::other)?;
        if events.len() != 1 {
            return Err(invalid());
        }
        let original = &events[0];
        let mut at_original_time = template.clone();
        at_original_time["ts"] = original["ts"].clone();
        if original != &at_original_time {
            return Err(invalid());
        }
        let proof = self.append_final(operation, original)?;
        if proof["stored"] != true {
            self.failed = true;
            return Err(invalid());
        }
        Ok(Some(original.clone()))
    }
    fn preflight_finish(&mut self, request: &Value, thread: &str) -> io::Result<Value> {
        let origin = request["eventId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let expected = request
            .get("expectedTurn")
            .filter(|v| v.is_null() || v.is_object())
            .ok_or_else(invalid)?;
        let reason = request["reason"]
            .as_str()
            .filter(|reason| ["missing-runner", "missing-folder"].contains(reason))
            .ok_or_else(invalid)?;
        day(&request["ts"])?;
        let operation = Self::final_operation("preflight", thread, origin, reason, expected)?;
        let root = self.root.clone();
        // Scope validation and final intent admission share the actual metadata writer lease.
        let writer = crate::thread_index::native_writer(&root)?;
        let bytes = crate::thread_index::current(&root)?.ok_or_else(invalid)?;
        let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let Some(home) = index
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["id"] == thread)
        else {
            return Ok(json!({"stored":false,"applied":false,"reason":"scope-replaced"}));
        };
        let agent = home["agent"]
            .as_str()
            .filter(|agent| !invalid_id(agent) && *agent != "yorozu")
            .ok_or_else(invalid)?;
        let completion = format!("native:{origin}:final");
        let text = if reason == "missing-runner" {
            format!("{agent} is no longer registered on this host.")
        } else {
            format!("{agent} needs one of this Mac's project folders, and this thread has none.")
        };
        let mut final_event = json!({"id":completion,"threadId":thread,"ts":request["ts"],"agentId":"main","kind":"message",
            "data":{"role":"agent","text":text,"done":true,"failed":true}});
        let retained = self.retained_final(&operation, &final_event)?;
        let stored = retained.is_some();
        if let Some(original) = retained {
            final_event = original;
        }
        let refusal = |reason: &str| json!({"stored":stored,"applied":false,"reason":reason,"final":if stored {Some(&final_event)}else{None}});
        let marker = home["nativeTurn"].clone();
        let already_retired = stored && marker.is_null() && !self.attempts.contains_key(thread);
        if !crate::thread_index::compatible(&marker, expected) && !already_retired
            || !marker.is_null()
                && (marker["id"] != completion
                    || marker.get("userEventId").is_some_and(|id| id != origin))
        {
            return Ok(refusal("scope-replaced"));
        }
        if !marker.is_null() && marker["state"] != "interrupted" {
            return Ok(refusal("run-active"));
        }
        if self.attempts.get(thread).is_some_and(|owner| {
            marker.is_null()
                || owner.0 != origin
                || marker["attemptId"] != owner.1
                || home["agent"] != owner.3
        }) {
            return Ok(refusal("scope-replaced"));
        }
        if !stored {
            let accepted = self.request(&json!({"op":"accepted_get","messageId":origin}));
            if accepted.get("error").is_some() {
                return Ok(accepted);
            }
            let entry = &accepted["entry"];
            if entry["id"] != origin
                || entry["threadId"] != thread
                || !["conversation", "legacy"].contains(&entry["purpose"].as_str().unwrap_or(""))
            {
                return Ok(refusal("not-accepted-conversation"));
            }
            let (seen, terminal, hidden) =
                crate::paging::run_evidence(&root, thread, entry, &completion)?;
            if !seen {
                return Ok(refusal("missing-origin"));
            }
            if hidden {
                return Ok(refusal("rewound-origin"));
            }
            if terminal {
                return Ok(
                    json!({"stored":false,"applied":false,"terminal":true,"reason":"already-completed"}),
                );
            }
            let proof = self.append_final(&operation, &final_event)?;
            if proof["stored"] != true {
                return Ok(proof);
            }
        }
        if marker.is_null() {
            return Ok(json!({"stored":true,"applied":true,"cleared":false,"final":final_event}));
        }
        home.as_object_mut().unwrap().remove("nativeTurn");
        let result =
            writer.replace(&json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}));
        if result["stored"] != true {
            return Ok(
                json!({"stored":true,"applied":false,"cleared":false,"reason":"metadata-unconfirmed","final":final_event}),
            );
        }
        self.attempts.remove(thread);
        Ok(json!({"stored":true,"applied":true,"cleared":true,"final":final_event}))
    }
    fn stop_fallback(&mut self, request: &Value, thread: &str) -> io::Result<Value> {
        let origin = request["eventId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let expected = request
            .get("expectedTurn")
            .filter(|v| v.is_null() || v.is_object())
            .ok_or_else(invalid)?;
        day(&request["ts"])?;
        let stop = self.request(&json!({"op":"stop_get","targetEventId":origin}));
        if stop.get("error").is_some() {
            return Ok(stop);
        }
        let record = &stop["record"];
        if record["targetEventId"] != origin
            || record["threadId"] != thread
            || record["preDispatch"] == true
        {
            return Ok(json!({"error":"stop-owner-unconfirmed"}));
        }
        let prior = record["status"].as_str().ok_or_else(invalid)?;
        let root = self.root.clone();
        let _writer = crate::thread_index::native_writer(&root)?;
        let bytes = crate::thread_index::current(&root)?.ok_or_else(invalid)?;
        let index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let home = index
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == thread)
            .ok_or_else(invalid)?;
        if home["agent"]
            .as_str()
            .is_none_or(|agent| agent.is_empty() || agent == "yorozu")
        {
            return Err(invalid());
        }
        let completion = format!("native:{origin}:final");
        let operation =
            Self::final_operation("stop-fallback", thread, origin, "stopped", expected)?;
        let template = json!({"id":completion,"threadId":thread,"ts":request["ts"],"agentId":"main","kind":"message",
            "data":{"role":"agent","text":record["partialText"].as_str().unwrap_or(""),"done":true,"interrupted":true}});
        let mut final_event = self.retained_final(&operation, &template)?;
        let mut outcome = "unconfirmed";
        let reason;
        if ["stopped", "completed", "withdrawn"].contains(&prior) {
            outcome = prior;
            reason = "already-recorded";
        } else if final_event.is_some() {
            outcome = "stopped";
            reason = "already-stored";
        } else {
            let accepted = self.request(&json!({"op":"accepted_get","messageId":origin}));
            if accepted.get("error").is_some() {
                return Ok(accepted);
            }
            let entry = &accepted["entry"];
            if entry["id"] == origin
                && entry["threadId"] == thread
                && ["conversation", "legacy"].contains(&entry["purpose"].as_str().unwrap_or(""))
            {
                let (seen, terminal, hidden, conflict) =
                    crate::paging::stop_evidence(&root, thread, entry, &completion)?;
                if !seen {
                    reason = "missing-origin";
                } else if hidden {
                    reason = "rewound-origin";
                } else if conflict {
                    reason = "completion-conflict";
                } else if let Some(terminal) = terminal {
                    outcome = terminal;
                    reason = "terminal-known";
                } else if !crate::thread_index::compatible(&home["nativeTurn"], expected) {
                    reason = "scope-replaced";
                } else if !home["nativeTurn"].is_null() || self.attempts.contains_key(thread) {
                    reason = "execution-unconfirmed";
                } else {
                    let head = self.queue_request(&json!({"op":"queue_head","threadId":thread}));
                    if head["eventId"] != origin || head.get("error").is_some() {
                        reason = "not-queue-head";
                    } else {
                        let proof = self.append_final(&operation, &template)?;
                        if proof["stored"] != true {
                            return Ok(proof);
                        }
                        final_event = Some(template);
                        outcome = "stopped";
                        reason = "pending-withdrawn";
                    }
                }
            } else {
                reason = "not-accepted-conversation";
            }
        }
        let mut next = record.clone();
        next["status"] = json!(outcome);
        let proof = self.request(&json!({"op":"stop_save","record":next}));
        let confirmed = proof["record"]["threadId"] == thread
            && proof["record"]["targetEventId"] == origin
            && proof["record"]["status"] == outcome;
        Ok(
            json!({"stopConfirmed":confirmed,"record":if confirmed {&proof["record"]}else{record},
            "stored":final_event.is_some(),"final":final_event,"reason":if confirmed {reason}else{"stop-status-unconfirmed"}}),
        )
    }
    // One immutable result per issued attempt. The lease protects scope validation and final
    // admission; metadata retirement remains the separate exact run_attempt_finish operation.
    fn worker_result(&mut self, request: &Value, thread: &str, origin: &str) -> io::Result<Value> {
        let attempt = request["attemptId"]
            .as_str()
            .filter(|id| id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(invalid)?;
        let agent = request["agent"]
            .as_str()
            .filter(|id| !invalid_id(id) && *id != "yorozu")
            .ok_or_else(invalid)?;
        let completion = format!("native:{origin}:final");
        let outcome = request["outcome"]
            .as_str()
            .filter(|v| ["completed", "stopped"].contains(v))
            .ok_or_else(invalid)?;
        let evidence = request["evidence"]
            .as_str()
            .filter(|v| {
                [
                    "returned",
                    "provider-terminal",
                    "process-exited",
                    "unconfirmed",
                ]
                .contains(v)
            })
            .ok_or_else(invalid)?;
        if request["contractVersion"] != 1
            || request["turnId"] != completion
            || request.get("failed").is_some_and(|v| !v.is_boolean())
            || request.get("text").is_some_and(|v| !v.is_string())
            || outcome == "completed" && !request["text"].is_string()
        {
            return Err(invalid());
        }
        let stop = self.request(&json!({"op":"stop_get","targetEventId":origin}));
        if stop.get("error").is_some() {
            return Ok(stop);
        }
        let record = stop["record"].clone();
        if !record.is_null() && (record["threadId"] != thread || record["preDispatch"] == true) {
            return Err(invalid());
        }
        let root = self.root.clone();
        let _writer = crate::thread_index::native_writer(&root)?;
        let scope = json!([attempt, agent]);
        let operation = Self::final_operation("worker-result", thread, origin, "v1", &scope)?;
        let mut final_event = None;
        let reason;
        let mut status = "unconfirmed";
        // Recover this operation before requiring a live epoch: lost responses cannot dispatch
        // again, change its timestamp/text, or acquire a replacement's metadata.
        let key = digest(operation.as_bytes());
        if self.committed.contains_key(&key) {
            let value: Value = serde_json::from_slice(&read_private(
                &self.directory.join(format!("{key}.json")),
                RECORD_BYTES,
            )?)
            .map_err(io::Error::other)?;
            let line = value["entry"]["line"].as_str().ok_or_else(invalid)?;
            let original: Value = serde_json::from_str(line).map_err(io::Error::other)?;
            let original_status = if original["data"]["interrupted"] == true {
                "stopped"
            } else {
                "completed"
            };
            if original["id"] != completion
                || original["threadId"] != thread
                || original["kind"] != "message"
                || original["data"]["role"] != "agent"
                || original["data"]["done"] != true
            {
                return Err(invalid());
            }
            if original_status != outcome
                || outcome == "completed"
                    && (original["data"]["text"] != request["text"]
                        || (original["data"]["failed"] == true) != (request["failed"] == true))
            {
                return Ok(
                    json!({"stored":false,"stopConfirmed":record.is_null(),"record":record,"reason":"conflicting-result"}),
                );
            }
            final_event = self.retained_final(&operation, &original)?;
            status = original_status;
            reason = "already-stored";
        } else {
            let bytes = crate::thread_index::current(&root)?.ok_or_else(invalid)?;
            let index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            let home = index
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["id"] == thread)
                .ok_or_else(invalid)?;
            let owned =
                self.attempts.get(thread).is_some_and(|owner| {
                    owner.0 == origin && owner.1 == attempt && owner.3 == agent
                }) && home["agent"] == agent
                    && home["nativeTurn"]["id"] == completion
                    && home["nativeTurn"]["userEventId"] == origin
                    && home["nativeTurn"]["attemptId"] == attempt
                    && home["nativeTurn"]["state"] == "running";
            let accepted = self.request(&json!({"op":"accepted_get","messageId":origin}));
            if accepted.get("error").is_some() {
                return Ok(accepted);
            }
            let entry = &accepted["entry"];
            if entry["id"] != origin
                || entry["threadId"] != thread
                || !["conversation", "legacy"].contains(&entry["purpose"].as_str().unwrap_or(""))
            {
                reason = "not-accepted-conversation";
            } else {
                let (seen, terminal, hidden, conflict) =
                    crate::paging::stop_evidence(&root, thread, entry, &completion)?;
                let expired = self.request(&json!({"op":"admission_get","messageId":origin}));
                if expired.get("error").is_some() {
                    return Ok(expired);
                }
                if !seen {
                    reason = "missing-origin";
                } else if hidden {
                    reason = "rewound-origin";
                } else if conflict {
                    reason = "completion-conflict";
                } else if ["stopped", "completed", "withdrawn"]
                    .contains(&record["status"].as_str().unwrap_or(""))
                {
                    reason = "already-recorded";
                } else if let Some(known) = terminal {
                    status = known;
                    reason = "terminal-known";
                } else if !owned {
                    reason = "scope-replaced";
                } else if !expired["entry"].is_null() {
                    reason = "expired";
                } else if outcome == "stopped"
                    && (record.is_null()
                        || !["provider-terminal", "process-exited"].contains(&evidence))
                    || outcome == "completed"
                        && (!record.is_null()
                            && (evidence != "provider-terminal" || request["failed"] == true)
                            || !["returned", "provider-terminal"].contains(&evidence))
                {
                    reason = "cessation-unconfirmed";
                } else {
                    // Stop text is exclusively the durable host partial, never the worker packet.
                    let text = if outcome == "stopped" {
                        record["partialText"].as_str().unwrap_or("")
                    } else {
                        request["text"].as_str().ok_or_else(invalid)?
                    };
                    let mut event = json!({"id":completion,"threadId":thread,"ts":crate::now_ms(),"agentId":"main","kind":"message","data":{"role":"agent","text":text,"done":true}});
                    if outcome == "stopped" {
                        event["data"]["interrupted"] = json!(true);
                    }
                    if outcome == "completed" && request["failed"] == true {
                        event["data"]["failed"] = json!(true);
                    }
                    let proof = self.append_final(&operation, &event)?;
                    if proof["stored"] != true {
                        return Ok(proof);
                    }
                    final_event = Some(event);
                    status = outcome;
                    reason = "worker-result-stored";
                }
            }
        }
        if record.is_null() {
            return Ok(
                json!({"stored":final_event.is_some(),"final":final_event,"stopConfirmed":true,"record":null,"reason":reason}),
            );
        }
        let prior = record["status"].as_str().ok_or_else(invalid)?;
        if ["stopped", "completed", "withdrawn"].contains(&prior) {
            status = prior;
        }
        let mut next = record.clone();
        next["status"] = json!(status);
        let proof = self.request(&json!({"op":"stop_save","record":next}));
        let confirmed = proof["record"]["threadId"] == thread
            && proof["record"]["targetEventId"] == origin
            && proof["record"]["status"] == status;
        Ok(
            json!({"stored":final_event.is_some(),"final":final_event,"stopConfirmed":confirmed,"record":if confirmed {&proof["record"]} else {&record},"reason":if confirmed {reason} else {"stop-status-unconfirmed"}}),
        )
    }
    fn unissued_turn(&mut self, request: &Value, thread: &str) -> io::Result<Value> {
        let origin = request["eventId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let completion = format!("native:{origin}:final");
        let expected = request
            .get("expectedTurn")
            .filter(|v| v.is_null() || v.is_object())
            .ok_or_else(invalid)?;
        let pause = request["op"] == "run_turn_unissued_pause";
        if request["turnId"] != completion {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        if request
            .get("pauseReason")
            .is_some_and(|reason| reason != "unconfirmed")
        {
            return Err(invalid());
        }
        let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
        let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let Some(home) = index
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["id"] == thread)
        else {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        };
        let marker = home["nativeTurn"].clone();
        if home["agent"]
            .as_str()
            .is_none_or(|agent| agent.is_empty() || agent == "yorozu")
            || !crate::thread_index::compatible(&marker, expected)
            || !marker.is_null()
                && (marker["id"] != completion
                    || marker.get("userEventId").is_some_and(|id| id != origin))
        {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        // Presence, including malformed/null fields, is never an unissued marker.
        if marker.get("attemptId").is_some() || self.attempts.contains_key(thread) {
            return Ok(json!({"applied":false,"reason":"run-issued"}));
        }
        if pause {
            let accepted = self.request(&json!({"op":"accepted_get","messageId":origin}));
            if accepted.get("error").is_some() {
                return Ok(accepted);
            }
            let entry = &accepted["entry"];
            if entry["id"] != origin
                || entry["threadId"] != thread
                || !["conversation", "legacy"].contains(&entry["purpose"].as_str().unwrap_or(""))
            {
                return Ok(json!({"applied":false,"reason":"not-accepted-conversation"}));
            }
            let (seen, terminal, hidden) =
                crate::paging::run_evidence(&self.root, thread, entry, &completion)?;
            if !seen {
                return Ok(json!({"applied":false,"reason":"missing-origin"}));
            }
            if terminal {
                return Ok(json!({"applied":false,"terminal":true,"reason":"already-completed"}));
            }
            if hidden {
                return Ok(json!({"applied":false,"reason":"rewound-origin"}));
            }
            for (op, key, result, reason) in [
                ("stop_get", "targetEventId", "record", "stopped"),
                ("admission_get", "messageId", "entry", "expired"),
            ] {
                let mut query = json!({"op":op});
                query[key] = json!(origin);
                let proof = self.request(&query);
                if proof.get("error").is_some() {
                    return Ok(proof);
                }
                if !proof[result].is_null() {
                    return Ok(json!({"applied":false,"reason":reason}));
                }
            }
            if marker.is_null() {
                let head = self.queue_request(&json!({"op":"queue_head","threadId":thread}));
                if head.get("error").is_some() {
                    return Ok(head);
                }
                if head["eventId"] != origin {
                    return Ok(json!({"applied":false,"reason":"not-queue-head"}));
                }
                home["nativeTurn"] = json!({"id":completion,"userEventId":origin,"state":"interrupted","recoveryAttempts":0});
            } else {
                home["nativeTurn"]["state"] = json!("interrupted");
                home["nativeTurn"]["userEventId"] = json!(origin);
            }
            if let Some(reason) = request.get("pauseReason") {
                home["nativeTurn"]["pauseReason"] = reason.clone();
            }
        } else {
            // Pure retirement needs retained terminal evidence, not dispatch permission/FIFO.
            let (seen, terminal, _, _) =
                crate::paging::boot_evidence(&self.root, thread, Some(origin), &completion)?;
            if !seen || !terminal {
                return Ok(json!({"applied":false,"reason":"terminal-unconfirmed"}));
            }
            if marker.is_null() {
                return Ok(json!({"applied":true,"cleared":false}));
            }
            home.as_object_mut().unwrap().remove("nativeTurn");
        }
        let turn = home["nativeTurn"].clone();
        let stored = crate::thread_index::request_native(
            &self.root,
            &json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}),
        );
        if stored["stored"] != true {
            return Ok(json!({"applied":false,"reason":"metadata-unconfirmed"}));
        }
        if pause {
            Ok(json!({"applied":true,"turn":turn}))
        } else {
            Ok(json!({"applied":true,"cleared":true}))
        }
    }
    fn rewind_turn(&mut self, request: &Value, thread: &str) -> io::Result<Value> {
        let rewind = request["rewindId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let request_id = request["requestId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let expected = request
            .get("expectedTurn")
            .filter(|v| v.is_null() || v.is_object())
            .ok_or_else(invalid)?;
        let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
        let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let Some(home) = index
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["id"] == thread)
        else {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        };
        if home["agent"]
            .as_str()
            .is_none_or(|agent| agent.is_empty() || agent == "yorozu")
        {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        let marker = home["nativeTurn"].clone();
        let origin = marker["userEventId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .or_else(|| {
                if marker.get("userEventId").is_none() {
                    marker["id"]
                        .as_str()?
                        .strip_prefix("native:")?
                        .strip_suffix(":final")
                        .filter(|id| !invalid_id(id))
                } else {
                    None
                }
            })
            .map(str::to_owned);
        let ready = self.queue_request(&json!({"op":"queue_open"}));
        if ready["stored"] != true {
            return Ok(json!({"applied":false,"reason":"queue-unconfirmed"}));
        }
        let mut candidates = self.queue.as_ref().unwrap().rewind_candidates(thread)?;
        if let Some(origin) = &origin {
            candidates.push(origin.clone());
        }
        let Some(hidden) =
            crate::paging::rewind_evidence(&self.root, thread, rewind, request_id, &candidates)?
        else {
            return Ok(json!({"applied":false,"reason":"rewind-unconfirmed"}));
        };
        let mut outcome = self.queue.as_mut().unwrap().retire_rewound(thread, &hidden);
        outcome["applied"] = json!(false);
        if outcome["queueConfirmed"] != true {
            outcome["reason"] = json!("queue-unconfirmed");
            return Ok(outcome);
        }
        if !crate::thread_index::compatible(&marker, expected) {
            outcome["reason"] = json!("scope-replaced");
            return Ok(outcome);
        }
        if marker.is_null() || origin.as_ref().is_none_or(|id| !hidden.contains(id)) {
            outcome["applied"] = json!(true);
            outcome["cleared"] = json!(false);
            return Ok(outcome);
        }
        let origin = origin.unwrap();
        if marker["id"] != format!("native:{origin}:final") {
            outcome["reason"] = json!("scope-replaced");
            return Ok(outcome);
        }
        if marker["state"] != "interrupted" {
            outcome["reason"] = json!("run-active");
            return Ok(outcome);
        }
        if self.attempts.get(thread).is_some_and(|owner| {
            owner.0 != origin || marker["attemptId"] != owner.1 || home["agent"] != owner.3
        }) {
            outcome["reason"] = json!("scope-replaced");
            return Ok(outcome);
        }
        home.as_object_mut().unwrap().remove("nativeTurn");
        let stored = crate::thread_index::request_native(
            &self.root,
            &json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}),
        );
        if stored["stored"] != true {
            outcome["reason"] = json!("metadata-unconfirmed");
            return Ok(outcome);
        }
        self.attempts.remove(thread);
        outcome["applied"] = json!(true);
        outcome["cleared"] = json!(true);
        Ok(outcome)
    }
    fn stop_clear(&mut self, request: &Value, thread: &str) -> io::Result<Value> {
        let origin = request["eventId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let completion = format!("native:{origin}:final");
        let expected = request
            .get("expectedTurn")
            .filter(|value| value.is_null() || value.is_object())
            .ok_or_else(invalid)?;
        if request["turnId"] != completion {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        let proof = self.request(&json!({"op":"stop_get","targetEventId":origin}));
        if proof.get("error").is_some() {
            return Ok(proof);
        }
        let stop = &proof["record"];
        if stop["threadId"] != thread
            || !["unconfirmed", "stopped"].contains(&stop["status"].as_str().unwrap_or(""))
        {
            return Ok(json!({"applied":false,"reason":"stop-unconfirmed"}));
        }
        let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
        let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let Some(home) = index
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["id"] == thread)
        else {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        };
        if home["agent"]
            .as_str()
            .is_none_or(|agent| agent.is_empty() || agent == "yorozu")
        {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        let marker = home["nativeTurn"].clone();
        if !crate::thread_index::compatible(&marker, expected) {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        if marker.is_null() {
            return Ok(json!({"applied":true,"cleared":false,"stopStatus":stop["status"]}));
        }
        if marker["id"] != completion || marker.get("userEventId").is_some_and(|id| id != origin) {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        if marker["state"] != "interrupted" {
            return Ok(json!({"applied":false,"reason":"run-active"}));
        }
        if self.attempts.get(thread).is_some_and(|owner| {
            owner.0 != origin || marker["attemptId"] != owner.1 || home["agent"] != owner.3
        }) {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        home.as_object_mut().unwrap().remove("nativeTurn");
        let stored = crate::thread_index::request_native(
            &self.root,
            &json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}),
        );
        if stored["stored"] != true {
            return Ok(json!({"applied":false,"reason":"metadata-unconfirmed"}));
        }
        self.attempts.remove(thread);
        Ok(json!({"applied":true,"cleared":true,"stopStatus":stop["status"]}))
    }
    fn boot_reconcile(&mut self, request: &Value, thread: &str) -> io::Result<Value> {
        let expected = request
            .get("expectedTurn")
            .filter(|value| value.is_object())
            .ok_or_else(invalid)?;
        let preview = request["preview"].as_bool().ok_or_else(invalid)?;
        let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
        let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let Some(home) = index
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["id"] == thread)
        else {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        };
        if home
            .get("nativeTurn")
            .is_none_or(|marker| !crate::thread_index::compatible(marker, expected))
            || home["agent"]
                .as_str()
                .is_none_or(|agent| agent.is_empty() || agent == "yorozu")
        {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        if self.attempts.contains_key(thread) {
            return Ok(json!({"applied":false,"reason":"run-active"}));
        }
        let marker = home["nativeTurn"].clone();
        let completion = marker["id"].as_str().ok_or_else(invalid)?;
        let origin = marker["userEventId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .or_else(|| {
                if marker.get("userEventId").is_none() {
                    completion
                        .strip_prefix("native:")?
                        .strip_suffix(":final")
                        .filter(|id| !invalid_id(id))
                } else {
                    None
                }
            });
        let (seen, finished, hidden_origin, hidden_final) =
            crate::paging::boot_evidence(&self.root, thread, origin, completion)?;
        let issued = marker.get("attemptId").is_some();
        let canonical = origin.is_some_and(|id| completion == format!("native:{id}:final"));
        let legacy_terminal = !issued && origin.is_none() && marker.get("userEventId").is_none();
        let outcome;
        if seen && hidden_origin {
            home.as_object_mut().unwrap().remove("nativeTurn");
            outcome = "rewound";
        } else if finished && !hidden_final && (seen || legacy_terminal) && (!issued || canonical) {
            home.as_object_mut().unwrap().remove("nativeTurn");
            outcome = "completed";
        } else {
            home["nativeTurn"]["state"] = json!("interrupted");
            if seen && marker.get("userEventId").is_none() {
                home["nativeTurn"]["userEventId"] = json!(origin);
            }
            let uncertain = origin.is_some() && !seen
                || marker.get("userEventId").is_some() && origin.is_none()
                || issued && !canonical;
            if uncertain {
                if home["nativeTurn"].get("pauseReason").is_none() {
                    home["nativeTurn"]["pauseReason"] = json!("unconfirmed");
                }
                outcome = "unconfirmed";
            } else {
                outcome = "paused";
            }
        }
        if preview {
            return Ok(
                json!({"checked":true,"outcome":outcome,"wasRunning":marker["state"] == "running"}),
            );
        }
        let stored = crate::thread_index::request_native(
            &self.root,
            &json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}),
        );
        if stored["stored"] != true {
            return Ok(json!({"applied":false,"reason":"metadata-unconfirmed"}));
        }
        Ok(json!({"applied":true,"outcome":outcome,"wasRunning":marker["state"] == "running"}))
    }
    // Permission, question and startup callers always require effect currency.
    fn native_prompt_owner(&mut self, scope: &Value, card: &Value) -> io::Result<bool> {
        self.native_worker_owner(scope, card, "effect")
    }
    fn native_worker_owner(&mut self, scope: &Value, card: &Value, mode: &str) -> io::Result<bool> {
        let thread = card["threadId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let origin = scope["eventId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let attempt = scope["attemptId"]
            .as_str()
            .filter(|id| id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(invalid)?;
        let turn = format!("native:{origin}:final");
        if scope["turnId"] != turn {
            return Err(invalid());
        }
        let current = self.attempt_request(&json!({"op":"run_attempt_current","threadId":thread,"eventId":origin,"attemptId":attempt,"mode":mode}))?;
        if current.get("error").is_some() {
            return Err(invalid());
        }
        if current["current"] != true {
            return Ok(false);
        }
        let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
        let index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let home = index
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == thread)
            .ok_or_else(invalid)?;
        if home["nativeTurn"]["id"] != turn
            || home["agent"] != card["data"]["nativeAgent"]
            || home["agent"]
                .as_str()
                .is_none_or(|a| a.is_empty() || a == "yorozu")
        {
            return Ok(false);
        }
        let accepted = self.request(&json!({"op":"accepted_get","messageId":origin}));
        if accepted.get("error").is_some()
            || accepted["entry"]["threadId"] != thread
            || !["conversation", "legacy"]
                .contains(&accepted["entry"]["purpose"].as_str().unwrap_or(""))
        {
            return Err(invalid());
        }
        let (seen, terminal, hidden, conflict) =
            crate::paging::stop_evidence(&self.root, thread, &accepted["entry"], &turn)?;
        Ok(seen && terminal.is_none() && !hidden && !conflict)
    }
    fn native_prompt_replay(
        &mut self,
        operation: &str,
        event: &Value,
        fingerprint: &str,
    ) -> io::Result<Option<Value>> {
        let question = event["kind"] == "question_answer";
        let prefix = if question { "question" } else { "approval" };
        let key_field = if question { "questionId" } else { "actionId" };
        if let Err(error) = self.recover() {
            self.failed = true;
            return Err(error);
        }
        let key = digest(operation.as_bytes());
        if !self.committed.contains_key(&key) {
            return Ok(None);
        }
        let value: Value = serde_json::from_slice(&read_private(
            &self.directory.join(format!("{key}.json")),
            RECORD_BYTES,
        )?)
        .map_err(io::Error::other)?;
        let entry: Entry =
            serde_json::from_value(value["entry"].clone()).map_err(io::Error::other)?;
        if entry.key != key
            || entry.operation_id != operation
            || !self.valid_entry(&entry)
            || value["checksum"] != digest(&serde_json::to_vec(&entry).map_err(io::Error::other)?)
        {
            return Err(invalid());
        }
        let events: Vec<Value> = entry
            .line
            .lines()
            .map(serde_json::from_str)
            .collect::<Result<_, _>>()
            .map_err(io::Error::other)?;
        let status = events.last().ok_or_else(invalid)?;
        if status["kind"] != format!("{prefix}_status")
            || status["threadId"] != event["threadId"]
            || status["id"]
                != format!(
                    "{prefix}:{}:status",
                    event["id"].as_str().ok_or_else(invalid)?
                )
            || status["data"]["requestId"] != event["id"]
        {
            return Err(invalid());
        }
        if status["data"]["nativeRequestHash"] != fingerprint
            || status["data"][key_field] != event["data"][key_field]
        {
            return Ok(Some(
                json!({"stored":false,"execute":false,"reason":"conflicting-request"}),
            ));
        }
        let applied = status["data"]["status"] == "applied";
        if !["applied", "no-longer-needed", "expired", "rejected"]
            .contains(&status["data"]["status"].as_str().unwrap_or(""))
            || events.len() != if applied { 2 } else { 1 }
            || applied
                && (events[0]["id"] != event["id"]
                    || events[0]["threadId"] != event["threadId"]
                    || events[0]["kind"] != format!("{prefix}_answer")
                    || events[0]["data"] != event["data"])
        {
            return Err(invalid());
        }
        let proof = self.append(&json!({"op":"history_append","operationId":operation,"events":events,"thread":true,"transcript":true}));
        if !proof.is_ok_and(|proof| proof["stored"] == true) {
            self.failed = true;
            return Err(invalid());
        }
        Ok(Some(
            json!({"stored":true,"execute":false,"replayed":true,"status":status,"events":events}),
        ))
    }
    fn native_prompt_request(&mut self, request: &Value) -> io::Result<Value> {
        let question = request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("native_question_"));
        let prefix = if question { "question" } else { "approval" };
        let key_field = if question { "questionId" } else { "actionId" };
        let card_operation = format!("native-{prefix}-card");
        let decision_operation = format!("native-{prefix}-decision");
        let request_operation = format!("native-{prefix}-request");
        let event = &request["event"];
        let thread = event["threadId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let id = event["id"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let action = event["data"][key_field]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let ts = event["ts"]
            .as_f64()
            .filter(|ts| ts.fract() == 0.0 && ts.abs() <= crate::SAFE_INTEGER as f64)
            .ok_or_else(invalid)?;
        day(&event["ts"])?;
        let root = self.root.clone();
        let _writer = crate::thread_index::native_writer(&root)?;
        if request["op"] == format!("native_{prefix}_raise") {
            let valid_card = if question {
                event["data"]["question"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty() && s.len() <= 32_768)
                    && event["data"]["options"].as_array().is_some_and(|options| {
                        options.len() <= 64
                            && options.iter().all(|option| {
                                option
                                    .as_str()
                                    .is_some_and(|s| !s.is_empty() && s.len() <= 4096)
                            })
                    })
                    && event["data"]
                        .get("allowOther")
                        .is_none_or(Value::is_boolean)
            } else {
                event["data"]["actionClass"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty() && s.len() <= 4096)
                    && event["data"]["target"].is_string()
            };
            if event["kind"] != format!("{prefix}_card")
                || !valid_card
                || event["data"].get("nativeRun").is_some()
            {
                return Err(invalid());
            }
            let scope = &request["scope"];
            if !self.native_prompt_owner(scope, event)? {
                return Ok(json!({"stored":false,"reason":"scope-replaced"}));
            }
            let operation = Self::final_operation(
                &card_operation,
                thread,
                scope["eventId"].as_str().ok_or_else(invalid)?,
                action,
                scope,
            )?;
            let mut card = event.clone();
            card["data"]["nativeRun"] = scope.clone();
            if let Some(saved) = self.retained_final(&operation, &card)? {
                return Ok(json!({"stored":true,"event":saved}));
            }
            let (prior, _) =
                crate::paging::native_prompt_evidence(&self.root, thread, action, id, question)?;
            if prior.is_some() {
                return Err(invalid());
            }
            let proof = self.append_final(&operation, &card)?;
            if proof["stored"] != true {
                return Err(invalid());
            }
            return Ok(json!({"stored":true,"event":card}));
        }
        let valid_answer = if question {
            event["data"]["answer"]
                .as_str()
                .is_some_and(|s| !s.trim().is_empty() && s.len() <= 65_536)
                && event["data"].get("source").is_none()
        } else {
            ["yes", "no", "discuss", "task", "always"]
                .contains(&event["data"]["answer"].as_str().unwrap_or(""))
                && event["data"]
                    .get("source")
                    .is_none_or(|s| s == "notification")
        };
        if request["op"] != format!("native_{prefix}_decide")
            || event["kind"] != format!("{prefix}_answer")
            || !valid_answer
        {
            return Err(invalid());
        }
        let live = request["live"].as_bool().ok_or_else(invalid)?;
        let operation =
            Self::final_operation(&decision_operation, thread, id, "answer", &Value::Null)?;
        let fingerprint =
            Self::final_operation(&request_operation, thread, id, "answer", &event["data"])?;
        if let Some(replay) = self.native_prompt_replay(&operation, event, &fingerprint)? {
            return Ok(replay);
        }
        let (card, settled) =
            crate::paging::native_prompt_evidence(&self.root, thread, action, id, question)?;
        if let Some(prior) = &settled {
            // Generic history rows cannot consume a registered permission or authorize replay.
            let prior_id = prior["data"]["requestId"]
                .as_str()
                .filter(|id| !invalid_id(id))
                .ok_or_else(invalid)?;
            let prior_operation = Self::final_operation(
                &decision_operation,
                thread,
                prior_id,
                "answer",
                &Value::Null,
            )?;
            let key = digest(prior_operation.as_bytes());
            if !self.committed.contains_key(&key) {
                return Err(invalid());
            }
            let value: Value = serde_json::from_slice(&read_private(
                &self.directory.join(format!("{key}.json")),
                RECORD_BYTES,
            )?)
            .map_err(io::Error::other)?;
            let entry: Entry =
                serde_json::from_value(value["entry"].clone()).map_err(io::Error::other)?;
            let original = entry.line.lines().next().ok_or_else(invalid)?;
            let original: Value = serde_json::from_str(original).map_err(io::Error::other)?;
            let hash = Self::final_operation(
                &request_operation,
                thread,
                prior_id,
                "answer",
                &original["data"],
            )?;
            let proof = self
                .native_prompt_replay(&prior_operation, &original, &hash)?
                .ok_or_else(invalid)?;
            if proof["stored"] != true || proof["status"] != *prior {
                return Err(invalid());
            }
        }
        let now = crate::now_ms() as f64;
        let status;
        if ts > now + 5.0 * 60_000.0 {
            status = "rejected";
        } else if !question && now >= ts + 30.0 * 60_000.0 {
            status = "expired";
        } else if settled.is_some() || !live {
            status = "no-longer-needed";
        } else if let Some(card) = card.as_ref() {
            let scope = &card["data"]["nativeRun"];
            if scope.is_null() {
                status = "no-longer-needed";
            } else {
                let operation = Self::final_operation(
                    &card_operation,
                    thread,
                    scope["eventId"].as_str().ok_or_else(invalid)?,
                    action,
                    scope,
                )?;
                if self.retained_final(&operation, card)?.as_ref() != Some(card) {
                    return Err(invalid());
                }
                let raised = card["ts"].as_f64().ok_or_else(invalid)?;
                if !question && now >= raised + 30.0 * 60_000.0 {
                    status = "expired";
                } else if !self.native_prompt_owner(scope, card)? {
                    status = "no-longer-needed";
                } else if question
                    && card["data"]["allowOther"] != true
                    && !card["data"]["options"]
                        .as_array()
                        .ok_or_else(invalid)?
                        .contains(&event["data"]["answer"])
                    || !question
                        && (event["data"]["source"] == "notification"
                            && card["data"]["actionClass"]
                                .as_str()
                                .ok_or_else(invalid)?
                                .starts_with("mcp__")
                            || ["task", "always"]
                                .contains(&event["data"]["answer"].as_str().unwrap_or("")))
                {
                    status = "rejected";
                } else {
                    status = "applied";
                }
            }
        } else {
            status = "no-longer-needed";
        }
        let outcome = json!({"id":format!("{prefix}:{id}:status"),"threadId":thread,"ts":crate::now_ms(),"agentId":"main","kind":format!("{prefix}_status"),"data":{"requestId":id,(key_field):action,"status":status,"nativeRequestHash":fingerprint}});
        let events = if status == "applied" {
            vec![event.clone(), outcome.clone()]
        } else {
            vec![outcome.clone()]
        };
        // A delayed phone answer may belong to a different day: its original timestamp remains
        // readable in clientTs while this one transaction uses the host's admission day.
        let mut events = events;
        if status == "applied" {
            events[0]["clientTs"] = events[0]["ts"].clone();
            events[0]["ts"] = outcome["ts"].clone();
        }
        let proof = self.append(&json!({"op":"history_append","operationId":operation,"events":events,"thread":true,"transcript":true}));
        if !proof.is_ok_and(|proof| proof["stored"] == true) {
            self.failed = true;
            return Err(invalid());
        }
        Ok(
            json!({"stored":true,"execute":status == "applied" && (question || event["data"]["answer"] == "yes"),"replayed":false,"status":outcome,"events":events}),
        )
    }
    fn worker_policy_operation(
        thread: &str,
        origin: &str,
        completion: &str,
        attempt: &str,
        source: &str,
    ) -> io::Result<String> {
        Ok(format!(
            "worker-policy:{}",
            digest(
                &serde_json::to_vec(&json!([1, thread, origin, completion, attempt, source]))
                    .map_err(io::Error::other)?
            )
        ))
    }
    fn worker_activity(
        &mut self,
        request: &Value,
        thread: &str,
        origin: &str,
    ) -> io::Result<Value> {
        let attempt = request["attemptId"]
            .as_str()
            .filter(|id| id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(invalid)?;
        let source = request["source"]
            .as_str()
            .filter(|id| !invalid_id(id) && *id != "yorozu")
            .ok_or_else(invalid)?;
        let batch = request["requestId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let completion = format!("native:{origin}:final");
        if request["version"] != 1 || request["turnId"] != completion {
            return Err(invalid());
        }
        let scope = json!({"version":1,"threadId":thread,"eventId":origin,"turnId":completion,"attemptId":attempt,"source":source});
        let supplied = request["events"]
            .as_array()
            .filter(|events| !events.is_empty() && events.len() <= 256)
            .ok_or_else(invalid)?;
        let mut events = Vec::with_capacity(supplied.len());
        let mut size = 0;
        let nonempty = |value: &Value| value.as_str().is_some_and(|s| !s.is_empty());
        for input in supplied {
            if input["threadId"] != thread
                || input["agentId"] != "main"
                || !nonempty(&input["id"])
                || input["id"] == origin
                || input["id"] == completion
                || input.get("workerRun").is_some_and(|value| value != &scope)
            {
                return Err(invalid());
            }
            let data = &input["data"];
            let valid = match input["kind"].as_str() {
                Some("thought") => {
                    data["text"].is_string() && data.get("transient").is_none_or(Value::is_boolean)
                }
                Some("tool_call") => {
                    nonempty(&data["callId"]) && nonempty(&data["name"]) && data["args"].is_object()
                }
                Some("tool_result") => {
                    nonempty(&data["callId"])
                        && data["ok"].is_boolean()
                        && data["output"].is_string()
                        && data.get("denied").is_none_or(Value::is_boolean)
                        && data.get("truncated").is_none_or(Value::is_boolean)
                        && data.get("chunkOffset").is_none()
                        && data.get("nextOffset").is_none()
                        && if data["truncated"] == true {
                            data["fullResultRef"].as_str().is_some_and(valid_hash)
                        } else {
                            data.get("fullResultRef").is_none()
                        }
                }
                _ => false,
            };
            if !valid || day(&input["ts"])? != day(&supplied[0]["ts"])? {
                return Err(invalid());
            }
            let mut event = input.clone();
            event["workerRun"] = scope.clone();
            size += serde_json::to_vec(&event).map_err(io::Error::other)?.len() + 1;
            if size > 8 * 1024 * 1024 {
                return Err(invalid());
            }
            events.push(event);
        }
        let operation = format!(
            "worker-stream:{}",
            digest(&serde_json::to_vec(&json!([scope, batch])).map_err(io::Error::other)?)
        );
        let key = digest(operation.as_bytes());
        let root = self.root.clone();
        // Replay owns only the original observations, even after the live epoch has disappeared.
        {
            let _writer = crate::thread_index::native_writer(&root)?;
            self.recover().inspect_err(|_| self.failed = true)?;
            if self.committed.contains_key(&key) {
                let original = (|| -> io::Result<Vec<Value>> {
                    let value: Value = serde_json::from_slice(&read_private(
                        &self.directory.join(format!("{key}.json")),
                        RECORD_BYTES,
                    )?)
                    .map_err(io::Error::other)?;
                    let entry: Entry =
                        serde_json::from_value(value["entry"].clone()).map_err(io::Error::other)?;
                    if entry.key != key
                        || entry.operation_id != operation
                        || !self.valid_entry(&entry)
                        || entry.targets.len() != 2
                        || self
                            .committed
                            .get(&key)
                            .is_none_or(|proof| proof.line_hash != digest(entry.line.as_bytes()))
                        || value["checksum"]
                            != digest(&serde_json::to_vec(&entry).map_err(io::Error::other)?)
                    {
                        return Err(invalid());
                    }
                    let original: Vec<Value> = entry
                        .line
                        .lines()
                        .map(serde_json::from_str)
                        .collect::<Result<_, _>>()
                        .map_err(io::Error::other)?;
                    Ok(original)
                })()
                .inspect_err(|_| self.failed = true)?;
                if original != events {
                    return Ok(json!({"stored":false,"reason":"conflicting-request"}));
                }
                let proof=self.append(&json!({"op":"history_append","operationId":operation,"events":original,"thread":true,"transcript":true})).inspect_err(|_| self.failed = true)?;
                if proof["stored"] != true {
                    self.failed = true;
                    return Err(invalid());
                }
                return Ok(
                    json!({"stored":true,"replayed":true,"operationId":operation,"events":original}),
                );
            }
        }
        let policy = Self::worker_policy_operation(thread, origin, &completion, attempt, source)?;
        // Do not call the policy's creation path from an observation request.
        if !self.committed.contains_key(&digest(policy.as_bytes())) {
            return Ok(json!({"stored":false,"reason":"startup-unconfirmed"}));
        }
        let permit = self.worker_policy(request, thread, origin)?;
        if permit["stored"] != true || permit["execute"] != false || permit["replayed"] != true {
            return Err(invalid());
        }
        let _writer = crate::thread_index::native_writer(&root)?;
        let card = json!({"threadId":thread,"data":{"nativeAgent":source}});
        if !self.native_worker_owner(&scope, &card, "owned")? {
            return Ok(json!({"stored":false,"reason":"scope-replaced"}));
        }
        // Admission binds the preview/reference. The guarded downloader separately validates blob bytes.
        let proof=self.append(&json!({"op":"history_append","operationId":operation,"events":events,"thread":true,"transcript":true})).inspect_err(|_| self.failed = true)?;
        if proof["stored"] != true {
            self.failed = true;
            return Err(invalid());
        }
        Ok(json!({"stored":true,"replayed":false,"operationId":operation,"events":events}))
    }
    fn worker_launch(&mut self, request: &Value, thread: &str, origin: &str) -> io::Result<Value> {
        let attempt = request["attemptId"]
            .as_str()
            .filter(|id| id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(invalid)?;
        let source = request["source"]
            .as_str()
            .filter(|id| !invalid_id(id) && *id != "yorozu")
            .ok_or_else(invalid)?;
        let completion = format!("native:{origin}:final");
        if request["version"] != 1 || request["turnId"] != completion {
            return Err(invalid());
        }
        let input = &request["input"];
        let nonempty = |value: &Value| value.as_str().is_some_and(|text| !text.is_empty());
        if !input.is_object()
            || !input["text"].is_string()
            || !input
                .as_object()
                .unwrap()
                .keys()
                .all(|key| ["text", "attachments", "skill"].contains(&key.as_str()))
            || input.get("attachments").is_some_and(|files| {
                files.as_array().is_none_or(|files| {
                    files.len() > 256
                        || files.iter().any(|file| {
                            !file.is_object()
                                || !["name", "mime", "path"]
                                    .iter()
                                    .all(|key| nonempty(&file[*key]))
                                || file
                                    .as_object()
                                    .unwrap()
                                    .keys()
                                    .any(|key| !["name", "mime", "path"].contains(&key.as_str()))
                        })
                })
            })
            || input.get("skill").is_some_and(|skill| {
                !skill.is_object()
                    || !nonempty(&skill["name"])
                    || !nonempty(&skill["path"])
                    || skill
                        .as_object()
                        .unwrap()
                        .keys()
                        .any(|key| !["name", "path"].contains(&key.as_str()))
            })
            || serde_json::to_vec(input).map_err(io::Error::other)?.len() > 8 * 1024 * 1024
        {
            return Err(invalid());
        }
        let scope = json!({"eventId":origin,"turnId":completion,"attemptId":attempt});
        let operation = format!(
            "worker-launch:{}",
            digest(
                &serde_json::to_vec(&json!([1, thread, origin, completion, attempt, source]))
                    .map_err(io::Error::other)?
            )
        );
        let key = digest(operation.as_bytes());
        let root = self.root.clone();
        {
            let _writer = crate::thread_index::native_writer(&root)?;
            self.recover().inspect_err(|_| self.failed = true)?;
            if self.committed.contains_key(&key) {
                let original = (|| -> io::Result<Value> {
                    let value: Value = serde_json::from_slice(&read_private(
                        &self.directory.join(format!("{key}.json")),
                        RECORD_BYTES,
                    )?)
                    .map_err(io::Error::other)?;
                    let entry: Entry =
                        serde_json::from_value(value["entry"].clone()).map_err(io::Error::other)?;
                    if entry.key != key
                        || entry.operation_id != operation
                        || !self.valid_entry(&entry)
                        || entry.targets.len() != 1
                        || entry.targets[0].folder != "transcripts"
                        || self
                            .committed
                            .get(&key)
                            .is_none_or(|proof| proof.line_hash != digest(entry.line.as_bytes()))
                        || value["checksum"]
                            != digest(&serde_json::to_vec(&entry).map_err(io::Error::other)?)
                    {
                        return Err(invalid());
                    }
                    let events: Vec<Value> = entry
                        .line
                        .lines()
                        .map(serde_json::from_str)
                        .collect::<Result<_, _>>()
                        .map_err(io::Error::other)?;
                    if events.len() != 1 {
                        return Err(invalid());
                    }
                    let event = &events[0];
                    let packet = &event["data"];
                    if event["id"] != operation
                        || event["threadId"] != thread
                        || event["kind"] != "worker_launch"
                        || event["ts"] != packet["sampledAt"]
                        || packet["sampledAt"].as_u64().is_none()
                        || packet["version"] != 1
                        || packet["threadId"] != thread
                        || packet["eventId"] != origin
                        || packet["turnId"] != completion
                        || packet["attemptId"] != attempt
                        || packet["source"] != source
                        || !packet["bypass"].is_boolean()
                        || !packet["cwd"].is_string()
                        || ["codex", "claude-code"].contains(&source)
                            && packet["cwd"].as_str().unwrap().trim().is_empty()
                        || !packet["originFingerprint"].as_str().is_some_and(valid_hash)
                        || serde_json::to_vec(packet).map_err(io::Error::other)?.len()
                            > 8 * 1024 * 1024
                    {
                        return Err(invalid());
                    }
                    Ok(event.clone())
                })()
                .inspect_err(|_| self.failed = true)?;
                if original["data"]["input"] != *input {
                    return Ok(
                        json!({"stored":false,"execute":false,"reason":"conflicting-request"}),
                    );
                }
                let proof=self.append(&json!({"op":"history_append","operationId":operation,"event":original,"thread":false,"transcript":true})).inspect_err(|_| self.failed = true)?;
                if proof["stored"] != true {
                    self.failed = true;
                    return Err(invalid());
                }
                return Ok(
                    json!({"stored":true,"execute":false,"replayed":true,"operationId":operation,"packet":original["data"]}),
                );
            }
        }
        let policy_operation =
            Self::worker_policy_operation(thread, origin, &completion, attempt, source)?;
        if !self
            .committed
            .contains_key(&digest(policy_operation.as_bytes()))
        {
            return Ok(json!({"stored":false,"execute":false,"reason":"startup-unconfirmed"}));
        }
        let permit = self
            .worker_policy(request, thread, origin)
            .inspect_err(|_| self.failed = true)?;
        if permit["stored"] != true || permit["execute"] != false || permit["replayed"] != true {
            return Err(invalid());
        }
        let _writer = crate::thread_index::native_writer(&root)?;
        let card = json!({"threadId":thread,"data":{"nativeAgent":source}});
        if !self.native_prompt_owner(&scope, &card)? {
            return Ok(json!({"stored":false,"execute":false,"reason":"scope-replaced"}));
        }
        let bytes = crate::thread_index::current(&root)?.ok_or_else(invalid)?;
        let index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let home = index
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == thread)
            .ok_or_else(invalid)?;
        if home["agent"] != source
            || home["nativeTurn"]["id"] != completion
            || home["nativeTurn"]["userEventId"] != origin
            || home["nativeTurn"]["attemptId"] != attempt
            || home["nativeTurn"]["state"] != "running"
        {
            return Ok(json!({"stored":false,"execute":false,"reason":"scope-replaced"}));
        }
        let cwd = home["cwd"].as_str().unwrap_or("");
        if ["codex", "claude-code"].contains(&source) && cwd.trim().is_empty() {
            return Err(invalid());
        }
        let rewind =
            crate::paging::latest_rewind(&root, thread).inspect_err(|_| self.failed = true)?;
        let session = if home["nativeSessionRewindId"] == json!(rewind) {
            home["nativeSessionId"].clone()
        } else {
            Value::Null
        };
        let accepted = self.request(&json!({"op":"accepted_get","messageId":origin}));
        let fingerprint =
            crate::accepted::fingerprint(&accepted["entry"], &accepted["entry"]["event"])
                .ok_or_else(invalid)?;
        let sampled = crate::now_ms();
        // Frozen compatibility input is not yet a Root-authored bounded context packet or account entitlement.
        let bypass = permit["policy"]["bypass"] == true
            && permit["policy"]["yoloUntil"]
                .as_f64()
                .is_some_and(|until| until > sampled as f64);
        let packet = json!({"version":1,"threadId":thread,"eventId":origin,"turnId":completion,"attemptId":attempt,"source":source,
            "originFingerprint":fingerprint,"input":input,"cwd":cwd,"model":home["model"],"effort":home["effort"],"sessionId":session,
            "rewindId":rewind,"bypass":bypass,"sampledAt":sampled,"policyOperationId":policy_operation});
        if serde_json::to_vec(&packet).map_err(io::Error::other)?.len() > 8 * 1024 * 1024 {
            return Err(invalid());
        }
        if crate::thread_index::current(&root)?.as_deref() != Some(bytes.as_slice()) {
            return Ok(json!({"stored":false,"execute":false,"reason":"scope-replaced"}));
        }
        let event = json!({"id":operation,"threadId":thread,"ts":sampled,"agentId":"main","kind":"worker_launch","data":packet});
        let proof=self.append(&json!({"op":"history_append","operationId":operation,"event":event,"thread":false,"transcript":true})).inspect_err(|_|self.failed=true)?;
        if proof["stored"] != true {
            self.failed = true;
            return Err(invalid());
        }
        Ok(
            json!({"stored":true,"execute":true,"replayed":false,"operationId":operation,"packet":packet}),
        )
    }
    fn worker_policy(&mut self, request: &Value, thread: &str, origin: &str) -> io::Result<Value> {
        if request["version"].as_u64() != Some(1) {
            return Err(invalid());
        }
        let attempt = request["attemptId"]
            .as_str()
            .filter(|id| id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(invalid)?;
        let source = request["source"]
            .as_str()
            .filter(|source| !invalid_id(source) && *source != "yorozu")
            .ok_or_else(invalid)?;
        let completion = format!("native:{origin}:final");
        if request["turnId"] != completion {
            return Err(invalid());
        }
        let scope = json!({"eventId":origin,"turnId":completion,"attemptId":attempt});
        let operation =
            Self::worker_policy_operation(thread, origin, &completion, attempt, source)?;
        let key = digest(operation.as_bytes());
        let root = self.root.clone();
        let _writer = crate::thread_index::native_writer(&root)?;
        if let Err(error) = self.recover() {
            self.failed = true;
            return Err(error);
        }
        // Saved policy precedes settings resampling; an acknowledgement cannot mint another start.
        if self.committed.contains_key(&key) {
            let value: Value = serde_json::from_slice(&read_private(
                &self.directory.join(format!("{key}.json")),
                RECORD_BYTES,
            )?)
            .map_err(io::Error::other)?;
            let entry: Entry =
                serde_json::from_value(value["entry"].clone()).map_err(io::Error::other)?;
            if entry.key != key
                || entry.operation_id != operation
                || !self.valid_entry(&entry)
                || entry.targets.len() != 1
                || entry.targets[0].folder != "transcripts"
                || value["checksum"]
                    != digest(&serde_json::to_vec(&entry).map_err(io::Error::other)?)
            {
                return Err(invalid());
            }
            let events: Vec<Value> = entry
                .line
                .lines()
                .map(serde_json::from_str)
                .collect::<Result<_, _>>()
                .map_err(io::Error::other)?;
            if events.len() != 1 {
                return Err(invalid());
            }
            let event = &events[0];
            let policy = &event["data"];
            if event["id"] != operation
                || event["kind"] != "worker_policy"
                || event["threadId"] != thread
                || policy["version"] != 1
                || policy["threadId"] != thread
                || policy["eventId"] != origin
                || policy["turnId"] != completion
                || policy["attemptId"] != attempt
                || policy["source"] != source
                || !policy["bypass"].is_boolean()
                || policy["sampledAt"].as_u64().is_none()
                || event["ts"] != policy["sampledAt"]
                || !(policy["settingsHash"].is_null()
                    || policy["settingsHash"].as_str().is_some_and(valid_hash))
                || policy["bypass"] == true
                    && policy["yoloUntil"].as_f64().is_none_or(|until| {
                        !until.is_finite() || until <= policy["sampledAt"].as_u64().unwrap() as f64
                    })
            {
                return Err(invalid());
            }
            let proof = self.append(&json!({"op":"history_append","operationId":operation,"event":event,"thread":false,"transcript":true}));
            if !proof.is_ok_and(|proof| proof["stored"] == true) {
                self.failed = true;
                return Err(invalid());
            }
            return Ok(
                json!({"stored":true,"execute":false,"replayed":true,"operationId":operation,"policy":policy}),
            );
        }
        let card = json!({"threadId":thread,"data":{"nativeAgent":source}});
        if !self.native_prompt_owner(&scope, &card)? {
            return Ok(json!({"stored":false,"execute":false,"reason":"scope-replaced"}));
        }
        let sampled = crate::now_ms();
        let settings_path = root.join("approval.json");
        // The metadata lease does not serialize hand edits. Sample bounded, stable bytes only.
        let settings = match settings_sample(&settings_path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
            Ok((file, bytes)) => {
                if settings_sample(&settings_path)?.1 != bytes {
                    return Err(invalid());
                }
                same_file(&settings_path, &file)?;
                Some(bytes)
            }
        };
        let parsed: Value = settings
            .as_ref()
            .and_then(|bytes| serde_json::from_slice(bytes).ok())
            .unwrap_or(Value::Null);
        let until = parsed["yoloUntil"]
            .as_f64()
            .filter(|until| until.is_finite() && *until > sampled as f64);
        let bypass = parsed["yolo"] == true && until.is_some();
        let mut policy = json!({"version":1,"threadId":thread,"eventId":origin,"turnId":completion,"attemptId":attempt,"source":source,"bypass":bypass,"sampledAt":sampled,"settingsHash":settings.as_ref().map(|bytes| digest(bytes))});
        if bypass {
            policy["yoloUntil"] = parsed["yoloUntil"].clone();
        }
        let event = json!({"id":operation,"threadId":thread,"ts":sampled,"agentId":"main","kind":"worker_policy","data":policy});
        let proof = self.append(&json!({"op":"history_append","operationId":operation,"event":event,"thread":false,"transcript":true}));
        if !proof.is_ok_and(|proof| proof["stored"] == true) {
            self.failed = true;
            return Err(invalid());
        }
        Ok(
            json!({"stored":true,"execute":true,"replayed":false,"operationId":operation,"policy":policy}),
        )
    }
    fn attempt_request(&mut self, request: &Value) -> io::Result<Value> {
        use rand_core::{OsRng, RngCore};
        let thread = request["threadId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?
            .to_owned();
        let origin = request["eventId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?
            .to_owned();
        if request["op"] == "run_attempt_result" {
            return self.worker_result(request, &thread, &origin);
        }
        if request["op"] == "run_attempt_policy" {
            return self.worker_policy(request, &thread, &origin);
        }
        if request["op"] == "run_attempt_launch" {
            return self.worker_launch(request, &thread, &origin);
        }
        if request["op"] == "run_attempt_activity" {
            return self.worker_activity(request, &thread, &origin);
        }
        if ["run_attempt_pause", "run_attempt_finish"]
            .contains(&request["op"].as_str().unwrap_or(""))
        {
            return self.attempt_lifecycle(request, &thread, &origin);
        }
        if request["op"] == "run_attempt_claim" {
            let proof = self.run_ready(request)?;
            if proof["ready"] != true {
                return Ok(proof);
            }
            if !self.attempts.contains_key(&thread) && self.attempts.len() >= 1024 {
                return Ok(json!({"error":"run-attempt-capacity"}));
            }
            let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
            let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            let home = index
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|row| row["id"] == thread)
                .ok_or_else(invalid)?;
            if home["agent"] != proof["agent"]
                || self.attempts.get(&thread).is_some_and(|owner| {
                    owner.0 != origin
                        || home["nativeTurn"]["userEventId"] != origin
                        || home["nativeTurn"]["attemptId"] != owner.1
                        || home["nativeTurn"]["id"] != proof["completionId"]
                        || home["agent"] != owner.3
                })
            {
                return Ok(json!({"ready":false,"reason":"scope-replaced"}));
            }
            // Admission comes from retained state, never a worker's recovery hint.
            let marker = home.get("nativeTurn");
            if marker.is_some_and(|turn| turn["state"] == "running") {
                return Ok(json!({"ready":false,"reason":"run-active"}));
            }
            if marker.is_some_and(|turn| turn.get("pauseReason").is_some()) {
                return Ok(json!({"ready":false,"reason":"retry-required"}));
            }
            let recovering = marker.is_some();
            // Valid legacy JSON permits integer counters written as e.g. 2.0.
            let previous = home["nativeTurn"]["recoveryAttempts"]
                .as_f64()
                .map(|count| count as u64)
                .unwrap_or(0);
            let count = previous + u64::from(recovering);
            if count > 3 {
                return Ok(json!({"ready":false,"reason":"recovery-exhausted"}));
            }
            let progress = crate::paging::ProgressAnchor::capture(&self.root, &thread)?;
            let mut currency = [0u8; 16];
            OsRng
                .try_fill_bytes(&mut currency)
                .map_err(|error| io::Error::other(error.to_string()))?;
            let attempt: String = currency.iter().map(|byte| format!("{byte:02x}")).collect();
            home["nativeTurn"] = json!({"id":proof["completionId"],"state":"running","userEventId":origin,"recoveryAttempts":count,"recoveryActive":recovering,"attemptId":attempt});
            let stored = crate::thread_index::request(
                &self.root,
                &json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}),
            );
            if stored["stored"] != true {
                return Ok(stored);
            }
            self.attempts.insert(
                thread.clone(),
                (
                    origin.clone(),
                    attempt.clone(),
                    progress,
                    proof["agent"].clone(),
                ),
            );
            return Ok(
                json!({"claimed":true,"threadId":thread,"eventId":origin,"attemptId":attempt,"recovering":recovering,"recoveryAttempts":count}),
            );
        }
        if request["op"] == "run_attempt_progress" {
            let activity = request["activityId"]
                .as_str()
                .filter(|id| !id.is_empty() && id.len() as u64 <= RECORD_BYTES)
                .ok_or_else(invalid)?;
            let mut check = request.clone();
            check["op"] = json!("run_attempt_current");
            check["mode"] = json!("effect");
            let proof = self.attempt_request(&check)?;
            if proof.get("error").is_some() {
                return Ok(proof);
            }
            if proof["current"] != true {
                return Ok(
                    json!({"applied":false,"reason":proof.get("reason").cloned().unwrap_or(json!("scope-replaced"))}),
                );
            }
            let anchor = &self.attempts.get(&thread).ok_or_else(invalid)?.2;
            let Some(next) = anchor.advance(&self.root, &thread, activity)? else {
                return Ok(json!({"applied":false,"reason":"no-new-progress"}));
            };
            let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
            let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            let home = index
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|row| row["id"] == thread)
                .ok_or_else(invalid)?;
            if home["nativeTurn"]["attemptId"] != request["attemptId"]
                || home["nativeTurn"]["userEventId"] != origin
                || home["agent"] != self.attempts.get(&thread).ok_or_else(invalid)?.3
                || home["nativeTurn"]["id"] != format!("native:{origin}:final")
                || request["turnId"] != format!("native:{origin}:final")
            {
                return Ok(json!({"applied":false,"reason":"scope-replaced"}));
            }
            if home["nativeTurn"]["state"] != "running" {
                return Ok(json!({"applied":false,"reason":"paused"}));
            }
            home["nativeTurn"]["recoveryAttempts"] = json!(0);
            let stored = crate::thread_index::request_native(
                &self.root,
                &json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}),
            );
            if stored["stored"] != true {
                return Ok(json!({"applied":false,"reason":"metadata-unconfirmed"}));
            }
            self.attempts.get_mut(&thread).ok_or_else(invalid)?.2 = next;
            return Ok(json!({"applied":true,"recoveryAttempts":0}));
        }
        if request["op"] == "run_attempt_session" {
            request["mode"]
                .as_str()
                .filter(|mode| ["effect", "terminal"].contains(mode))
                .ok_or_else(invalid)?;
            let mut check = request.clone();
            check["op"] = json!("run_attempt_current");
            let proof = self.attempt_request(&check)?;
            if proof["current"] != true {
                return Ok(proof);
            }
            let session = request
                .get("sessionId")
                .filter(|value| value.is_null() || value.is_string())
                .ok_or_else(invalid)?;
            let rewind = request
                .get("rewindId")
                .filter(|value| value.is_null() || value.is_string())
                .ok_or_else(invalid)?;
            let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
            let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            let home = index
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|row| row["id"] == thread)
                .ok_or_else(invalid)?;
            if home["nativeTurn"]["attemptId"] != request["attemptId"]
                || home["nativeTurn"]["userEventId"] != origin
                || home["nativeTurn"]["id"] != format!("native:{origin}:final")
                || home["agent"] != self.attempts.get(&thread).ok_or_else(invalid)?.3
            {
                return Ok(json!({"current":false}));
            }
            if home["nativeTurn"]["state"] != "running" {
                return Ok(json!({"current":false,"owned":true,"reason":"paused"}));
            }
            let row = home.as_object_mut().unwrap();
            for (field, value) in [
                ("nativeSessionId", session),
                ("nativeSessionRewindId", rewind),
            ] {
                if value.is_null() {
                    row.remove(field);
                } else {
                    row.insert(field.to_owned(), value.clone());
                }
            }
            return Ok(crate::thread_index::request_native(
                &self.root,
                &json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}),
            ));
        }
        let attempt = request["attemptId"].as_str().ok_or_else(invalid)?;
        let matches = self
            .attempts
            .get(&thread)
            .is_some_and(|owner| owner.0 == origin && owner.1 == attempt);
        if request["op"] == "run_attempt_release" {
            if matches {
                self.attempts.remove(&thread);
            }
            return Ok(json!({"released":matches}));
        }
        if request["op"] != "run_attempt_current" {
            return Err(invalid());
        }
        if !matches {
            return Ok(json!({"current":false}));
        }
        let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
        let index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let home = index
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == thread)
            .ok_or_else(invalid)?;
        let mode = request["mode"]
            .as_str()
            .filter(|mode| ["effect", "terminal", "owned"].contains(mode))
            .ok_or_else(invalid)?;
        if home["nativeTurn"]["attemptId"] != attempt
            || home["nativeTurn"]["userEventId"] != origin
            || home["nativeTurn"]["id"] != format!("native:{origin}:final")
            || home["agent"] != self.attempts.get(&thread).ok_or_else(invalid)?.3
        {
            return Ok(json!({"current":false}));
        }
        if mode == "owned" {
            return Ok(json!({"current":true,"owned":true}));
        }
        if home["nativeTurn"]["state"] != "running" {
            return Ok(json!({"current":false,"owned":true,"reason":"paused"}));
        }
        for (op, key, result) in [
            ("stop_get", "targetEventId", "record"),
            ("admission_get", "messageId", "entry"),
        ] {
            let mut query = json!({"op":op});
            query[key] = json!(origin);
            let proof = self.request(&query);
            if proof.get("error").is_some() {
                return Ok(proof);
            }
            // Only the explicit completed result may reconcile a Stop race. No new SDK effect
            // may use that exception. Expired admission never permits completion either.
            if !(proof[result].is_null() || op == "stop_get" && mode == "terminal") {
                return Ok(
                    json!({"current":false,"owned":true,"reason":if op == "stop_get" { "stopped" } else { "expired" }}),
                );
            }
        }
        Ok(json!({"current":true,"owned":true}))
    }
    fn attempt_lifecycle(
        &mut self,
        request: &Value,
        thread: &str,
        origin: &str,
    ) -> io::Result<Value> {
        let attempt = request["attemptId"]
            .as_str()
            .filter(|id| id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_hexdigit()))
            .ok_or_else(invalid)?;
        let completion = format!("native:{origin}:final");
        let bytes = crate::thread_index::current(&self.root)?.ok_or_else(invalid)?;
        let mut index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let Some(home) = index
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["id"] == thread)
        else {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        };
        let marker = home["nativeTurn"].clone();
        if request["turnId"] != completion
            || marker["id"] != completion
            || marker["userEventId"] != origin
            || marker["attemptId"] != attempt
        {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        if home["agent"]
            .as_str()
            .is_none_or(|agent| agent.is_empty() || agent == "yorozu")
        {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        if self.attempts.get(thread).is_some_and(|owner| {
            owner.0 != origin || owner.1 != attempt || owner.3 != home["agent"]
        }) {
            return Ok(json!({"applied":false,"reason":"scope-replaced"}));
        }
        // A retained scope may be conservatively paused after its Rust epoch was lost.
        // Cleanup requires durable evidence, independent of dispatch/Stop/expiry/FIFO policy.
        let proof = self.request(&json!({"op":"accepted_get","messageId":origin}));
        if proof.get("error").is_some() || proof["entry"]["threadId"] != thread {
            return Err(invalid());
        }
        let (seen, terminal, _) =
            crate::paging::run_evidence(&self.root, thread, &proof["entry"], &completion)?;
        if !seen {
            return Err(invalid());
        }
        if request["op"] == "run_attempt_pause" {
            if terminal {
                return Ok(json!({"applied":false,"terminal":true,"reason":"already-completed"}));
            }
            if let Some(reason) = request.get("pauseReason") {
                if reason != "unconfirmed" {
                    return Err(invalid());
                }
                home["nativeTurn"]["pauseReason"] = reason.clone();
            }
            home["nativeTurn"]["state"] = json!("interrupted");
        } else {
            if !terminal {
                return Ok(json!({"applied":false,"reason":"terminal-unconfirmed"}));
            }
            home.as_object_mut().unwrap().remove("nativeTurn");
        }
        let stored = crate::thread_index::request_native(
            &self.root,
            &json!({"op":"replace","expectedHash":digest(&bytes),"threads":index}),
        );
        if stored["stored"] != true {
            return Ok(json!({"applied":false,"reason":"metadata-unconfirmed"}));
        }
        Ok(json!({"applied":true,"terminal":terminal}))
    }
    pub fn request(&mut self, request: &Value) -> Value {
        // Keep each existing operational journal's own failure fence, including durable Stop
        // recording when an unrelated history projection is unavailable.
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("accepted_"))
        {
            if self.accepted.is_none() {
                match crate::accepted::Accepted::open(&self.root) {
                    Ok(store) => self.accepted = Some(store),
                    Err(_) => return json!({"error":"accepted-storage-failed"}),
                }
            }
            return self.accepted.as_mut().unwrap().request(request);
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("stop_"))
        {
            if self.stops.is_none() {
                match crate::stops::Stops::open(&self.root) {
                    Ok(store) => self.stops = Some(store),
                    Err(_) => return json!({"error":"stop-storage-failed"}),
                }
            }
            return self.stops.as_mut().unwrap().request(request);
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("admission_"))
        {
            if self.admissions.is_none() {
                match crate::admission::Admissions::open(&self.root) {
                    Ok(store) => self.admissions = Some(store),
                    Err(_) => return json!({"error":"admission-storage-failed"}),
                }
            }
            return self.admissions.as_mut().unwrap().request(request);
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("outbox_"))
        {
            if self.outbox.is_none() {
                match crate::outbox::ChannelOutbox::open(&self.root) {
                    Ok(store) => self.outbox = Some(store),
                    Err(_) => return json!({"error":"channel-storage-failed"}),
                }
            }
            return self.outbox.as_mut().unwrap().request(request);
        }
        if self.failed {
            return json!({"error":"history-storage-failed"});
        }
        if request["op"].as_str().is_some_and(|op| {
            op.starts_with("native_approval_") || op.starts_with("native_question_")
        }) {
            return self
                .native_prompt_request(request)
                .unwrap_or_else(|_| json!({"error":"native-approval-unconfirmed"}));
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("run_turn_"))
        {
            return self
                .run_turn_request(request)
                .unwrap_or_else(|_| json!({"error":"run-control-unconfirmed"}));
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("run_attempt_"))
        {
            return self
                .attempt_request(request)
                .unwrap_or_else(|_| json!({"error":"run-attempt-unconfirmed"}));
        }
        if request["op"] == "run_ready" {
            return self
                .run_ready(request)
                .unwrap_or_else(|_| json!({"error":"run-readiness-unconfirmed"}));
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("peer_"))
        {
            return crate::peers::request(request);
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("catchup_"))
        {
            return self.catchup.request(request);
        }
        if request["op"] == "thread_index_replace" {
            let mut transaction = request.clone();
            transaction["op"] = json!("replace");
            return crate::thread_index::request(&self.root, &transaction);
        }
        if request["op"] == "history_page" {
            return self.paging.request(&self.root, request);
        }
        // Compose authenticated boxes with their durable currency in one local request.
        // Fixed internal operations keep recursion bounded and retain each component's fences.
        if request["op"] == "session_seal" {
            let peer = self.request(&json!({"op":"crypto_peer","pub":request["pub"]}));
            if peer["valid"] != true {
                return peer;
            }
            let currency = self.request(&json!({"op":"seq_next","pub":request["pub"]}));
            if currency.get("error").is_some() {
                return currency;
            }
            return self.request(&json!({"op":"crypto_seal","pub":request["pub"],"mode":"current","seq":currency["seq"],"event":request["event"]}));
        }
        if request["op"] == "session_open_box" {
            let opened = self.request(&json!({"op":"crypto_open_box","pub":request["pub"],"mode":"current","nonce":request["nonce"],"ciphertext":request["ciphertext"]}));
            if opened["status"] != "opened" {
                return opened;
            }
            let currency =
                self.request(&json!({"op":"seq_accept","pub":request["pub"],"seq":opened["seq"]}));
            if currency.get("error").is_some() {
                return currency;
            }
            return if currency["accepted"] == true {
                opened
            } else {
                json!({"status":"replayed"})
            };
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("seq_"))
        {
            if self.sequences.is_none() {
                match crate::sequences::Sequences::open(&self.root) {
                    Ok(sequences) => self.sequences = Some(sequences),
                    Err(_) => {
                        return if request["op"] == "seq_open" {
                            json!({"unavailable":true})
                        } else {
                            json!({"error":"sequence-storage-failed"})
                        };
                    }
                }
            }
            return self.sequences.as_mut().unwrap().request(request);
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("crypto_"))
        {
            if self.crypto.is_none() {
                match crate::crypto::HostCrypto::open(&self.root) {
                    Ok(crypto) => self.crypto = Some(crypto),
                    Err(_) => {
                        return if request["op"] == "crypto_open" {
                            json!({"unavailable":true})
                        } else {
                            json!({"error":"crypto-storage-failed"})
                        };
                    }
                }
            }
            return self.crypto.as_mut().unwrap().request(request);
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("queue_"))
        {
            return self.queue_request(request);
        }
        if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("steering_"))
        {
            return self.steering_request(request).unwrap_or_else(|_| {
                self.failed = true;
                json!({"error":"steering-storage-failed"})
            });
        }
        let result = match request["op"].as_str() {
            Some("history_open") => Ok(json!({"stored":true})),
            Some("history_append")
                if request["operationId"].as_str().is_some_and(|id| {
                    id.starts_with("native-approval-")
                        || id.starts_with("native-question-")
                        || id.starts_with("worker-result:")
                        || id.starts_with("worker-policy:")
                        || id.starts_with("worker-stream:")
                        || id.starts_with("worker-launch:")
                }) =>
            {
                Ok(json!({"error":"reserved-history-operation"}))
            }
            Some("history_append") => self.append(request),
            _ => return json!({"error":"invalid-history-request"}),
        };
        result.unwrap_or_else(|_| {
            self.failed = true;
            json!({"error":"history-storage-failed"})
        })
    }
}
