//! Durable, monotonic connection counters with a recoverable legacy projection.
use crate::{
    TEMP_ID, digest, history::publish, invalid_id, private_dir, private_open, read_private,
    sync_dir,
};
use serde_json::{Value, json};
use std::{
    fs,
    fs::File,
    io::{self, Write},
    path::{Path, PathBuf},
    sync::atomic::Ordering,
};
const PROJECTION_BYTES: u64 = 1024 * 1024;
const STATE_BYTES: u64 = 8 * 1024 * 1024;
const BACKUP_FILES: usize = 128;
const BACKUP_BYTES: u64 = 128 * 1024 * 1024;
const MAX_SEQ: u64 = 9_007_199_254_740_991;
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn count(value: &Value) -> Option<u64> {
    value
        .as_f64()
        .filter(|number| {
            number.is_finite()
                && number.fract() == 0.0
                && *number >= 0.0
                && *number <= MAX_SEQ as f64
        })
        .map(|number| number as u64)
}
fn valid(records: &Value) -> bool {
    records.as_object().is_some_and(|records| {
        records.len() <= 65_536
            && records.iter().all(|(pubkey, record)| {
                !invalid_id(pubkey)
                    && record.is_object()
                    && count(&record["sendSeq"]).is_some()
                    && count(&record["recvSeq"]).is_some()
            })
    })
}
fn read(path: &Path, limit: u64) -> io::Result<Option<Vec<u8>>> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        meta => {
            let meta = meta?;
            if !meta.is_file() || meta.file_type().is_symlink() {
                return Err(invalid());
            }
            Ok(Some(read_private(path, limit)?))
        }
    }
}
fn hash(bytes: &Option<Vec<u8>>) -> Value {
    bytes
        .as_ref()
        .map_or(Value::Null, |bytes| json!(digest(bytes)))
}
fn parse(bytes: &[u8]) -> io::Result<Value> {
    let records: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    if !valid(&records) {
        return Err(invalid());
    }
    Ok(records)
}
fn backup(root: &Path, name: &str, bytes: &[u8]) -> io::Result<()> {
    let path = root.join(format!(
        ".rust-channel-seq-{name}-original.{}.json",
        digest(bytes)
    ));
    match read(&path, PROJECTION_BYTES)? {
        Some(old) => {
            if old != bytes {
                return Err(invalid());
            }
        }
        None => {
            let mut files = 0;
            let mut total = bytes.len() as u64;
            for item in fs::read_dir(root)? {
                let item = item?;
                let name = item.file_name();
                let name = name.to_string_lossy();
                if !name.starts_with(".rust-channel-seq-projection-original.")
                    && !name.starts_with(".rust-channel-seq-devices-original.")
                {
                    continue;
                }
                let old = read(&item.path(), PROJECTION_BYTES)?.ok_or_else(invalid)?;
                files += 1;
                total += old.len() as u64;
                if files >= BACKUP_FILES || total > BACKUP_BYTES {
                    return Err(invalid());
                }
            }
            publish(&path, bytes)?;
        }
    }
    Ok(())
}
pub struct Sequences {
    root: PathBuf,
    owner: File,
    state: Value,
    canonical: Option<Vec<u8>>,
    raw: Option<Vec<u8>>,
    failed: bool,
}
impl Drop for Sequences {
    fn drop(&mut self) {
        let _ = self.owner.unlock();
    }
}
impl Sequences {
    pub fn open(root: &Path) -> io::Result<Self> {
        private_dir(root)?;
        let owner = private_open(&root.join(".rust-channel-seq-owner.lock"), false)?;
        owner.try_lock().map_err(io::Error::other)?;
        let raw = read(&root.join("channel-seq.json"), PROJECTION_BYTES)?;
        let canonical = read(&root.join(".rust-channel-seq-state.json"), STATE_BYTES)?;
        let mut store = Self {
            root: root.into(),
            owner,
            state: Value::Null,
            canonical,
            raw: raw.clone(),
            failed: false,
        };
        if let Some(bytes) = &store.canonical {
            let envelope: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
            let state = &envelope["state"];
            if envelope["checksum"] != digest(&serde_json::to_vec(state).map_err(io::Error::other)?)
                || state["version"] != 1
                || !valid(&state["records"])
            {
                return Err(invalid());
            }
            let expected = match &state["raw"] {
                Value::Null => None,
                Value::String(raw) => {
                    if raw.len() as u64 > PROJECTION_BYTES
                        || parse(raw.as_bytes())? != state["records"]
                    {
                        return Err(invalid());
                    }
                    Some(raw.as_bytes().to_vec())
                }
                _ => return Err(invalid()),
            };
            store.state = state.clone();
            if raw == expected {
                return Ok(store);
            }
            if raw.is_none() || hash(&raw) == store.state["previousHash"] {
                if let Some(expected) = expected {
                    store.projection(&expected)?;
                    store.raw = Some(expected);
                    return Ok(store);
                }
                return Err(invalid());
            }
            // A stopped older build may have advanced its compatible projection. Merge only
            // forward progress and retain omitted peers and unknown fields; never lower currency.
            let incoming = parse(raw.as_ref().unwrap())?;
            let mut merged = store.state["records"].clone();
            merge(&mut merged, &incoming)?;
            backup(root, "projection", raw.as_ref().unwrap())?;
            store.save(merged)?;
            return Ok(store);
        }
        let records = if let Some(raw) = &raw {
            let records = parse(raw)?;
            backup(root, "projection", raw)?;
            records
        } else {
            let mut records = json!({});
            if let Some(bytes) = read(&root.join("devices.json"), PROJECTION_BYTES)? {
                let devices: Value = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
                let devices = devices.as_array().ok_or_else(invalid)?;
                if devices.len() > 65_536 {
                    return Err(invalid());
                }
                for device in devices {
                    let pubkey = device
                        .as_str()
                        .or_else(|| device["pub"].as_str())
                        .filter(|pubkey| !invalid_id(pubkey))
                        .ok_or_else(invalid)?;
                    let send = match device.get("sendSeq") {
                        Some(value) => count(value).ok_or_else(invalid)?,
                        None => 0,
                    };
                    let recv = match device.get("recvSeq") {
                        Some(value) => count(value).ok_or_else(invalid)?,
                        None => 0,
                    };
                    let old = &records[pubkey];
                    records[pubkey] = json!({"sendSeq":send.max(count(&old["sendSeq"]).unwrap_or(0)),"recvSeq":recv.max(count(&old["recvSeq"]).unwrap_or(0))});
                }
                backup(root, "devices", &bytes)?;
            }
            records
        };
        store.state = json!({"version":1,"records":records,"raw":raw.as_ref().map(|raw|String::from_utf8(raw.clone())).transpose().map_err(|_|invalid())?,"previousHash":hash(&raw)});
        store.write_canonical()?;
        Ok(store)
    }
    fn check_canonical(&self) -> io::Result<()> {
        if read(&self.root.join(".rust-channel-seq-state.json"), STATE_BYTES)? != self.canonical {
            return Err(invalid());
        }
        Ok(())
    }
    fn temporary(&self, bytes: &[u8]) -> io::Result<PathBuf> {
        let mut pending = 0;
        for item in fs::read_dir(&self.root)? {
            let item = item?;
            if !item
                .file_name()
                .to_string_lossy()
                .starts_with(".rust-channel-seq-pending.")
            {
                continue;
            }
            let meta = fs::symlink_metadata(item.path())?;
            if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > STATE_BYTES {
                return Err(invalid());
            }
            pending += 1;
        }
        if pending >= 128 {
            return Err(invalid());
        }
        let path = self.root.join(format!(
            ".rust-channel-seq-pending.{}.{}",
            std::process::id(),
            TEMP_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = private_open(&path, true)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        Ok(path)
    }
    fn write_canonical(&mut self) -> io::Result<()> {
        self.check_canonical()?;
        let bytes=serde_json::to_vec(&json!({"state":self.state,"checksum":digest(&serde_json::to_vec(&self.state).map_err(io::Error::other)?)})).map_err(io::Error::other)?;
        if bytes.len() as u64 > STATE_BYTES {
            return Err(invalid());
        }
        let pending = self.temporary(&bytes)?;
        self.check_canonical()?;
        let path = self.root.join(".rust-channel-seq-state.json");
        if self.canonical.is_none() {
            fs::hard_link(&pending, &path)?;
            let _ = fs::remove_file(pending);
        } else {
            fs::rename(pending, &path)?;
        }
        sync_dir(&self.root)?;
        if read(&path, STATE_BYTES)?.as_deref() != Some(bytes.as_slice()) {
            return Err(invalid());
        }
        self.canonical = Some(bytes);
        Ok(())
    }
    fn projection(&self, bytes: &[u8]) -> io::Result<()> {
        self.check_canonical()?;
        let path = self.root.join("channel-seq.json");
        if read(&path, PROJECTION_BYTES)? != self.raw {
            return Err(invalid());
        }
        let pending = self.temporary(bytes)?;
        if read(&path, PROJECTION_BYTES)? != self.raw {
            return Err(invalid());
        }
        if self.raw.is_none() {
            fs::hard_link(&pending, &path)?;
            let _ = fs::remove_file(pending);
        } else {
            fs::rename(pending, &path)?;
        }
        sync_dir(&self.root)?;
        if read(&path, PROJECTION_BYTES)?.as_deref() != Some(bytes) {
            return Err(invalid());
        }
        Ok(())
    }
    fn save(&mut self, records: Value) -> io::Result<Value> {
        self.check_canonical()?;
        let actual = read(&self.root.join("channel-seq.json"), PROJECTION_BYTES)?;
        if actual != self.raw {
            return Err(invalid());
        }
        let mut bytes = serde_json::to_vec(&records).map_err(io::Error::other)?;
        bytes.push(b'\n');
        if bytes.len() as u64 > PROJECTION_BYTES {
            return Err(invalid());
        }
        self.state["previousHash"] = hash(&self.raw);
        self.state["records"] = records;
        self.state["raw"] = json!(String::from_utf8(bytes.clone()).map_err(|_| invalid())?);
        self.write_canonical()?;
        self.projection(&bytes)?;
        self.raw = Some(bytes);
        Ok(json!({"stored":true,"hasProjection":true}))
    }
    fn request_inner(&mut self, request: &Value) -> io::Result<Value> {
        self.check_canonical()?;
        let actual = match read(&self.root.join("channel-seq.json"), PROJECTION_BYTES) {
            Ok(actual) => actual,
            Err(_) => return Ok(json!({"error":"sequence-projection-unavailable"})),
        };
        if actual.is_none() && self.raw.is_some() {
            self.raw = None;
            let bytes = self.state["raw"]
                .as_str()
                .ok_or_else(invalid)?
                .as_bytes()
                .to_vec();
            self.projection(&bytes)?;
            self.raw = Some(bytes);
        } else if actual != self.raw {
            return Err(invalid());
        }
        match request["op"].as_str() {
            Some("seq_open") => Ok(json!({"stored":true,"hasProjection":self.raw.is_some()})),
            Some("seq_get") => {
                let pubkey = request["pub"]
                    .as_str()
                    .filter(|pubkey| !invalid_id(pubkey))
                    .ok_or_else(invalid)?;
                let record = &self.state["records"][pubkey];
                Ok(
                    json!({"sendSeq":count(&record["sendSeq"]).unwrap_or(0),"recvSeq":count(&record["recvSeq"]).unwrap_or(0)}),
                )
            }
            Some("seq_save") => {
                let input = &request["records"];
                if !valid(input) || input.as_object().unwrap().len() > 16 {
                    return Ok(json!({"error":"invalid-sequence-records"}));
                }
                let mut records = self.state["records"].clone();
                if merge(&mut records, input).is_err() {
                    return Ok(json!({"error":"conflicting-sequence-currency"}));
                }
                if records == self.state["records"] && self.raw.is_some() {
                    return Ok(json!({"stored":true,"hasProjection":true}));
                }
                self.save(records)
            }
            _ => Ok(json!({"error":"invalid-sequence-request"})),
        }
    }
    pub fn request(&mut self, request: &Value) -> Value {
        if self.failed {
            return json!({"error":"sequence-storage-failed"});
        }
        self.request_inner(request).unwrap_or_else(|_| {
            self.failed = true;
            json!({"error":"sequence-storage-failed"})
        })
    }
}
fn merge(records: &mut Value, incoming: &Value) -> io::Result<()> {
    for (pubkey, next) in incoming.as_object().ok_or_else(invalid)? {
        let prior = &records[pubkey];
        for key in ["sendSeq", "recvSeq"] {
            if count(&next[key]).ok_or_else(invalid)? < count(&prior[key]).unwrap_or(0) {
                return Err(invalid());
            }
        }
        let mut record = if prior.is_object() {
            prior.clone()
        } else {
            json!({})
        };
        for (key, value) in next.as_object().ok_or_else(invalid)? {
            record[key] = value.clone();
        }
        records[pubkey] = record;
    }
    if !valid(records) {
        return Err(invalid());
    }
    Ok(())
}
