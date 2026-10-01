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
    pub fn request(&mut self, request: &Value) -> Value {
        if self.failed {
            return json!({"error":"history-storage-failed"});
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
            Some("history_append") => self.append(request),
            _ => return json!({"error":"invalid-history-request"}),
        };
        result.unwrap_or_else(|_| {
            self.failed = true;
            json!({"error":"history-storage-failed"})
        })
    }
}
