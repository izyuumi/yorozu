//! Irreversible expired-operation identities. Accepted history remains a later boundary.
use crate::{SAFE_INTEGER, TEMP_ID, invalid_id, private_dir, private_open, sync_dir, valid_hash};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
const JOURNAL_BYTES: u64 = 64 * 1024 * 1024;
const RECORD_BYTES: usize = 1024 * 1024;
const RECORDS: usize = 65_536;
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn safe_integer(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .filter(|n| n.unsigned_abs() <= SAFE_INTEGER)
        .or_else(|| {
            value
                .as_f64()
                .filter(|n| n.is_finite() && n.fract() == 0.0 && n.abs() <= SAFE_INTEGER as f64)
                .map(|n| n as i64)
        })
}
fn valid(entry: &Value) -> bool {
    entry.is_object()
        && ["id", "threadId"]
            .iter()
            .all(|key| entry[*key].as_str().is_some_and(|s| !invalid_id(s)))
        && entry["identity"].as_str().is_some_and(valid_hash)
        && safe_integer(&entry["deadline"]).is_some()
}
fn same(a: &Value, b: &Value) -> bool {
    ["id", "threadId", "identity"]
        .iter()
        .all(|key| a[*key] == b[*key])
        && safe_integer(&a["deadline"]) == safe_integer(&b["deadline"])
}
pub struct Admissions {
    root: PathBuf,
    entries: HashMap<String, Value>,
    length: u64,
    complete: u64,
    owner: File,
}
impl Drop for Admissions {
    fn drop(&mut self) {
        let _ = self.owner.unlock();
    }
}
impl Admissions {
    pub fn open(root: &Path) -> io::Result<Self> {
        private_dir(root)?;
        let owner = private_open(&root.join(".rust-admission-owner.lock"), false)?;
        owner.try_lock().map_err(io::Error::other)?;
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW);
        }
        let mut entries = HashMap::new();
        let mut complete = 0;
        let mut length = 0;
        match options.open(root.join("expired-admissions.jsonl")) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            file => {
                let file = file?;
                let meta = file.metadata()?;
                length = meta.len();
                if !meta.is_file() || length > JOURNAL_BYTES {
                    return Err(invalid());
                }
                let mut reader = BufReader::new(file);
                loop {
                    let mut bytes = Vec::new();
                    if reader.read_until(b'\n', &mut bytes)? == 0 {
                        break;
                    }
                    if bytes.len() > RECORD_BYTES {
                        return Err(invalid());
                    }
                    if !bytes.ends_with(b"\n") {
                        break;
                    }
                    let entry: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
                    if !valid(&entry) || entries.len() >= RECORDS {
                        return Err(invalid());
                    }
                    let id = entry["id"].as_str().unwrap().to_owned();
                    if entries.insert(id, entry).is_some() {
                        return Err(invalid());
                    }
                    complete += bytes.len() as u64;
                }
            }
        }
        Ok(Self {
            root: root.into(),
            entries,
            length,
            complete,
            owner,
        })
    }
    fn expire(&mut self, entry: &Value, now: i64) -> io::Result<Value> {
        if !valid(entry) || now.unsigned_abs() > SAFE_INTEGER {
            return Err(invalid());
        }
        let id = entry["id"].as_str().unwrap();
        if let Some(prior) = self.entries.get(id) {
            return Ok(if same(prior, entry) {
                json!({"status":"expired"})
            } else {
                json!({"status":"rejected","reason":"conflicting-message-id"})
            });
        }
        if now < safe_integer(&entry["deadline"]).unwrap() {
            return Ok(json!({"error":"admission-not-expired"}));
        }
        let mut bytes = serde_json::to_vec(entry).map_err(io::Error::other)?;
        bytes.push(b'\n');
        if bytes.len() > RECORD_BYTES
            || self.entries.len() >= RECORDS
            || self.complete + bytes.len() as u64 > JOURNAL_BYTES
        {
            return Err(invalid());
        }
        let mut file = private_open(&self.root.join("expired-admissions.jsonl"), false)?;
        // A writer that ignores the owner lock must not silently change our admission currency.
        if !file.metadata()?.is_file() || file.metadata()?.len() != self.length {
            return Err(invalid());
        }
        if self.length != self.complete {
            // Retain the entire original before removing its never-acknowledged partial append.
            let backup = self.root.join(format!(
                ".expired-admissions-recovery.{}.{}.jsonl",
                std::process::id(),
                TEMP_ID.fetch_add(1, Ordering::Relaxed)
            ));
            let mut recovery = private_open(&backup, true)?;
            file.seek(SeekFrom::Start(0))?;
            io::copy(&mut file, &mut recovery)?;
            recovery.sync_all()?;
            sync_dir(&self.root)?;
            file.set_len(self.complete)?;
            file.sync_all()?;
            self.length = self.complete;
        }
        file.seek(SeekFrom::End(0))?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        sync_dir(&self.root)?;
        self.length += bytes.len() as u64;
        self.complete = self.length;
        self.entries.insert(id.into(), entry.clone());
        Ok(json!({"status":"expired"}))
    }
    pub fn request(&mut self, request: &Value) -> Value {
        match request["op"].as_str() {
            Some("admission_expire") => request["now"]
                .as_i64()
                .ok_or_else(invalid)
                .and_then(|now| self.expire(&request["entry"], now))
                .unwrap_or_else(|_| json!({"error":"admission-storage-failed"})),
            Some("admission_get") => self
                .entries
                .get(request["messageId"].as_str().unwrap_or(""))
                .map_or_else(|| json!({"entry":null}), |entry| json!({"entry":entry})),
            _ => json!({"error":"invalid-admission-request"}),
        }
    }
}
