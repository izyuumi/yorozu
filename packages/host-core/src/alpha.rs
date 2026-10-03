//! Isolated alpha conversation owner. Uses committed History transactions, never imports profiles.
use crate::{history::History, now_ms, private_dir, private_open};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::{self, File};
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
    runs: HashMap<String, Value>,
    secretary_run: Option<String>,
    _secretary_lock: Option<File>,
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
        Self::load(profile, workspace, None, None)
    }
    /// Explicit opt-in only: this root never contains the legacy production store.
    pub fn prepare_secretary(root: &Path, workspace: &Path) -> io::Result<PathBuf> {
        if root.file_name().and_then(|n| n.to_str()) != Some("secretary-v1")
            || !workspace.is_absolute()
        {
            return Err(invalid());
        }
        let parent = root.parent().ok_or_else(invalid)?.canonicalize()?;
        let root = parent.join("secretary-v1");
        if workspace.file_name().and_then(|name| name.to_str()) != Some("Yorozu Secretary")
            || workspace
                .parent()
                .ok_or_else(invalid)?
                .canonicalize()?
                .join("Yorozu Secretary")
                != workspace
            || workspace.starts_with(&root)
        {
            return Err(invalid());
        }
        private_dir(&root)?;
        let marker = root.join(".yorozu-secretary-v1");
        let contents = format!("yorozu-secretary-v1\n{}\n", workspace.display());
        match fs::symlink_metadata(&marker) {
            Ok(meta) if meta.is_file() && !meta.file_type().is_symlink() => {
                if crate::read_private(&marker, 8192)? != contents.as_bytes() {
                    return Err(invalid());
                }
            }
            Ok(_) => return Err(invalid()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if fs::read_dir(&root)?.next().is_some() {
                    return Err(invalid());
                }
                let mut file = private_open(&marker, true)?;
                file.write_all(contents.as_bytes())?;
                file.sync_all()?;
                crate::sync_dir(&root)?;
            }
            Err(error) => return Err(error),
        }
        private_dir(workspace)?;
        // A dedicated, marked workspace cannot adopt an existing populated project.
        let workspace_marker = workspace.join(".yorozu-secretary-workspace-v1");
        let identity = format!("{}\n", root.display());
        match fs::symlink_metadata(&workspace_marker) {
            Ok(meta) if meta.is_file() && !meta.file_type().is_symlink() => {
                if crate::read_private(&workspace_marker, 8192)? != identity.as_bytes() {
                    return Err(invalid());
                }
            }
            Ok(_) => return Err(invalid()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if fs::read_dir(workspace)?.next().is_some() {
                    return Err(invalid());
                }
                let mut file = private_open(&workspace_marker, true)?;
                file.write_all(identity.as_bytes())?;
                file.sync_all()?;
                crate::sync_dir(workspace)?;
            }
            Err(error) => return Err(error),
        }
        Ok(root)
    }
    pub fn open_secretary(root: &Path, run: &str, workspace: &Path) -> io::Result<Self> {
        if identifier(&json!(run)).is_none() {
            return Err(invalid());
        }
        let root = Self::prepare_secretary(root, workspace)?;
        let lock = private_open(&root.join(".secretary-owner.lock"), false)?;
        lock.try_lock().map_err(io::Error::other)?;
        let runs = root.join("runs");
        private_dir(&runs)?;
        let profile = runs.join(run);
        private_dir(&profile)?;
        Self::load(
            profile,
            workspace.canonicalize()?,
            Some(run.to_owned()),
            Some(lock),
        )
    }
    fn load(
        profile: PathBuf,
        workspace: PathBuf,
        secretary_run: Option<String>,
        secretary_lock: Option<File>,
    ) -> io::Result<Self> {
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
                    json!({"text": event["text"].as_str().ok_or_else(invalid)?, "turn":event.get("data").unwrap_or(&Value::Null)}),
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
            secretary_run,
            _secretary_lock: secretary_lock,
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
                if self.secretary_run.is_some() {
                    if ["request", "response", "tool_boundary"].contains(&kind) {
                        return false;
                    }
                    if kind == "session" {
                        let count = detail.entry((run, kind)).or_default();
                        *count += 1;
                        return *count == 1;
                    }
                }
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
        let text_limit = if self.secretary_run.is_some() {
            EVENT_BYTES - 4096
        } else {
            16000
        };
        let Some(text) = request["text"]
            .as_str()
            .filter(|t| !t.trim().is_empty() && t.len() <= text_limit)
        else {
            return Ok((json!({"error":"invalid-text"}), None));
        };
        if self
            .secretary_run
            .as_deref()
            .is_some_and(|expected| expected != run)
        {
            return Ok((json!({"error":"invalid-run"}), None));
        }
        let turn = if self.secretary_run.is_some() {
            match validated_turn(&request["turn"]) {
                Some(turn) => turn,
                None => return Ok((json!({"error":"invalid-turn"}), None)),
            }
        } else {
            Value::Null
        };
        let admission = json!({"text":text,"turn":turn});
        if let Some(original) = self.runs.get(run) {
            return Ok((
                if original == &admission {
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
        let encoded = serde_json::to_vec(text).map_err(io::Error::other)?.len();
        if encoded > EVENT_BYTES - 1024 {
            return Ok((json!({"error":"invalid-text"}), None));
        }
        // Text and attachment metadata share one accepted record. Leave room for the
        // bounded record envelope and refuse before persistence or worker admission.
        if serde_json::to_vec(&admission).map_err(io::Error::other)?.len() > EVENT_BYTES - 1024 {
            return Ok((json!({"error":"invalid-turn"}), None));
        }
        // Reserve an accepted event, full terminal/partial text, bounded activity and controls.
        // Refuse before admission rather than lose a retained message or exceed the UI pipe.
        let retained = serde_json::to_vec(&self.snapshot())
            .map_err(io::Error::other)?
            .len();
        if retained + encoded + 2 * EVENT_BYTES + 16 * 1024 > FRAME_BYTES as usize - 16 * 1024 {
            return Ok((json!({"error":"profile-size-limit"}), None));
        }
        let event = self.record(
            run,
            "accepted",
            Some(text),
            if turn.is_null() { None } else { Some(turn) },
        )?;
        self.runs.insert(run.to_owned(), admission);
        self.active = Some(run.to_owned());
        Ok((
            json!({"accepted":true,"runId":run,"replayed":false}),
            Some(event),
        ))
    }
    /// Journal the exact change before it can cross the worker pipe. A repeated ID
    /// is evidence to reconcile, never permission to send the change a second time.
    pub fn steer(&mut self, request: &Value) -> io::Result<(Value, Option<Value>)> {
        let Some(run) = identifier(&request["runId"]) else {
            return Ok((json!({"submitted":false}), None));
        };
        let Some(delivery) = identifier(&request["deliveryId"]) else {
            return Ok((json!({"submitted":false}), None));
        };
        let Some(text) = request["text"]
            .as_str()
            .filter(|t| !t.trim().is_empty() && t.len() <= 16000)
        else {
            return Ok((json!({"submitted":false}), None));
        };
        let Some(files) = validated_turn(&json!({"attachments":request["attachments"]})) else {
            return Ok((json!({"submitted":false}), None));
        };
        let data = json!({"deliveryId":delivery,"attachments":files["attachments"]});
        if let Some(original) = self
            .events
            .iter()
            .find(|e| e["kind"] == "steer_requested" && e["data"]["deliveryId"] == delivery)
        {
            return Ok((
                if original["runId"] == run && original["text"] == text && original["data"] == data
                {
                    json!({"submitted":true,"replayed":true})
                } else {
                    json!({"error":"conflicting-steer"})
                },
                None,
            ));
        }
        if self.secretary_run.as_deref() != Some(run)
            || self.active.as_deref() != Some(run)
            || self.events.iter().any(|e| e["kind"] == "stop_requested")
            || self
                .events
                .iter()
                .filter(|e| e["kind"] == "steer_requested")
                .count()
                >= 16
        {
            return Ok((json!({"submitted":false}), None));
        }
        let retained = serde_json::to_vec(&self.snapshot())
            .map_err(io::Error::other)?
            .len();
        if retained + serde_json::to_vec(request).map_err(io::Error::other)?.len() + 3 * EVENT_BYTES
            > FRAME_BYTES as usize - 16 * 1024
        {
            return Ok((json!({"submitted":false}), None));
        }
        let event = self.record(run, "steer_requested", Some(text), Some(data))?;
        Ok((json!({"submitted":true,"replayed":false}), Some(event)))
    }

    pub fn accepts_steer_result(&self, run: &str, packet: &Value) -> bool {
        let delivery = &packet["data"]["deliveryId"];
        self.secretary_run.as_deref() == Some(run)
            && (packet["data"]["accepted"].is_boolean() || packet["data"]["accepted"].is_null())
            && self.events.iter().any(|e| {
                e["kind"] == "steer_requested"
                    && e["runId"] == run
                    && &e["data"]["deliveryId"] == delivery
            })
            && !self
                .events
                .iter()
                .any(|e| e["kind"] == "steer_result" && &e["data"]["deliveryId"] == delivery)
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

/// Bound the data crossing the subprocess boundary. Permissions are never accepted here.
fn validated_turn(value: &Value) -> Option<Value> {
    let object = value.as_object()?;
    if object.keys().any(|key| {
        !["sessionId", "model", "effort", "attachments", "skill", "secretaryCoordinator"].contains(&key.as_str())
    }) {
        return None;
    }
    if object.get("secretaryCoordinator").is_some_and(|value| value != &json!(true)) {
        return None;
    }
    for key in ["sessionId", "model", "effort"] {
        if let Some(value) = object.get(key) {
            let text = value.as_str()?;
            if text.is_empty() || text.len() > 256 || text.chars().any(char::is_control) {
                return None;
            }
        }
    }
    if let Some(effort) = object.get("effort") {
        if ![
            "none",
            "minimal",
            "low",
            "medium",
            "high",
            "xhigh",
            "max",
            "ultra",
            "persistent",
        ]
        .contains(&effort.as_str()?)
        {
            return None;
        }
    }
    if let Some(files) = object.get("attachments") {
        let files = files.as_array()?;
        if files.len() > 32 {
            return None;
        }
        for file in files {
            for key in ["name", "mime", "path"] {
                let text = file.get(key)?.as_str()?;
                if text.is_empty() || text.len() > 4096 || text.contains('\0') {
                    return None;
                }
            }
            if !Path::new(file["path"].as_str()?).is_absolute() {
                return None;
            }
        }
    }
    if let Some(skill) = object.get("skill") {
        let name = skill.get("name")?.as_str()?;
        let path = skill.get("path")?.as_str()?;
        if name.is_empty()
            || name.len() > 256
            || path.len() > 4096
            || !Path::new(path).is_absolute()
        {
            return None;
        }
    }
    if serde_json::to_vec(value).ok()?.len() > 16 * 1024 {
        return None;
    }
    Some(value.clone())
}
