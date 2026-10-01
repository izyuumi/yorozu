//! Immutable accepted user messages. Thread-history projections and execution remain separate.
use crate::{
    SAFE_INTEGER, TEMP_ID, digest, invalid_id, private_dir, private_open, sync_dir, valid_hash,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
const RECORD_BYTES: u64 = 32 * 1024 * 1024;
const STORE_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const RECORDS: usize = 65_536;
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn number(value: &Value) -> Option<Value> {
    let n = value.as_f64().filter(|n| n.is_finite())?;
    if n.fract() == 0.0 && n.abs() <= SAFE_INTEGER as f64 {
        Some(json!(n as i64))
    } else {
        Some(json!(n))
    }
}
/// Bind the client-owned content independently of the compatibility host's wire fingerprint.
pub(crate) fn fingerprint(entry: &Value, event: &Value) -> Option<String> {
    let data = &event["data"];
    if !entry.is_object()
        || !event.is_object()
        || !data.is_object()
        || !["id", "threadId"].iter().all(|key| {
            entry[*key].as_str().is_some_and(|id| !invalid_id(id)) && entry[*key] == event[*key]
        })
        || !entry["identity"].as_str().is_some_and(valid_hash)
        || !["conversation", "approval-reply", "legacy"].contains(&entry["purpose"].as_str()?)
        || entry
            .get("approvalActionId")
            .is_some_and(|id| id.as_str().is_none_or(invalid_id))
        || event["kind"] != "message"
        || data["role"] != "user"
        || !data["text"].is_string()
        || !event["agentId"].is_string()
        || number(&event["ts"]).is_none()
    {
        return None;
    }
    let time = number(event.get("clientTs").unwrap_or(&event["ts"]))?;
    let deadline = match data.get("admissionDeadline") {
        None | Some(Value::Null) => Value::Null,
        Some(value) => number(value)?,
    };
    let mut attachments = Vec::new();
    if let Some(files) = data.get("attachments") {
        for file in files.as_array()? {
            if !["name", "mime", "data"]
                .iter()
                .all(|key| file[*key].is_string())
            {
                return None;
            }
            attachments.push(json!([file["name"], file["mime"], file["data"]]));
        }
    }
    let mut content = vec![
        entry["threadId"].clone(),
        time,
        json!("user"),
        data["text"].clone(),
        deadline,
        json!(attachments),
    ];
    if let Some(model) = data.get("channelModel") {
        if !model.is_object()
            || model
                .get("model")
                .is_some_and(|value| !value.is_null() && !value.is_string())
        {
            return None;
        }
        content.push(model.get("model").cloned().unwrap_or(Value::Null));
    }
    if let Some(parent) = data.get("replyTo") {
        if !parent.is_string() {
            return None;
        }
        content.extend([json!("replyTo"), parent.clone()]);
    }
    Some(digest(&serde_json::to_vec(&content).ok()?))
}
#[derive(Clone)]
struct Metadata {
    summary: Value,
    fingerprint: String,
    record_hash: String,
    bytes: u64,
}
fn metadata(entry: &Value, bytes: u64, record_hash: String) -> Option<Metadata> {
    Some(Metadata {
        fingerprint: fingerprint(entry, &entry["event"])?,
        record_hash,
        bytes,
        summary: json!({"id":entry["id"],"threadId":entry["threadId"],"identity":entry["identity"],"purpose":entry["purpose"]}),
    })
}
fn read(path: &Path) -> io::Result<(Value, u64, String)> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > RECORD_BYTES {
        return Err(invalid());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() || file.metadata()?.len() > RECORD_BYTES {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    file.take(RECORD_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > RECORD_BYTES {
        return Err(invalid());
    }
    let mut envelope: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    let checksum = envelope["checksum"]
        .as_str()
        .ok_or_else(invalid)?
        .to_owned();
    let entry = envelope.get_mut("entry").ok_or_else(invalid)?.take();
    if checksum != digest(&serde_json::to_vec(&entry).map_err(io::Error::other)?) {
        return Err(invalid());
    }
    Ok((entry, bytes.len() as u64, checksum))
}
pub struct Accepted {
    root: PathBuf,
    entries: BTreeMap<String, Metadata>,
    bytes: u64,
    owner: File,
    failed: bool,
}
impl Drop for Accepted {
    fn drop(&mut self) {
        let _ = self.owner.unlock();
    }
}
impl Accepted {
    pub fn open(state: &Path) -> io::Result<Self> {
        private_dir(state)?;
        let owner = private_open(&state.join(".rust-accepted-owner.lock"), false)?;
        owner.try_lock().map_err(io::Error::other)?;
        let root = state.join("accepted-messages");
        private_dir(&root)?;
        let mut entries = BTreeMap::new();
        let mut total = 0u64;
        let mut pending = 0;
        for item in fs::read_dir(&root)? {
            let item = item?;
            let name = item.file_name().into_string().map_err(|_| invalid())?;
            let meta = fs::symlink_metadata(item.path())?;
            if !meta.is_file() || meta.file_type().is_symlink() {
                return Err(invalid());
            }
            total = total.checked_add(meta.len()).ok_or_else(invalid)?;
            if total > STORE_BYTES {
                return Err(invalid());
            }
            if name.starts_with(".accepted-") && name.ends_with(".tmp") {
                pending += 1;
                if pending > 128 || meta.len() > RECORD_BYTES {
                    return Err(invalid());
                }
                continue;
            }
            let hash = name
                .strip_suffix(".json")
                .filter(|hash| valid_hash(hash))
                .ok_or_else(invalid)?;
            let (entry, bytes, checksum) = read(&item.path())?;
            let info = metadata(&entry, bytes, checksum).ok_or_else(invalid)?;
            let id = entry["id"].as_str().unwrap();
            if digest(id.as_bytes()) != hash
                || entries.len() >= RECORDS
                || entries.insert(id.to_owned(), info).is_some()
            {
                return Err(invalid());
            }
        }
        Ok(Self {
            root,
            entries,
            bytes: total,
            owner,
            failed: false,
        })
    }
    fn path(&self, id: &str) -> PathBuf {
        self.root.join(format!("{}.json", digest(id.as_bytes())))
    }
    fn get(&self, id: &str) -> io::Result<Option<Value>> {
        let Some(prior) = self.entries.get(id) else {
            return Ok(None);
        };
        let (entry, bytes, checksum) = read(&self.path(id))?;
        if checksum != prior.record_hash || bytes != prior.bytes {
            return Err(invalid());
        }
        Ok(Some(entry))
    }
    fn accept_inner(&mut self, entry: &Value) -> io::Result<Value> {
        let fingerprint = fingerprint(entry, &entry["event"]).ok_or_else(invalid)?;
        let id = entry["id"].as_str().unwrap();
        if let Some(prior) = self.entries.get(id) {
            if fingerprint != prior.fingerprint || entry["identity"] != prior.summary["identity"] {
                return Ok(json!({"status":"rejected","reason":"conflicting-message-id"}));
            }
            return Ok(json!({"status":"accepted","entry":self.get(id)?.ok_or_else(invalid)?}));
        }
        let checksum = digest(&serde_json::to_vec(entry).map_err(io::Error::other)?);
        let envelope = json!({"entry":entry,"checksum":checksum});
        let mut encoded = serde_json::to_vec(&envelope).map_err(io::Error::other)?;
        encoded.push(b'\n');
        let info = Metadata {
            fingerprint,
            record_hash: checksum.clone(),
            bytes: encoded.len() as u64,
            summary: json!({"id":entry["id"],"threadId":entry["threadId"],"identity":entry["identity"],"purpose":entry["purpose"]}),
        };
        if info.bytes > RECORD_BYTES
            || self.entries.len() >= RECORDS
            || self.bytes + info.bytes > STORE_BYTES
        {
            return Err(invalid());
        }
        let path = self.path(id);
        if fs::symlink_metadata(&path).is_ok() {
            return Err(invalid());
        }
        let temporary = self.root.join(format!(
            ".accepted-{}-{}.tmp",
            std::process::id(),
            TEMP_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = private_open(&temporary, true)?;
        file.write_all(&encoded)?;
        file.sync_all()?;
        // Publish without replacing any path planted by another writer. Interrupted private
        // temporary files remain recoverable; only the final immutable name is accepted work.
        fs::hard_link(&temporary, &path)?;
        sync_dir(&self.root)?;
        sync_dir(self.root.parent().ok_or_else(invalid)?)?;
        let (committed, bytes, committed_hash) = read(&path)?;
        if committed != *entry || committed_hash != checksum || bytes != info.bytes {
            return Err(invalid());
        }
        let _ = fs::remove_file(&temporary);
        self.bytes += info.bytes;
        self.entries.insert(id.to_owned(), info);
        Ok(json!({"status":"accepted","entry":entry}))
    }
    pub fn request(&mut self, request: &Value) -> Value {
        if self.failed {
            return json!({"error":"accepted-storage-failed"});
        }
        let result = match request["op"].as_str() {
            Some("accepted_accept") => self.accept_inner(&request["entry"]),
            Some("accepted_get") => self
                .get(request["messageId"].as_str().unwrap_or(""))
                .map(|entry| json!({"entry":entry})),
            Some("accepted_snapshot") => {
                let after = request.get("after").and_then(Value::as_str);
                let mut entries: Vec<_> = self
                    .entries
                    .iter()
                    .filter(|(id, _)| after.is_none_or(|after| id.as_str() > after))
                    .take(257)
                    .map(|(_, entry)| entry.summary.clone())
                    .collect();
                let more = entries.len() > 256;
                entries.truncate(256);
                let next = if more {
                    entries.last().map(|entry| entry["id"].clone())
                } else {
                    None
                };
                Ok(json!({"entries":entries,"next":next}))
            }
            _ => Ok(json!({"error":"invalid-accepted-request"})),
        };
        result.unwrap_or_else(|_| {
            self.failed = true;
            json!({"error":"accepted-storage-failed"})
        })
    }
}
