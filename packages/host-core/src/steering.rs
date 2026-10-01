//! Durable native follow-up intent. An attempted external effect is never retried implicitly.
use crate::{invalid_id, journal::Journal, valid_hash};
use serde_json::{Value, json};
use std::{collections::BTreeMap, collections::HashMap, io, path::Path};
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn valid(record: &Value) -> bool {
    record.is_object()
        && ["eventId", "threadId", "activeEventId", "attemptId"]
            .iter()
            .all(|key| record[*key].as_str().is_some_and(|id| !invalid_id(id)))
        && record["eventId"] != record["activeEventId"]
        && record["identity"].as_str().is_some_and(valid_hash)
        && record["completionId"]
            .as_str()
            .is_some_and(|id| !id.is_empty() && id.encode_utf16().count() <= 256)
        && record
            .get("sessionId")
            .is_none_or(|id| id.as_str().is_some_and(|id| id.len() <= 1024))
        && record["status"]
            .as_str()
            .is_some_and(|status| ["attempting", "delivered", "rejected"].contains(&status))
}
fn binding(a: &Value, b: &Value) -> bool {
    [
        "eventId",
        "threadId",
        "activeEventId",
        "attemptId",
        "identity",
        "completionId",
        "sessionId",
    ]
    .iter()
    .all(|key| a[*key] == b[*key])
}
pub struct Steering {
    journal: Journal,
    entries: BTreeMap<String, Value>,
    attempts: HashMap<String, String>,
    failed: bool,
}
impl Steering {
    pub fn open(root: &Path) -> io::Result<Self> {
        let mut journal =
            Journal::open(root, "native-steering.jsonl", ".rust-steering-owner.lock")?;
        let records = journal.take_records();
        let mut store = Self {
            entries: BTreeMap::new(),
            attempts: HashMap::new(),
            failed: false,
            journal,
        };
        for record in records {
            if store.transition(&record).is_err() {
                return Err(invalid());
            }
            store.install(record);
        }
        Ok(store)
    }
    fn transition(&self, record: &Value) -> io::Result<()> {
        if !valid(record) {
            return Err(invalid());
        }
        let event = record["eventId"].as_str().unwrap();
        let attempt = record["attemptId"].as_str().unwrap();
        if self
            .attempts
            .get(attempt)
            .is_some_and(|owner| owner != event)
        {
            return Err(invalid());
        }
        if let Some(prior) = self.entries.get(event) {
            if prior["threadId"] != record["threadId"] || prior["identity"] != record["identity"] {
                return Err(invalid());
            }
            if binding(prior, record) {
                if prior["status"] != "attempting" && prior["status"] != record["status"] {
                    return Err(invalid());
                }
            } else if prior["status"] != "rejected"
                || record["status"] != "attempting"
                || self.attempts.contains_key(attempt)
            {
                return Err(invalid());
            }
        } else if record["status"] != "attempting" {
            return Err(invalid());
        }
        Ok(())
    }
    fn install(&mut self, record: Value) {
        let event = record["eventId"].as_str().unwrap().to_owned();
        self.attempts
            .insert(record["attemptId"].as_str().unwrap().into(), event.clone());
        self.entries.insert(event, record);
    }
    pub fn records(&self) -> Vec<Value> {
        self.entries.values().cloned().collect()
    }
    pub fn get(&self, event: &str) -> Option<Value> {
        self.entries.get(event).cloned()
    }
    fn save(&mut self, record: Value) -> io::Result<()> {
        self.journal.append(&record)?;
        self.install(record);
        Ok(())
    }
    pub fn finish(&mut self, event: &str, attempt: &str, status: &str) -> Value {
        if self.failed {
            return json!({"error":"steering-storage-failed"});
        }
        let Some(mut record) = self.get(event) else {
            return json!({"error":"unknown-steering-intent"});
        };
        if record["attemptId"] != attempt || !["delivered", "rejected"].contains(&status) {
            return json!({"error":"conflicting-steering-outcome"});
        }
        if record["status"] == status {
            return json!({"record":record});
        }
        record["status"] = json!(status);
        if self.transition(&record).is_err() {
            return json!({"error":"conflicting-steering-outcome"});
        }
        match self.save(record.clone()) {
            Ok(()) => json!({"record":record}),
            Err(_) => {
                self.failed = true;
                json!({"error":"steering-storage-failed"})
            }
        }
    }
    pub fn request(&mut self, request: &Value) -> Value {
        if self.failed {
            return json!({"error":"steering-storage-failed"});
        }
        match request["op"].as_str() {
            Some("steering_open") => json!({"stored":true}),
            Some("steering_get") => {
                json!({"record":self.get(request["eventId"].as_str().unwrap_or(""))})
            }
            Some("steering_active") => json!({"unconfirmed": self.entries.values().any(|record|
                record["threadId"] == request["threadId"] && record["activeEventId"] == request["eventId"]
                && record["status"] == "attempting")}),
            Some("steering_list") => {
                let offset = request["offset"].as_u64().unwrap_or(0) as usize;
                let mut records = Vec::new();
                let mut bytes = 0;
                for record in self.entries.values().skip(offset).take(64) {
                    let size = serde_json::to_vec(record).map_or(usize::MAX, |bytes| bytes.len());
                    if size > 512 * 1024 {
                        return json!({"error":"steering-record-too-large"});
                    }
                    if bytes + size > 512 * 1024 {
                        break;
                    }
                    bytes += size;
                    records.push(record.clone());
                }
                let next = offset.saturating_add(records.len());
                json!({"records":records,"next":if next<self.entries.len(){Some(next)}else{None}})
            }
            Some("steering_begin") => {
                if !request["record"].is_object() {
                    return json!({"error":"invalid-steering-intent"});
                }
                let mut record = request["record"].clone();
                record["status"] = json!("attempting");
                if !valid(&record) {
                    return json!({"error":"invalid-steering-intent"});
                }
                if let Some(prior) = self.entries.get(record["eventId"].as_str().unwrap()) {
                    if prior["threadId"] != record["threadId"]
                        || prior["identity"] != record["identity"]
                    {
                        return json!({"error":"conflicting-steering-owner"});
                    }
                    if prior["status"] != "rejected" || prior["attemptId"] == record["attemptId"] {
                        return json!({"record":prior,"reserved":false});
                    }
                    let mut merged = prior.clone();
                    for (key, value) in record.as_object().unwrap() {
                        merged[key] = value.clone();
                    }
                    if !record.as_object().unwrap().contains_key("sessionId") {
                        merged.as_object_mut().unwrap().remove("sessionId");
                    }
                    record = merged;
                }
                if self.transition(&record).is_err() {
                    return json!({"error":"conflicting-steering-intent"});
                }
                match self.save(record.clone()) {
                    Ok(()) => json!({"record":record,"reserved":true}),
                    Err(_) => {
                        self.failed = true;
                        json!({"error":"steering-storage-failed"})
                    }
                }
            }
            Some("steering_reject") => self.finish(
                request["eventId"].as_str().unwrap_or(""),
                request["attemptId"].as_str().unwrap_or(""),
                "rejected",
            ),
            _ => json!({"error":"invalid-steering-request"}),
        }
    }
}
