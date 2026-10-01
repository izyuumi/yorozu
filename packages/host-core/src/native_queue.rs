//! Native queue metadata. Message bodies remain in accepted/history stores.
use crate::{
    TEMP_ID, digest, history::publish, invalid_id, private_dir, private_open, read_private,
    sync_dir,
};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
const BYTES: u64 = 16 * 1024 * 1024;
const RECOVERY_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const RECORDS: usize = 65_536;
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn id<'a>(value: &'a Value, key: &str) -> io::Result<&'a str> {
    value[key]
        .as_str()
        .filter(|id| !invalid_id(id))
        .ok_or_else(invalid)
}
fn load(root: &Path) -> io::Result<Option<Vec<u8>>> {
    let path = root.join("native-turn-queue.json");
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        meta => {
            let meta = meta?;
            if !meta.is_file() || meta.file_type().is_symlink() {
                return Err(invalid());
            }
            Ok(Some(read_private(&path, BYTES)?))
        }
    }
}
fn blocked(root: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(root.join("native-turn-queue.json.tmp")) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        meta => {
            meta?;
            Ok(true)
        }
    }
}
fn snapshot(root: &Path, bytes: &[u8]) -> io::Result<()> {
    let directory = root.join(".rust-native-queue-recovery");
    private_dir(&directory)?;
    let path = directory.join(format!("{}.json", digest(bytes)));
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        _ => {
            if read_private(&path, BYTES)? != bytes {
                return Err(invalid());
            }
            return Ok(());
        }
    }
    let mut count = 0;
    let mut total = 0u64;
    for item in fs::read_dir(&directory)? {
        let item = item?;
        let meta = fs::symlink_metadata(item.path())?;
        if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > BYTES {
            return Err(invalid());
        }
        count += 1;
        total = total.checked_add(meta.len()).ok_or_else(invalid)?;
    }
    if count >= RECORDS || total + bytes.len() as u64 > RECOVERY_BYTES {
        return Err(invalid());
    }
    publish(&path, bytes)?;
    sync_dir(root)
}
pub struct NativeQueue {
    root: PathBuf,
    entries: Vec<Value>,
    raw: Option<Vec<u8>>,
    owner: File,
    failed: bool,
}
impl Drop for NativeQueue {
    fn drop(&mut self) {
        let _ = self.owner.unlock();
    }
}
impl NativeQueue {
    pub fn open(root: &Path) -> io::Result<Self> {
        private_dir(root)?;
        let owner = private_open(&root.join(".rust-native-queue-owner.lock"), false)?;
        owner.try_lock().map_err(io::Error::other)?;
        if blocked(root)? {
            return Err(invalid());
        }
        let raw = load(root)?;
        let entries: Vec<Value> = raw
            .as_ref()
            .map(|bytes| serde_json::from_slice(bytes))
            .transpose()
            .map_err(io::Error::other)?
            .unwrap_or_default();
        let mut ids = HashSet::new();
        if entries.len() > RECORDS
            || !entries.iter().all(|entry| {
                entry.is_object()
                    && id(entry, "threadId").is_ok()
                    && id(entry, "eventId").is_ok_and(|id| ids.insert(id))
            })
        {
            return Err(invalid());
        }
        Ok(Self {
            root: root.into(),
            entries,
            raw,
            owner,
            failed: false,
        })
    }
    fn proof(&self) -> Value {
        json!({"stored":true,"hash":self.raw.as_ref().map(|bytes| digest(bytes))})
    }
    fn check(&self) -> io::Result<()> {
        if load(&self.root)? != self.raw {
            return Err(invalid());
        }
        Ok(())
    }
    fn save(&mut self, entries: Vec<Value>) -> io::Result<Value> {
        self.check()?;
        if entries.len() > RECORDS {
            return Err(invalid());
        }
        let mut bytes = serde_json::to_vec(&entries).map_err(io::Error::other)?;
        bytes.push(b'\n');
        if bytes.len() as u64 > BYTES {
            return Err(invalid());
        }
        let mut count = 0;
        for item in fs::read_dir(&self.root)? {
            let item = item?;
            if !item
                .file_name()
                .to_string_lossy()
                .starts_with(".native-queue-pending.")
            {
                continue;
            }
            let meta = fs::symlink_metadata(item.path())?;
            if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > BYTES {
                return Err(invalid());
            }
            count += 1;
        }
        if count >= 128 {
            return Err(invalid());
        }
        if let Some(raw) = &self.raw {
            snapshot(&self.root, raw)?;
        }
        let temporary = self.root.join(format!(
            ".native-queue-pending.{}.{}.json",
            std::process::id(),
            TEMP_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = private_open(&temporary, true)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        self.check()?;
        let path = self.root.join("native-turn-queue.json");
        if self.raw.is_none() {
            fs::hard_link(&temporary, &path)?;
            let _ = fs::remove_file(temporary);
        } else {
            fs::rename(&temporary, &path)?;
        }
        sync_dir(&self.root)?;
        if load(&self.root)?.as_deref() != Some(bytes.as_slice()) {
            return Err(invalid());
        }
        self.entries = entries;
        self.raw = Some(bytes);
        Ok(self.proof())
    }
    fn mutate(&mut self, request: &Value) -> io::Result<Value> {
        self.check()?;
        if blocked(&self.root)? {
            return Ok(json!({"error":"queue-recovery-required"}));
        }
        if request["op"] == "queue_open" || request["op"] == "queue_ready" {
            if let Some(expected) = request.get("expectedHash")
                && expected != &self.proof()["hash"]
            {
                return Ok(json!({"error":"conflicting-native-queue"}));
            }
            return Ok(self.proof());
        }
        if request["op"] == "queue_head" {
            let thread = id(request, "threadId")?;
            let head = self
                .entries
                .iter()
                .find(|entry| entry["threadId"] == thread);
            return Ok(json!({"stored":true,"eventId":head.map(|entry| &entry["eventId"])}));
        }
        let event = id(request, "eventId")?;
        let thread = id(request, "threadId")?;
        let existing = self
            .entries
            .iter()
            .position(|entry| entry["eventId"] == event);
        if existing.is_some_and(|index| self.entries[index]["threadId"] != thread) {
            return Ok(json!({"error":"conflicting-queue-owner"}));
        }
        let mut next = self.entries.clone();
        match request["op"].as_str() {
            Some("queue_enqueue") => {
                if existing.is_some() {
                    return Ok(self.proof());
                }
                next.push(json!({"eventId":event,"threadId":thread}));
            }
            Some("queue_remove") => {
                let Some(index) = existing else {
                    return Ok(self.proof());
                };
                next.remove(index);
            }
            _ => return Err(invalid()),
        }
        self.save(next)
    }
    pub fn request(&mut self, request: &Value) -> Value {
        if self.failed {
            return json!({"error":"native-queue-storage-failed"});
        }
        self.mutate(request).unwrap_or_else(|_| {
            self.failed = true;
            json!({"error":"native-queue-storage-failed"})
        })
    }
}
