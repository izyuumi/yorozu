//! Durable channel outbox transitions. Transport/provider code cannot bypass this writer.
use crate::{TEMP_ID, private_dir, private_open, sync_dir};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn id(value: &Value, key: &str) -> io::Result<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty() && v.encode_utf16().count() <= 128)
        .map(String::from)
        .ok_or_else(invalid)
}
fn atomic<T: Serialize>(path: &Path, value: &T) -> io::Result<()> {
    let parent = path.parent().ok_or_else(invalid)?;
    let temp = parent.join(format!(
        ".outbox.{}.{}.tmp",
        std::process::id(),
        TEMP_ID.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let mut file = private_open(&temp, true)?;
        serde_json::to_writer(&mut file, value).map_err(io::Error::other)?;
        file.flush()?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, path)?;
        sync_dir(parent)
    })();
    let _ = fs::remove_file(temp);
    result
}
fn load(path: &Path, fallback: Value) -> io::Result<Value> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    match options.open(path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(fallback),
        file => serde_json::from_reader(BufReader::new(file?)).map_err(io::Error::other),
    }
}
pub struct ChannelOutbox {
    root: PathBuf,
    messages: Vec<Value>,
    delivery: HashMap<String, String>,
    cancelled: HashSet<String>,
    original_models: HashMap<String, Value>,
    _owner: File,
}
impl Drop for ChannelOutbox {
    fn drop(&mut self) {
        let _ = self._owner.unlock();
    }
}
impl ChannelOutbox {
    pub fn open(root: &Path) -> io::Result<Self> {
        private_dir(root)?;
        let owner = private_open(&root.join(".rust-channel-owner.lock"), false)?;
        owner.try_lock().map_err(io::Error::other)?;
        let messages: Vec<Value> =
            serde_json::from_value(load(&root.join("channel-outbox.json"), json!([]))?)
                .map_err(io::Error::other)?;
        let delivery: HashMap<String, String> =
            serde_json::from_value(load(&root.join("channel-model-delivery.json"), json!({}))?)
                .map_err(io::Error::other)?;
        if delivery
            .values()
            .any(|s| s != "prepared" && s != "delivered")
        {
            return Err(invalid());
        }
        let mut cancelled: HashSet<String> =
            serde_json::from_value(load(&root.join("channel-cancelled.json"), json!([]))?)
                .map_err(io::Error::other)?;
        let original_models: HashMap<String, Value> =
            serde_json::from_value(load(&root.join("channel-model-original.json"), json!({}))?)
                .map_err(io::Error::other)?;
        let mut seen = HashSet::new();
        for message in &messages {
            let message_id = id(message, "id")?;
            id(message, "threadId")?;
            if !seen.insert(message_id) || message.get("text").and_then(Value::as_str).is_none() {
                return Err(invalid());
            }
        }
        // A prior host may have committed withdrawal before removing the outbox row.
        // Replay only validated final withdrawal intents; keep other uncertain outcomes.
        let mut stop_options = fs::OpenOptions::new();
        stop_options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            stop_options.custom_flags(libc::O_NOFOLLOW);
        }
        match stop_options.open(root.join("stopped-turns.jsonl")) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            file => {
                let mut latest = HashMap::<String, (String, String)>::new();
                let mut reader = BufReader::new(file?);
                loop {
                    let mut bytes = Vec::new();
                    let mut complete = false;
                    loop {
                        let part = reader.fill_buf()?;
                        if part.is_empty() {
                            break;
                        }
                        let length = part
                            .iter()
                            .position(|b| *b == b'\n')
                            .map_or(part.len(), |n| n + 1);
                        if bytes.len() + length > 1024 * 1024 {
                            return Err(invalid());
                        }
                        complete = part[length - 1] == b'\n';
                        bytes.extend_from_slice(&part[..length]);
                        reader.consume(length);
                        if complete {
                            break;
                        }
                    }
                    if bytes.is_empty() {
                        break;
                    }
                    // The host trims interrupted final journal records on startup.
                    if !complete {
                        break;
                    }
                    let line = std::str::from_utf8(&bytes).map_err(io::Error::other)?;
                    if line.trim().is_empty() {
                        continue;
                    }
                    let value: Value = serde_json::from_str(line).map_err(io::Error::other)?;
                    let target = id(&value, "targetEventId")?;
                    let status = value
                        .get("status")
                        .and_then(Value::as_str)
                        .ok_or_else(invalid)?;
                    let thread = id(&value, "threadId")?;
                    if ![
                        "requested",
                        "stopped",
                        "completed",
                        "withdrawn",
                        "unconfirmed",
                    ]
                    .contains(&status)
                    {
                        return Err(invalid());
                    }
                    if latest
                        .get(&target)
                        .is_some_and(|(owner, _)| owner != &thread)
                    {
                        return Err(invalid());
                    }
                    if messages
                        .iter()
                        .any(|m| m["id"] == target && m["threadId"] != thread)
                    {
                        return Err(invalid());
                    }
                    latest.insert(target, (thread, status.into()));
                }
                cancelled.extend(
                    latest
                        .into_iter()
                        .filter_map(|(id, (_, status))| (status == "withdrawn").then_some(id)),
                );
            }
        }
        let mut store = Self {
            root: root.into(),
            messages,
            delivery,
            cancelled,
            original_models,
            _owner: owner,
        };
        let retained: Vec<_> = store
            .messages
            .iter()
            .filter(|m| {
                let id = m["id"].as_str().unwrap();
                store.delivery.get(id).map(String::as_str) != Some("delivered")
                    && !store.cancelled.contains(id)
            })
            .collect();
        if retained.len() != store.messages.len() {
            atomic(&store.root.join("channel-outbox.json"), &retained)?;
            let delivery = &store.delivery;
            let cancelled = &store.cancelled;
            store.messages.retain(|m| {
                let id = m["id"].as_str().unwrap();
                delivery.get(id).map(String::as_str) != Some("delivered") && !cancelled.contains(id)
            });
        }
        Ok(store)
    }
    pub fn snapshot(&self) -> Value {
        json!({"outbox":self.messages.iter().map(|m| json!({"id":m["id"],"threadId":m["threadId"]})).collect::<Vec<_>>(),"modelDelivery":self.delivery})
    }
    pub fn get(&self, target: &str) -> Option<Value> {
        self.messages.iter().find(|m| m["id"] == target).cloned()
    }
    fn set_delivery(&mut self, target: &str, status: &str) -> io::Result<()> {
        let mut next = self.delivery.clone();
        next.insert(target.into(), status.into());
        atomic(&self.root.join("channel-model-delivery.json"), &next)?;
        self.delivery = next;
        Ok(())
    }
    pub fn enqueue(&mut self, message: Value) -> io::Result<Value> {
        let target = id(&message, "id")?;
        id(&message, "threadId")?;
        if message.get("text").and_then(Value::as_str).is_none() {
            return Err(invalid());
        }
        if self.cancelled.contains(&target)
            || self.delivery.get(&target).map(String::as_str) == Some("delivered")
        {
            return Ok(self.snapshot());
        }
        if let Some(original) = self.original_models.get(&target)
            && message.get("channelModel") != Some(original)
        {
            return Err(invalid());
        }
        if let Some(stored) = self.messages.iter().find(|m| m["id"] == target) {
            let mut candidate = stored.clone();
            if let Some(object) = candidate.as_object_mut() {
                object.remove("replyAttempted");
                // A prepared model pin was deliberately removed before transmission.
                if !object.contains_key("channelModel")
                    && self.delivery.get(&target).map(String::as_str) == Some("prepared")
                    && let Some(model) = message.get("channelModel")
                {
                    object.insert("channelModel".into(), model.clone());
                }
            }
            if candidate != message {
                return Err(invalid());
            }
            return Ok(self.snapshot());
        }
        if let Some(model) = message.get("channelModel") {
            self.remember_model(&target, model.clone())?;
        }
        let mut next: Vec<&Value> = self.messages.iter().collect();
        next.push(&message);
        atomic(&self.root.join("channel-outbox.json"), &next)?;
        self.messages.push(message);
        Ok(self.snapshot())
    }
    fn remember_model(&mut self, target: &str, model: Value) -> io::Result<()> {
        if let Some(original) = self.original_models.get(target) {
            return if original == &model {
                Ok(())
            } else {
                Err(invalid())
            };
        }
        let mut next = self.original_models.clone();
        next.insert(target.into(), model);
        atomic(&self.root.join("channel-model-original.json"), &next)?;
        self.original_models = next;
        Ok(())
    }
    pub fn prepared(&mut self, target: &str) -> io::Result<Value> {
        let position = self
            .messages
            .iter()
            .position(|m| m["id"] == target)
            .ok_or_else(invalid)?;
        if let Some(model) = self.messages[position].get("channelModel").cloned() {
            self.remember_model(target, model)?;
        }
        if self.delivery.get(target).map(String::as_str) != Some("prepared") {
            self.set_delivery(target, "prepared")?;
        }
        // If the process dies between these writes, the preparation marker prevents
        // resetting a pin. Recovery can safely repeat this second transition.
        let mut message = self.messages[position].clone();
        message
            .as_object_mut()
            .ok_or_else(invalid)?
            .remove("channelModel");
        let next: Vec<_> = self
            .messages
            .iter()
            .enumerate()
            .map(|(index, m)| if index == position { &message } else { m })
            .collect();
        atomic(&self.root.join("channel-outbox.json"), &next)?;
        self.messages[position] = message;
        Ok(self.snapshot())
    }
    pub fn attempted(&mut self, target: &str) -> io::Result<Value> {
        let position = self
            .messages
            .iter()
            .position(|m| m["id"] == target)
            .ok_or_else(invalid)?;
        if self.messages[position].get("replyAttempted") == Some(&json!(true)) {
            return Ok(self.snapshot());
        }
        let mut message = self.messages[position].clone();
        message
            .as_object_mut()
            .ok_or_else(invalid)?
            .insert("replyAttempted".into(), json!(true));
        let next: Vec<_> = self
            .messages
            .iter()
            .enumerate()
            .map(|(index, m)| if index == position { &message } else { m })
            .collect();
        atomic(&self.root.join("channel-outbox.json"), &next)?;
        self.messages[position] = message;
        Ok(self.snapshot())
    }
    fn remove(&mut self, target: &str) -> io::Result<()> {
        let next: Vec<_> = self.messages.iter().filter(|m| m["id"] != target).collect();
        atomic(&self.root.join("channel-outbox.json"), &next)?;
        self.messages.retain(|m| m["id"] != target);
        Ok(())
    }
    pub fn acknowledge(&mut self, target: &str) -> io::Result<Value> {
        if self.delivery.get(target).map(String::as_str) == Some("prepared") {
            self.set_delivery(target, "delivered")?;
        }
        self.remove(target)?;
        Ok(self.snapshot())
    }
    pub fn reject(&mut self, target: &str) -> io::Result<Value> {
        let message = self
            .messages
            .iter()
            .find(|m| m["id"] == target)
            .ok_or_else(invalid)?;
        if message.get("replyAttempted") == Some(&json!(true)) {
            return Err(invalid());
        }
        self.remove(target)?;
        Ok(self.snapshot())
    }
    pub fn withdraw(&mut self, target: &str) -> io::Result<Value> {
        if target.is_empty() || target.encode_utf16().count() > 128 {
            return Err(invalid());
        }
        if self
            .messages
            .iter()
            .any(|m| m["id"] == target && m.get("replyAttempted") == Some(&json!(true)))
        {
            return Err(invalid());
        }
        let mut next = self.cancelled.clone();
        next.insert(target.into());
        // Tombstone first: an interrupted removal must not redispatch on recovery.
        atomic(&self.root.join("channel-cancelled.json"), &next)?;
        self.cancelled = next;
        self.remove(target)?;
        Ok(self.snapshot())
    }
    pub fn request(&mut self, request: &Value) -> Value {
        let target = request
            .get("messageId")
            .and_then(Value::as_str)
            .unwrap_or("");
        let result = match request.get("op").and_then(Value::as_str) {
            Some("outbox_snapshot") => return self.snapshot(),
            Some("outbox_get") => return json!({"message":self.get(target)}),
            Some("outbox_enqueue") => self.enqueue(request["message"].clone()),
            Some("outbox_prepared") => self.prepared(target),
            Some("outbox_attempted") => self.attempted(target),
            Some("outbox_ack") => self.acknowledge(target),
            Some("outbox_reject") => self.reject(target),
            Some("outbox_withdraw") => self.withdraw(target),
            _ => Err(invalid()),
        };
        result.unwrap_or_else(|_| json!({"error":"channel-storage-failed"}))
    }
}
