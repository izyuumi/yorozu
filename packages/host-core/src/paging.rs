//! Read-only retained JSONL paging. Cursors preserve the released decoded-prefix contract.
use crate::invalid_id;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
const LOG_BYTES: u64 = 1024 * 1024 * 1024;
const LINE_BYTES: u64 = 32 * 1024 * 1024 + 1;
const INDEX_BYTES: usize = 4 * 1024 * 1024;
const PAGE_BYTES: usize = 512 * 1024;
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
#[derive(Clone, PartialEq)]
struct Stamp {
    length: u64,
    #[cfg(unix)]
    identity: (u64, u64, i64, i64, i64, i64),
}
impl Stamp {
    fn new(meta: &Metadata) -> Self {
        Self {
            length: meta.len(),
            #[cfg(unix)]
            identity: {
                use std::os::unix::fs::MetadataExt;
                (
                    meta.dev(),
                    meta.ino(),
                    meta.mtime(),
                    meta.mtime_nsec(),
                    meta.ctime(),
                    meta.ctime_nsec(),
                )
            },
        }
    }
}
struct Index {
    stamp: Stamp,
    after: HashMap<String, u64>,
    cursors: HashMap<u64, String>,
}
struct Continuation {
    stamp: Stamp,
    offset: u64,
    prefix: Sha256,
}
#[derive(Default)]
pub struct Paging {
    indexes: HashMap<PathBuf, Index>,
    recent: VecDeque<PathBuf>,
    continuations: HashMap<PathBuf, VecDeque<Continuation>>,
}
fn open(path: &Path) -> io::Result<File> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
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
    if !file.metadata()?.is_file()
        || file.metadata()?.len() > LOG_BYTES
        || Stamp::new(&metadata) != Stamp::new(&file.metadata()?)
    {
        return Err(invalid());
    }
    Ok(file)
}
// Offsets count physical bytes. Node hashes decoded UTF-8 re-encoded with a synthetic newline,
// including broken lines and a successfully parsed unterminated final line.
fn line(
    reader: &mut BufReader<&mut File>,
    end: &mut u64,
    length: u64,
) -> io::Result<Option<String>> {
    if *end >= length {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    let read = Read::by_ref(reader)
        .take(LINE_BYTES + 1)
        .read_until(b'\n', &mut bytes)?;
    if read == 0 {
        return Ok(None);
    }
    if read as u64 > LINE_BYTES {
        return Err(invalid());
    }
    *end += read as u64;
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}
pub(crate) fn unsupported_legacy(error: &serde_json::Error) -> bool {
    let reason = error.to_string();
    reason.contains("surrogate")
        || reason.contains("unexpected end of hex escape")
        || reason.contains("invalid unicode code point")
        || reason.contains("number out of range")
}
fn parse(text: &str) -> io::Result<Option<Value>> {
    match serde_json::from_str::<Value>(text) {
        Ok(event) => Ok((event["id"].is_string() && event["ts"].is_number()).then_some(event)),
        Err(error) => {
            // These legacy values are accepted by JS but cannot be represented by this parser.
            // Refuse the query explicitly, preserving the file instead of silently dropping rows.
            if unsupported_legacy(&error) {
                return Err(invalid());
            }
            Ok(None)
        }
    }
}
fn hash(prefix: &Sha256) -> String {
    URL_SAFE_NO_PAD.encode(prefix.clone().finalize())
}
fn occurrence(cursor: Option<&str>) -> Option<(u64, &str)> {
    let (offset, tag) = cursor?.strip_prefix("sync:")?.split_once(':')?;
    if offset.is_empty()
        || !offset.bytes().all(|b| b.is_ascii_digit())
        || tag.len() != 43
        || !tag
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return None;
    }
    Some((offset.parse().ok()?, tag))
}
/// Read the retained execution evidence with the same bounds/parser contract as replay paging.
// A bounded raw prefix proves progress belongs after this process's issued claim.
// Unlike paging cursors, it hashes physical bytes and is never exposed to the worker.
#[derive(Clone)]
pub(crate) struct ProgressAnchor {
    offset: u64,
    raw_hash: String,
    #[cfg(unix)]
    identity: (u64, u64),
}
fn raw_prefix(file: &mut File, length: u64) -> io::Result<String> {
    file.seek(SeekFrom::Start(0))?;
    let mut reader = Read::by_ref(file).take(length);
    let mut sha = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut read = 0;
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        sha.update(&buffer[..count]);
        read += count as u64;
    }
    if read != length {
        return Err(invalid());
    }
    Ok(hash(&sha))
}
fn unchanged(path: &Path, file: &File, stamp: &Stamp) -> io::Result<()> {
    let current = fs::symlink_metadata(path)?;
    if current.file_type().is_symlink()
        || !current.is_file()
        || Stamp::new(&current) != *stamp
        || Stamp::new(&file.metadata()?) != *stamp
    {
        return Err(invalid());
    }
    Ok(())
}
impl ProgressAnchor {
    pub(crate) fn capture(root: &Path, thread: &str) -> io::Result<Self> {
        let path = root
            .join("threads")
            .join(format!("{}.jsonl", crate::thread_index::file_name(thread)));
        let mut file = open(&path)?;
        let stamp = Stamp::new(&file.metadata()?);
        let raw_hash = raw_prefix(&mut file, stamp.length)?;
        unchanged(&path, &file, &stamp)?;
        Ok(Self {
            offset: stamp.length,
            raw_hash,
            #[cfg(unix)]
            identity: (stamp.identity.0, stamp.identity.1),
        })
    }
    pub(crate) fn advance(
        &self,
        root: &Path,
        thread: &str,
        activity: &str,
    ) -> io::Result<Option<Self>> {
        let path = root
            .join("threads")
            .join(format!("{}.jsonl", crate::thread_index::file_name(thread)));
        let mut file = open(&path)?;
        let stamp = Stamp::new(&file.metadata()?);
        #[cfg(unix)]
        if self.identity != (stamp.identity.0, stamp.identity.1) {
            return Err(invalid());
        }
        if stamp.length < self.offset || raw_prefix(&mut file, self.offset)? != self.raw_hash {
            return Err(invalid());
        }
        file.seek(SeekFrom::Start(0))?;
        let mut end = 0;
        let mut candidate = None;
        {
            let mut reader = BufReader::new(&mut file);
            while end < stamp.length {
                let start = end;
                if let Some(text) = line(&mut reader, &mut end, stamp.length)?
                    && let Some(event) = parse(&text)?
                    && event["id"] == activity
                    && event["threadId"] == thread
                    && event["agentId"] == "main"
                    && event["kind"] == "tool_result"
                    && event["data"]["ok"] == true
                {
                    // Only the first successful occurrence can count. Re-appending an old
                    // success with a fresh physical offset cannot replenish the budget.
                    if start >= self.offset {
                        candidate = Some(end);
                    }
                    break;
                }
            }
        }
        let next = if let Some(offset) = candidate {
            Some(Self {
                offset,
                raw_hash: raw_prefix(&mut file, offset)?,
                #[cfg(unix)]
                identity: self.identity,
            })
        } else {
            None
        };
        if raw_prefix(&mut file, self.offset)? != self.raw_hash {
            return Err(invalid());
        }
        unchanged(&path, &file, &stamp)?;
        Ok(next)
    }
}
pub(crate) fn boot_evidence(
    root: &Path,
    thread: &str,
    origin: Option<&str>,
    completion: &str,
) -> io::Result<(bool, bool, bool, bool)> {
    let path = root
        .join("threads")
        .join(format!("{}.jsonl", crate::thread_index::file_name(thread)));
    let mut file = match open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok((false, false, false, false));
        }
        Err(error) => return Err(error),
    };
    let stamp = Stamp::new(&file.metadata()?);
    let mut end = 0;
    let (mut seen, mut finished, mut hidden_origin, mut hidden_final) =
        (false, false, false, false);
    {
        let mut reader = BufReader::new(&mut file);
        while let Some(text) = line(&mut reader, &mut end, stamp.length)? {
            let Some(event) = parse(&text)? else {
                continue;
            };
            if event["threadId"] != thread {
                continue;
            }
            seen |= origin.is_some_and(|id| event["id"] == id)
                && event["kind"] == "message"
                && event["data"]["role"] == "user";
            finished |= !completion.is_empty()
                && event["id"] == completion
                && event["kind"] == "message"
                && event["data"]["role"] == "agent"
                && event["data"]["done"] == true;
            if event["kind"] == "thread_rewound"
                && event["data"].get("reason").is_none()
                && event["data"]["requestId"].is_string()
                && event["data"]["eventId"].is_string()
                && let Some(hidden) = event["data"]["hiddenEventIds"].as_array()
            {
                hidden_origin |= origin.is_some_and(|id| hidden.iter().any(|value| value == id));
                hidden_final |= hidden.iter().any(|value| value == completion);
            }
        }
    }
    unchanged(&path, &file, &stamp)?;
    Ok((seen, finished, hidden_origin, hidden_final))
}
pub(crate) fn run_evidence(
    root: &Path,
    thread: &str,
    accepted: &Value,
    completion: &str,
) -> io::Result<(bool, bool)> {
    let origin = accepted["id"].as_str().ok_or_else(invalid)?;
    let expected =
        crate::accepted::fingerprint(accepted, &accepted["event"]).ok_or_else(invalid)?;
    let path = root
        .join("threads")
        .join(format!("{}.jsonl", crate::thread_index::file_name(thread)));
    let mut file = match open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok((false, false)),
        Err(error) => return Err(error),
    };
    let stamp = Stamp::new(&file.metadata()?);
    let mut end = 0;
    let mut seen = false;
    let mut finished = false;
    {
        let mut reader = BufReader::new(&mut file);
        while let Some(text) = line(&mut reader, &mut end, stamp.length)? {
            if let Some(event) = parse(&text)? {
                if event["id"] == origin
                    && event["threadId"] == thread
                    && event["kind"] == "message"
                    && event["data"]["role"] == "user"
                {
                    if crate::accepted::fingerprint(accepted, &event).as_ref() != Some(&expected) {
                        return Err(invalid());
                    }
                    seen = true;
                }
                finished |= event["id"] == completion
                    && event["threadId"] == thread
                    && event["kind"] == "message"
                    && event["data"]["role"] == "agent"
                    && event["data"]["done"] == true;
            }
        }
    }
    let current = fs::symlink_metadata(&path)?;
    if current.file_type().is_symlink()
        || !current.is_file()
        || Stamp::new(&current) != stamp
        || Stamp::new(&file.metadata()?) != stamp
    {
        return Err(invalid());
    }
    Ok((seen, finished))
}
impl Paging {
    fn page(&mut self, root: &Path, request: &Value) -> io::Result<Value> {
        let id = request["threadId"]
            .as_str()
            .filter(|id| !invalid_id(id))
            .ok_or_else(invalid)?;
        let after = request.get("after").and_then(Value::as_str);
        if request.get("after").is_some_and(|v| !v.is_string()) {
            return Err(invalid());
        }
        let min = request["minTs"]
            .as_f64()
            .filter(|n| n.is_finite())
            .ok_or_else(invalid)?;
        let include = request["includeApprovalStatus"]
            .as_bool()
            .ok_or_else(invalid)?;
        let path = root
            .join("threads")
            .join(format!("{}.jsonl", crate::thread_index::file_name(id)));
        let mut file = match open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                self.indexes.remove(&path);
                self.continuations.remove(&path);
                self.recent.retain(|p| p != &path);
                return Ok(json!({"events":[],"more":false}));
            }
            Err(error) => return Err(error),
        };
        let stamp = Stamp::new(&file.metadata()?);
        // Register before any cache publication: read failures must also obey the LRU cap.
        self.recent.retain(|known| known != &path);
        self.recent.push_back(path.clone());
        while self.recent.len() > 16 {
            if let Some(old) = self.recent.pop_front() {
                self.indexes.remove(&old);
                self.continuations.remove(&old);
            }
        }

        // Equivalent replacement identity is not stable on the supported Windows std surface.
        // Conservatively rebuild there; never trust length alone across same-size replacements.
        #[cfg(not(unix))]
        {
            self.indexes.remove(&path);
            self.continuations.remove(&path);
        }
        if self
            .indexes
            .get(&path)
            .is_some_and(|index| index.stamp != stamp)
        {
            self.indexes.remove(&path);
        }
        if self
            .continuations
            .get(&path)
            .is_some_and(|items| items.iter().any(|item| item.stamp != stamp))
        {
            self.continuations.remove(&path);
        }
        let continuation = occurrence(after).and_then(|(offset, tag)| {
            self.continuations
                .get(&path)?
                .iter()
                .find(|item| item.offset == offset && hash(&item.prefix) == tag)
        });
        let mut prefix = continuation
            .map(|item| item.prefix.clone())
            .unwrap_or_default();
        let mut start = continuation.map(|item| item.offset).unwrap_or(0);
        if !self.indexes.contains_key(&path) && continuation.is_none() {
            let mut index = Some(Index {
                stamp: stamp.clone(),
                after: HashMap::new(),
                cursors: HashMap::new(),
            });
            let mut estimate = 0usize;
            let mut seen = false;
            let mut cursor_start = None;
            let mut rolling = Sha256::new();
            let mut end = 0;
            let mut reader = BufReader::new(&mut file);
            while let Some(text) = line(&mut reader, &mut end, stamp.length)? {
                rolling.update(text.as_bytes());
                rolling.update(b"\n");
                let Some(event) = parse(&text)? else {
                    continue;
                };
                let event_id = event["id"].as_str().unwrap();
                let tag = hash(&rolling);
                if after == Some(event_id) && (event.get("clientTs").is_none() || !seen) {
                    start = end;
                    prefix = rolling.clone();
                    seen = true;
                }
                if occurrence(after)
                    .is_some_and(|(offset, expected)| offset == end && expected == tag)
                {
                    cursor_start = Some((end, rolling.clone()));
                }
                estimate = estimate.saturating_add(256).saturating_add(event_id.len());
                if estimate > INDEX_BYTES {
                    index = None;
                }
                if let Some(index) = index.as_mut() {
                    if event.get("clientTs").is_none() || !index.after.contains_key(event_id) {
                        index.after.insert(event_id.into(), end);
                    }
                    index.cursors.insert(end, tag);
                }
            }
            if let Some((offset, sha)) = cursor_start {
                start = offset;
                prefix = sha;
            }
            if let Some(index) = index {
                self.indexes.insert(path.clone(), index);
            }
        }
        let index = self.indexes.get(&path);
        if let Some(index) = index {
            start = occurrence(after)
                .filter(|(offset, tag)| index.cursors.get(offset).is_some_and(|known| known == tag))
                .map(|(offset, _)| offset)
                .unwrap_or_else(|| {
                    after
                        .and_then(|id| index.after.get(id).copied())
                        .unwrap_or(0)
                });
        }
        file.seek(SeekFrom::Start(start))?;
        let mut reader = BufReader::new(&mut file);
        let mut end = start;
        let mut events = Vec::new();
        let mut bytes = 2usize;
        let mut more = false;
        let mut points = VecDeque::new();
        while let Some(text) = line(&mut reader, &mut end, stamp.length)? {
            if index.is_none() {
                prefix.update(text.as_bytes());
                prefix.update(b"\n");
            }
            let Some(mut event) = parse(&text)? else {
                continue;
            };
            if event["ts"].as_f64().ok_or_else(invalid)? < min
                || (!include && event["kind"] == "approval_status")
            {
                continue;
            }
            let tag = if let Some(index) = index {
                index.cursors.get(&end).ok_or_else(invalid)?.clone()
            } else {
                hash(&prefix)
            };
            event["syncCursor"] = json!(format!("sync:{end}:{tag}"));
            let size = serde_json::to_vec(&event).map_err(io::Error::other)?.len()
                + usize::from(!events.is_empty());
            if events.len() == 200 || (!events.is_empty() && bytes + size > PAGE_BYTES) {
                more = true;
                break;
            }
            bytes += size;
            if index.is_none() {
                points.push_back(Continuation {
                    stamp: stamp.clone(),
                    offset: end,
                    prefix: prefix.clone(),
                });
            }
            events.push(event);
        }
        // Keep the released conservative full-page signal, even if the next query is empty.
        more |= events.len() == 200;
        if file.metadata()?.len() != stamp.length || Stamp::new(&file.metadata()?) != stamp {
            return Err(invalid());
        }
        if !points.is_empty() {
            // ponytail: recent returned offsets retain seeking after the full-index cap,
            // including pages truncated by a phone budget; older cursors scan bounded memory.
            let retained = self.continuations.entry(path.clone()).or_default();
            for point in points {
                retained.retain(|known| known.offset != point.offset);
                retained.push_back(point);
            }
            while retained.len() > 256 {
                retained.pop_front();
            }
        }
        Ok(json!({"events":events,"more":more}))
    }
    pub fn request(&mut self, root: &Path, request: &Value) -> Value {
        self.page(root, request)
            .unwrap_or_else(|_: io::Error| json!({"error":"history-page-unconfirmed"}))
    }
}
