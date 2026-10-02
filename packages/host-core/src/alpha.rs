//! Isolated alpha conversation owner. Uses committed History transactions, never imports profiles.
use crate::{history::History, now_ms, private_dir, private_open};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

pub const FRAME_BYTES: u64 = 1024 * 1024;
const EVENT_BYTES: usize = 64 * 1024;
const EVENT_LIMIT: usize = 4096;
const RUN_LIMIT: usize = 12;
const THREAD: &str = "alpha-main-v1";
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn identifier(value: &Value) -> Option<&str> {
    value.as_str().filter(|s| {
        !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
    })
}
fn terminal(kind: &str) -> bool {
    ["completed", "stopped", "failed", "unconfirmed"].contains(&kind)
}

pub struct Conversation {
    store: History,
    pub profile: PathBuf,
    pub workspace: PathBuf,
    events: Vec<Value>,
    runs: HashMap<String, String>,
    pub active: Option<String>,
}
impl Conversation {
    pub fn open(profile: &Path) -> io::Result<Self> {
        // Dedicated temporary profiles only. Canonicalize parent before creating anything.
        let parent = profile.parent().ok_or_else(invalid)?.canonicalize()?;
        let temporary = std::env::temp_dir().canonicalize()?;
        let tmp = Path::new("/tmp").canonicalize().ok();
        if !parent.starts_with(&temporary) && !tmp.is_some_and(|p| parent.starts_with(p)) {
            return Err(invalid());
        }
        let profile = parent.join(profile.file_name().ok_or_else(invalid)?);
        if let Ok(meta) = fs::symlink_metadata(&profile) {
            if !meta.is_dir() || meta.file_type().is_symlink() {
                return Err(invalid());
            }
        } else {
            private_dir(&profile)?;
        }
        let marker = profile.join(".yorozu-alpha-v1");
        if !marker.exists() {
            if fs::read_dir(&profile)?.next().is_some() {
                return Err(invalid());
            }
            let mut file = private_open(&marker, true)?;
            file.write_all(b"yorozu-alpha-v1\n")?;
            file.sync_all()?;
            crate::sync_dir(&profile)?;
        } else if crate::read_private(&marker, 64)? != b"yorozu-alpha-v1\n" {
            return Err(invalid());
        }
        let workspace = profile.join("workspace");
        private_dir(&workspace)?;
        let mut store = History::open(&profile.join("state"))?;
        let mut events = Vec::new();
        let mut cursor: Option<Value> = None;
        loop {
            let mut request = json!({"op":"history_page","threadId":THREAD,"minTs":0,"includeApprovalStatus":true});
            if let Some(cursor) = cursor {
                request["after"] = cursor;
            }
            let page = store.request(&request);
            let rows = page["events"].as_array().ok_or_else(invalid)?;
            for row in rows {
                let event = &row["data"];
                if row["kind"] != "alpha_event"
                    || event["seq"].as_u64() != Some(events.len() as u64 + 1)
                    || identifier(&event["runId"]).is_none()
                {
                    return Err(invalid());
                }
                events.push(event.clone());
                if events.len() >= EVENT_LIMIT {
                    return Err(invalid());
                }
            }
            if page["more"] != true {
                break;
            }
            cursor = Some(rows.last().ok_or_else(invalid)?["syncCursor"].clone());
        }
        let mut runs = HashMap::new();
        let mut unresolved = None;
        for event in &events {
            let run = event["runId"].as_str().ok_or_else(invalid)?.to_owned();
            if event["kind"] == "accepted" {
                runs.insert(
                    run.clone(),
                    event["text"].as_str().ok_or_else(invalid)?.to_owned(),
                );
                unresolved = Some(run.clone());
            } else if terminal(event["kind"].as_str().unwrap_or(""))
                && unresolved.as_ref() == Some(&run)
            {
                unresolved = None;
            }
        }
        let mut owner = Self {
            store,
            profile,
            workspace,
            events,
            runs,
            active: unresolved.clone(),
        };
        // Restart never reissues provider work, including an accepted-but-unlaunched task.
        if let Some(run) = unresolved {
            owner.record(
                &run,
                "unconfirmed",
                Some("Host restarted; prior worker outcome remains unconfirmed."),
                None,
            )?;
            owner.active = None;
        }
        Ok(owner)
    }
    pub fn has_run(&self, run: &str) -> bool {
        self.runs.contains_key(run)
    }
    pub fn snapshot(&self) -> Value {
        // Retain all conversation/terminal states; only recent provider detail is projected.
        // The complete bounded event ledger remains available in this temporary profile.
        let mut detail = HashMap::<(&str, &str), usize>::new();
        let mut events: Vec<Value> = self
            .events
            .iter()
            .rev()
            .filter(|event| {
                let kind = event["kind"].as_str().unwrap_or("");
                let run = event["runId"].as_str().unwrap_or("");
                if kind == "update" && self.active.as_deref() != Some(run) {
                    return false;
                }
                if ["update", "activity"].contains(&kind) {
                    let count = detail.entry((run, kind)).or_default();
                    *count += 1;
                    return *count <= if kind == "activity" { 2 } else { 1 };
                }
                true
            })
            .cloned()
            .collect();
        events.reverse();
        json!({"profileRoot":self.profile,"workspace":self.workspace,"events":events,"activeRunId":self.active})
    }
    pub fn record(
        &mut self,
        run: &str,
        kind: &str,
        text: Option<&str>,
        data: Option<Value>,
    ) -> io::Result<Value> {
        if self.events.len() >= EVENT_LIMIT - 1 {
            return Err(invalid());
        }
        let seq = self.events.len() as u64 + 1;
        let mut event = json!({"seq":seq,"runId":run,"kind":kind,"ts":now_ms()});
        if let Some(text) = text {
            event["text"] = json!(text);
        }
        if let Some(data) = data {
            event["data"] = data;
        }
        if serde_json::to_vec(&event).map_err(io::Error::other)?.len() > EVENT_BYTES {
            return Err(invalid());
        }
        let proof = self.store.request(&json!({"op":"history_append","operationId":format!("alpha-{seq}"),"thread":true,"transcript":true,
            "event":{"id":format!("alpha-{seq}"),"threadId":THREAD,"agentId":"main","kind":"alpha_event","ts":event["ts"],"data":event}}));
        if proof["stored"] != true {
            return Err(io::Error::other("alpha-persistence-unconfirmed"));
        }
        self.events.push(event.clone());
        Ok(event)
    }
    /// Acceptance is a durable immutable event. A retry never launches another worker.
    pub fn submit(&mut self, request: &Value) -> io::Result<(Value, Option<Value>)> {
        let Some(run) = identifier(&request["runId"]) else {
            return Ok((json!({"error":"invalid-run"}), None));
        };
        let Some(text) = request["text"]
            .as_str()
            .filter(|t| !t.trim().is_empty() && t.len() <= 16000)
        else {
            return Ok((json!({"error":"invalid-text"}), None));
        };
        if let Some(original) = self.runs.get(run) {
            return Ok((
                if original == text {
                    json!({"accepted":true,"runId":run,"replayed":true})
                } else {
                    json!({"error":"conflicting-run"})
                },
                None,
            ));
        }
        if self.runs.len() >= RUN_LIMIT {
            return Ok((json!({"error":"profile-task-limit"}), None));
        }
        if self.active.is_some() {
            return Ok((json!({"error":"worker-busy"}), None));
        }
        let event = self.record(run, "accepted", Some(text), None)?;
        self.runs.insert(run.to_owned(), text.to_owned());
        self.active = Some(run.to_owned());
        Ok((
            json!({"accepted":true,"runId":run,"replayed":false}),
            Some(event),
        ))
    }
    pub fn stop(&mut self, request: &Value) -> io::Result<(Value, Option<Value>)> {
        let Some(run) = identifier(&request["runId"]) else {
            return Ok((json!({"error":"invalid-run"}), None));
        };
        if self.active.as_deref() != Some(run) {
            return Ok((json!({"requested":false,"runId":run}), None));
        }
        if self
            .events
            .iter()
            .any(|e| e["runId"] == run && e["kind"] == "stop_requested")
        {
            return Ok((json!({"requested":true,"runId":run}), None));
        }
        let event = self.record(run, "stop_requested", None, None)?;
        Ok((json!({"requested":true,"runId":run}), Some(event)))
    }
}
