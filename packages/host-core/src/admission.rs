//! Irreversible expired-operation identities. Accepted history remains a later boundary.
use crate::{SAFE_INTEGER, invalid_id, journal::Journal, valid_hash};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io;
use std::path::Path;
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
    journal: Journal,
    entries: HashMap<String, Value>,
}
impl Admissions {
    pub fn open(root: &Path) -> io::Result<Self> {
        let mut journal = Journal::open(
            root,
            "expired-admissions.jsonl",
            ".rust-admission-owner.lock",
        )?;
        let mut entries = HashMap::new();
        for entry in journal.take_records() {
            if !valid(&entry) {
                return Err(invalid());
            }
            let id = entry["id"].as_str().unwrap().to_owned();
            if entries.insert(id, entry).is_some() {
                return Err(invalid());
            }
        }
        Ok(Self { journal, entries })
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
        self.journal.append(entry)?;
        self.entries.insert(id.into(), entry.clone());
        Ok(json!({"status":"expired"}))
    }
    pub fn request(&mut self, request: &Value) -> Value {
        if !self.journal.available() {
            return json!({"error":"admission-storage-failed"});
        }
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
