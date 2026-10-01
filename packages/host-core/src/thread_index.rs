//! Compare-and-swap thread metadata, with immutable pre-transition recovery snapshots.
use crate::{
    TEMP_ID, digest, invalid_id, private_dir, private_open, read_private, sync_dir, valid_hash,
};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::Ordering;
const INDEX_BYTES: u64 = 16 * 1024 * 1024;
const SNAPSHOTS_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const RECORDS: usize = 65_536;
const INTERRUPTED_WRITES: usize = 128;
struct WriterLock(fs::File);
impl Drop for WriterLock {
    fn drop(&mut self) {
        // A concurrent fork can retain the open description after this File closes.
        let _ = self.0.unlock();
    }
}
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn valid_record(record: &Value) -> bool {
    record.is_object()
        && record["id"].as_str().is_some_and(|id| !invalid_id(id))
        && record["title"].is_string()
        && record["createdAt"].as_str().is_some_and(|s| !s.is_empty())
        && record["archived"].is_boolean()
        && [
            "model",
            "effort",
            "agent",
            "cwd",
            "nativeSessionId",
            "nativeSessionRewindId",
        ]
        .iter()
        .all(|key| record.get(*key).is_none_or(Value::is_string))
        && ["pinned", "bypass"]
            .iter()
            .all(|key| record.get(*key).is_none_or(Value::is_boolean))
        && record
            .get("lastReadAt")
            .is_none_or(|v| v.as_f64().is_some_and(f64::is_finite))
        && record.get("creation").is_none_or(|v| {
            v.is_object()
                && v["eventId"].is_string()
                && v["identity"].as_str().is_some_and(valid_hash)
        })
        && record.get("nativeTurn").is_none_or(|turn| {
            turn.is_object()
                && turn["id"].is_string()
                && ["running", "interrupted"].contains(&turn["state"].as_str().unwrap_or(""))
                && turn
                    .get("userEventId")
                    .is_none_or(|v| v.as_str().is_some_and(|s| s.encode_utf16().count() <= 128))
                && turn.get("recoveryAttempts").is_none_or(|v| {
                    v.as_f64()
                        .is_some_and(|n| n.fract() == 0.0 && (0.0..=3.0).contains(&n))
                })
                && turn.get("recoveryActive").is_none_or(Value::is_boolean)
                && turn.get("attemptId").is_none_or(|v| {
                    v.as_str().is_some_and(|id| {
                        id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
                    })
                })
        })
}
pub(crate) fn file_name(id: &str) -> String {
    id.encode_utf16()
        .map(|unit| {
            if unit <= 127
                && ((unit as u8).is_ascii_alphanumeric()
                    || [b'_', b'.', b'-'].contains(&(unit as u8)))
            {
                unit as u8 as char
            } else {
                '_'
            }
        })
        .collect()
}
fn valid_index(index: &Value) -> bool {
    let Some(records) = index.as_array() else {
        return false;
    };
    let mut ids = HashSet::new();
    let mut files = HashSet::new();
    records.len() <= RECORDS
        && records.iter().all(|record| {
            valid_record(record)
                && ids.insert(record["id"].as_str().unwrap())
                && files.insert(file_name(record["id"].as_str().unwrap()))
        })
}
// JSON.parse/JSON.stringify can change an exactly representable number's notation.
// Larger integer values remain opaque: rounding them is never a valid migration.
pub(crate) fn compatible(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Number(a), Value::Number(b)) => {
            a == b
                || a.as_f64()
                    .zip(b.as_f64())
                    .is_some_and(|(a, b)| a == b && a.abs() <= crate::SAFE_INTEGER as f64)
        }
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| compatible(a, b))
        }
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len()
                && a.iter()
                    .all(|(key, a)| b.get(key).is_some_and(|b| compatible(a, b)))
        }
        _ => left == right,
    }
}
pub(crate) fn current(root: &Path) -> io::Result<Option<Vec<u8>>> {
    let path = root.join("threads.json");
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        meta => {
            let meta = meta?;
            if !meta.is_file() || meta.file_type().is_symlink() {
                return Err(invalid());
            }
            let bytes = read_private(&path, INDEX_BYTES)?;
            let index: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            if !valid_index(&index) {
                return Err(invalid());
            }
            Ok(Some(bytes))
        }
    }
}
fn snapshot(root: &Path, bytes: &[u8]) -> io::Result<()> {
    let directory = root.join(".thread-index-recovery");
    private_dir(&directory)?;
    let path = directory.join(format!("{}.json", digest(bytes)));
    if fs::symlink_metadata(&path).is_ok() {
        if read_private(&path, INDEX_BYTES)? != bytes {
            return Err(invalid());
        }
        return Ok(());
    }
    let mut total = 0u64;
    let mut count = 0;
    for entry in fs::read_dir(&directory)? {
        let entry = entry?;
        let meta = fs::symlink_metadata(entry.path())?;
        if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > INDEX_BYTES {
            return Err(invalid());
        }
        total = total.checked_add(meta.len()).ok_or_else(invalid)?;
        count += 1;
    }
    if total + bytes.len() as u64 > SNAPSHOTS_BYTES || count >= RECORDS {
        return Err(invalid());
    }
    let temporary = directory.join(format!(
        ".pending.{}.{}",
        std::process::id(),
        TEMP_ID.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = private_open(&temporary, true)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    // An interrupted snapshot remains private scratch evidence, never a corrupt final backup.
    fs::hard_link(&temporary, &path)?;
    let _ = fs::remove_file(temporary);
    sync_dir(&directory)?;
    sync_dir(root)
}
fn empty_home(root: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(root.join("threads/home.jsonl")) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(true),
        meta => {
            let meta = meta?;
            Ok(meta.is_file() && !meta.file_type().is_symlink() && meta.len() == 0)
        }
    }
}
fn bound_pending(root: &Path) -> io::Result<()> {
    let mut count = 0;
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with(".thread-index-pending.")
        {
            continue;
        }
        let meta = fs::symlink_metadata(entry.path())?;
        if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > INDEX_BYTES {
            return Err(invalid());
        }
        count += 1;
    }
    if count >= INTERRUPTED_WRITES {
        return Err(invalid());
    }
    Ok(())
}
fn replace(root: &Path, request: &Value, native_owned: bool) -> io::Result<Value> {
    private_dir(root)?;
    let owner = private_open(&root.join(".rust-thread-index-owner.lock"), false)?;
    owner.try_lock().map_err(io::Error::other)?;
    let _owner = WriterLock(owner);
    // A legacy writer's pending file is ambiguous state, never disposable scratch data.
    if fs::symlink_metadata(root.join("threads.json.tmp")).is_ok() {
        return Ok(json!({"error":"thread-index-recovery-required"}));
    }
    let original = current(root)?;
    let expected = match request.get("expectedHash") {
        Some(Value::Null) => None,
        Some(Value::String(hash)) if valid_hash(hash) => Some(hash.as_str()),
        _ => return Err(invalid()),
    };
    if original.as_ref().map(|bytes| digest(bytes)).as_deref() != expected {
        return Ok(json!({"error":"conflicting-thread-index"}));
    }
    let index = &request["threads"];
    if !valid_index(index) {
        return Err(invalid());
    }
    let old = original
        .as_ref()
        .map(|bytes| serde_json::from_slice::<Value>(bytes))
        .transpose()
        .map_err(io::Error::other)?;
    if let Some(old) = &old {
        for previous in old.as_array().unwrap() {
            let next = index
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["id"] == previous["id"]);
            if let Some(next) = next {
                if !native_owned
                    && previous["nativeTurn"]["attemptId"].is_string()
                    && ["nativeSessionId", "nativeSessionRewindId"]
                        .iter()
                        .any(|field| previous.get(*field) != next.get(*field))
                {
                    return Ok(json!({"error":"unscoped-native-session-transition"}));
                }
                if next.get("agent") != previous.get("agent")
                    || next.get("cwd") != previous.get("cwd")
                    || next.get("createdAt") != previous.get("createdAt")
                    || next.get("creation") != previous.get("creation")
                {
                    return Ok(json!({"error":"conflicting-thread-owner"}));
                }
                // Preserve unrecognized fields: an older compatibility layer cannot erase newer state.
                for (key, value) in previous.as_object().unwrap() {
                    if ![
                        "id",
                        "title",
                        "createdAt",
                        "archived",
                        "model",
                        "effort",
                        "agent",
                        "cwd",
                        "nativeSessionId",
                        "nativeSessionRewindId",
                        "pinned",
                        "bypass",
                        "lastReadAt",
                        "creation",
                        "nativeTurn",
                    ]
                    .contains(&key.as_str())
                        && !next.get(key).is_some_and(|next| compatible(value, next))
                    {
                        return Ok(json!({"error":"unsupported-thread-transition"}));
                    }
                }
            } else if previous["id"] != "home" || !empty_home(root)? {
                return Ok(json!({"error":"thread-history-retained"}));
            }
        }
        if compatible(old, index) {
            return Ok(json!({"stored":true,"hash":expected,"changed":false}));
        }
    }
    let mut bytes = serde_json::to_vec_pretty(index).map_err(io::Error::other)?;
    bytes.push(b'\n');
    if bytes.len() as u64 > INDEX_BYTES {
        return Err(invalid());
    }
    if let Some(original) = &original {
        snapshot(root, original)?;
    }
    bound_pending(root)?;
    let temporary = root.join(format!(
        ".thread-index-pending.{}.{}.json",
        std::process::id(),
        TEMP_ID.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = private_open(&temporary, true)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    if current(root)?
        .as_ref()
        .map(|bytes| digest(bytes))
        .as_deref()
        != expected
    {
        return Ok(json!({"error":"conflicting-thread-index"}));
    }
    if original.is_none() {
        fs::hard_link(&temporary, root.join("threads.json"))?;
        let _ = fs::remove_file(&temporary);
    } else {
        fs::rename(&temporary, root.join("threads.json"))?;
    }
    sync_dir(root)?;
    if current(root)?.as_deref() != Some(bytes.as_slice()) {
        return Err(invalid());
    }
    Ok(json!({"stored":true,"hash":digest(&bytes),"changed":true}))
}
pub fn request(root: &Path, request: &Value) -> Value {
    if request["op"] != "replace" {
        return json!({"error":"invalid-thread-index-request"});
    }
    replace(root, request, false).unwrap_or_else(|_| json!({"error":"thread-index-storage-failed"}))
}
// This privilege is a crate function, never a caller-controlled JSON option.
pub(crate) fn request_native(root: &Path, request: &Value) -> Value {
    replace(root, request, true).unwrap_or_else(|_| json!({"error":"thread-index-storage-failed"}))
}
