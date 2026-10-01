//! Durable Stop intent and confirmation currency, bound to the original operation/thread.
use crate::{invalid_id, journal::Journal};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io;
use std::path::Path;
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn valid(entry: &Value) -> bool {
    entry.is_object()
        && ["targetEventId", "threadId"]
            .iter()
            .all(|key| entry[*key].as_str().is_some_and(|s| !invalid_id(s)))
        && entry["status"].as_str().is_some_and(|s| {
            [
                "requested",
                "stopped",
                "completed",
                "withdrawn",
                "unconfirmed",
            ]
            .contains(&s)
        })
        && ["runId", "sessionKey", "partialText"]
            .iter()
            .all(|key| entry.get(*key).is_none_or(Value::is_string))
        && entry.get("preDispatch").is_none_or(Value::is_boolean)
        && entry["requestIds"].as_array().is_some_and(|ids| {
            ids.iter()
                .all(|id| id.as_str().is_some_and(|s| !invalid_id(s)))
        })
}
pub struct Stops {
    journal: Journal,
    entries: HashMap<String, Value>,
}
impl Stops {
    pub fn open(root: &Path) -> io::Result<Self> {
        let mut journal = Journal::open(root, "stopped-turns.jsonl", ".rust-stop-owner.lock")?;
        let mut entries: HashMap<String, Value> = HashMap::new();
        for entry in journal.take_records() {
            if !valid(&entry) {
                return Err(invalid());
            }
            let id = entry["targetEventId"].as_str().unwrap().to_owned();
            if entries
                .get(&id)
                .is_some_and(|prior| prior["threadId"] != entry["threadId"])
            {
                return Err(invalid());
            }
            entries.insert(id, entry);
        }
        Ok(Self { journal, entries })
    }
    fn write(&mut self, entry: &Value) -> io::Result<Value> {
        if !valid(entry) {
            return Err(invalid());
        }
        let id = entry["targetEventId"].as_str().unwrap();
        let mut merged = entry.clone();
        if let Some(prior) = self.entries.get(id) {
            if prior["threadId"] != entry["threadId"] {
                return Ok(json!({"error":"conflicting-stop-owner"}));
            }
            if ["stopped", "completed", "withdrawn"].contains(&prior["status"].as_str().unwrap())
                && prior["status"] != entry["status"]
            {
                return Ok(json!({"error":"conflicting-stop-transition"}));
            }
            merged = prior.clone();
            for (key, value) in entry.as_object().unwrap() {
                merged[key] = value.clone();
            }
            let mut requests = prior["requestIds"].as_array().unwrap().clone();
            for request in entry["requestIds"].as_array().unwrap() {
                if !requests.contains(request) {
                    requests.push(request.clone());
                }
            }
            merged["requestIds"] = Value::Array(requests);
            if &merged == prior {
                return Ok(json!({"record":prior}));
            }
        }
        self.journal.append(&merged)?;
        self.entries.insert(id.into(), merged.clone());
        Ok(json!({"record":merged}))
    }
    pub fn request(&mut self, request: &Value) -> Value {
        match request["op"].as_str() {
            Some("stop_save") => self
                .write(&request["record"])
                .unwrap_or_else(|_| json!({"error":"stop-storage-failed"})),
            Some("stop_get") => self
                .entries
                .get(request["targetEventId"].as_str().unwrap_or(""))
                .map_or_else(|| json!({"record":null}), |record| json!({"record":record})),
            _ => json!({"error":"invalid-stop-request"}),
        }
    }
}
