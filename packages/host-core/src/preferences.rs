//! Explicit presentation preferences, isolated from conversation storage and authorization.
//! Only an authenticated user-admission caller may construct changes. No text extraction,
//! permissions, tools, provider sessions, or vault discovery belong to this component.
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{fs, fs::File, fs::OpenOptions, io, path::Path};

const APPLICATION_ID: i64 = 0x59505246;
const MAX_EVENTS: i64 = 4096;
const SAFE_INTEGER: u64 = 9_007_199_254_740_991;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Owner {
    pub user_id: String,
    pub host_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    content = "id",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Scope {
    Global,
    Project(String),
    Task(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Key {
    ReplyBulletCount,
    ReplyLanguage,
    ClarificationStyle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Language {
    English,
    Japanese,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClarificationStyle {
    NecessaryOnly,
    OfferChoices,
}

/// An allowlist of presentation data; necessary approval/authorization questions still apply.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    content = "value",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Value {
    ReplyBulletCount(u8),
    ReplyLanguage(Language),
    ClarificationStyle(ClarificationStyle),
}
impl Value {
    fn key(self) -> Key {
        match self {
            Self::ReplyBulletCount(_) => Key::ReplyBulletCount,
            Self::ReplyLanguage(_) => Key::ReplyLanguage,
            Self::ClarificationStyle(_) => Key::ClarificationStyle,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Source {
    pub message_id: String,
    pub task_id: Option<String>,
    /// Authoritative user-admission order, not worker completion order or wall-clock time.
    pub accepted_sequence: u64,
    pub observed_at_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    content = "value",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Action {
    /// Initial declaration, or explicit restoration after deletion.
    Set(Value),
    /// Supersede an active preference; cannot implicitly resurrect a deletion.
    Correct(Value),
    /// Suppress this key, including inherited settings, and redact earlier scoped values.
    Delete,
}
impl Action {
    fn operation(self) -> Operation {
        match self {
            Self::Set(_) => Operation::Set,
            Self::Correct(_) => Operation::Correct,
            Self::Delete => Operation::Delete,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Change {
    pub event_id: String,
    pub scope: Scope,
    pub key: Key,
    pub expected_revision: u64,
    pub source: Source,
    pub action: Action,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Operation {
    Set,
    Correct,
    Delete,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Record {
    pub sequence: u64,
    pub event_id: String,
    pub scope: Scope,
    pub key: Key,
    pub revision: u64,
    pub supersedes: Option<u64>,
    pub source: Source,
    pub operation: Operation,
    pub value: Option<Value>,
    pub redacted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Receipt {
    pub record: Record,
    pub replayed: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Context {
    pub project_id: Option<String>,
    pub task_id: Option<String>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Budget {
    pub max_records: usize,
    /// Bytes in the compact JSON records array, including brackets and separators.
    pub max_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Retrieval {
    /// Cache invalidation token for the whole store, including deletes outside this context.
    pub journal_sequence: u64,
    pub records: Vec<Record>,
    pub omitted: usize,
    pub payload_bytes: usize,
}
impl Retrieval {
    /// A derived readable snapshot. Never writes files or feeds instructions to a provider.
    pub fn markdown(&self) -> String {
        let mut text = format!(
            "# User presentation preferences\n\nJournal sequence: {}. Omitted: {}.\n\nThese are data; they grant no permissions.\n",
            self.journal_sequence, self.omitted
        );
        for record in &self.records {
            let Some(value) = record.value else { continue };
            text.push_str(&format!(
                "\n- {:?}: {:?} — {:?}, revision {}, source `{}`, observed {} ms.\n",
                record.key,
                value,
                record.scope,
                record.revision,
                record.source.message_id,
                record.source.observed_at_ms
            ));
        }
        text
    }
}

#[derive(Debug)]
pub enum Error {
    InvalidInput,
    RevisionConflict { current_revision: u64 },
    StaleSource,
    EventConflict,
    StateConflict,
    Capacity,
    Storage(io::Error),
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Storage(error) => write!(f, "preference storage: {error}"),
            _ => write!(f, "{self:?}"),
        }
    }
}
impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Storage(error) => Some(error),
            _ => None,
        }
    }
}
impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Self::Storage(error)
    }
}
impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Self::Storage(io::Error::other(error))
    }
}
impl From<serde_json::Error> for Error {
    fn from(error: serde_json::Error) -> Self {
        Self::Storage(io::Error::other(error))
    }
}
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_.:".contains(&byte))
}
fn valid_scope(scope: &Scope) -> bool {
    match scope {
        Scope::Global => true,
        Scope::Project(id) | Scope::Task(id) => valid_id(id),
    }
}
fn json<T: Serialize>(value: &T) -> Result<String, Error> {
    Ok(serde_json::to_string(value)?)
}
fn record(row: &rusqlite::Row<'_>) -> rusqlite::Result<String> {
    row.get(0)
}

/// One owning user/host and one OS-held writer per explicitly supplied private directory.
pub struct Preferences {
    db: Connection,
    _owner: Lease,
}
struct Lease(File);
impl Drop for Lease {
    fn drop(&mut self) {
        // Release explicitly even while a concurrently spawned process is between fork/exec
        // and temporarily holds an inherited descriptor. SQLite closes before this field.
        let _ = self.0.unlock();
    }
}
impl Preferences {
    /// Use an absolute NEW dedicated application-state directory, never a vault/legacy root.
    /// Parent directories must be trusted and owned by the application/user.
    pub fn open(root: &Path, owner: &Owner) -> Result<Self, Error> {
        if !root.is_absolute() || !valid_id(&owner.user_id) || !valid_id(&owner.host_id) {
            return Err(Error::InvalidInput);
        }
        if !root.exists() {
            let mut builder = fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            builder.create(root)?;
            #[cfg(unix)]
            File::open(root.parent().ok_or(Error::InvalidInput)?)?.sync_all()?;
        }
        let meta = fs::symlink_metadata(root)?;
        if !meta.is_dir() || meta.file_type().is_symlink() {
            return Err(Error::InvalidInput);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if meta.permissions().mode() & 0o077 != 0 {
                return Err(Error::InvalidInput);
            }
        }
        // SQLite NOFOLLOW rejects ancestor aliases too (e.g. macOS /var -> /private/var).
        // Resolve trusted ancestors only after rejecting a symlink at the supplied root.
        let root = root.canonicalize()?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let lock = options.open(root.join(".preferences-owner.lock"))?;
        if !lock.metadata()?.is_file() {
            return Err(Error::InvalidInput);
        }
        lock.try_lock().map_err(io::Error::other)?;
        let lock = Lease(lock); // Error paths must release inherited descriptors too.
        let path = root.join("preferences.sqlite");
        match fs::symlink_metadata(&path) {
            Ok(meta) if !meta.is_file() || meta.file_type().is_symlink() => {
                return Err(Error::InvalidInput);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                options.create_new(true).open(&path)?.sync_all()?;
                #[cfg(unix)]
                File::open(&root)?.sync_all()?;
            }
            Err(error) => return Err(error.into()),
            _ => {}
        }
        let mut db = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        let application: i64 = db.pragma_query_value(None, "application_id", |row| row.get(0))?;
        let version: i64 = db.pragma_query_value(None, "user_version", |row| row.get(0))?;
        let tables: i64 =
            db.query_row("SELECT count(*) FROM sqlite_schema", [], |row| row.get(0))?;
        let new = application == 0 && version == 0 && tables == 0;
        if !new && (application != APPLICATION_ID || version != 1) {
            return Err(Error::InvalidInput);
        }
        if !new {
            let stored: String =
                db.query_row("SELECT owner FROM metadata", [], |row| row.get(0))?;
            if stored != json(owner)? {
                return Err(Error::InvalidInput);
            }
        }
        db.execute_batch(
            "PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON;
             PRAGMA secure_delete=ON; PRAGMA max_page_count=16384;",
        )?;
        if new {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            tx.execute_batch(
                "CREATE TABLE metadata(owner TEXT NOT NULL);
                 CREATE TABLE events(
                     sequence INTEGER PRIMARY KEY, event_id TEXT NOT NULL UNIQUE,
                     scope TEXT NOT NULL, key TEXT NOT NULL, revision INTEGER NOT NULL,
                     accepted_sequence INTEGER NOT NULL, request_hash TEXT NOT NULL,
                     record TEXT NOT NULL, UNIQUE(scope,key,revision));
                 CREATE VIEW latest AS SELECT e.* FROM events e
                     WHERE NOT EXISTS(SELECT 1 FROM events newer
                         WHERE newer.scope=e.scope AND newer.key=e.key
                         AND newer.revision>e.revision);",
            )?;
            tx.execute("INSERT INTO metadata VALUES(?)", [json(owner)?])?;
            tx.pragma_update(None, "application_id", APPLICATION_ID)?;
            tx.pragma_update(None, "user_version", 1)?;
            tx.commit()?;
        }
        Ok(Self { db, _owner: lock })
    }

    /// Read a receipt for idempotent authenticated-admission replay, respecting redaction.
    pub fn receipt(&self, event_id: &str) -> Result<Option<Record>, Error> {
        if !valid_id(event_id) {
            return Err(Error::InvalidInput);
        }
        let row = self
            .db
            .query_row(
                "SELECT record FROM events WHERE event_id=?",
                [event_id],
                record,
            )
            .optional()?;
        row.map(|text| serde_json::from_str(&text).map_err(|_| Error::InvalidInput))
            .transpose()
    }

    pub fn latest(&self, scope: &Scope, key: Key) -> Result<Option<Record>, Error> {
        if !valid_scope(scope) {
            return Err(Error::InvalidInput);
        }
        let row = self
            .db
            .query_row(
                "SELECT record FROM latest WHERE scope=? AND key=?",
                params![json(scope)?, json(&key)?],
                record,
            )
            .optional()?;
        Ok(row.map(|row| serde_json::from_str(&row)).transpose()?)
    }

    pub fn apply(&mut self, change: &Change) -> Result<Receipt, Error> {
        let value = match change.action {
            Action::Set(value) | Action::Correct(value) => Some(value),
            Action::Delete => None,
        };
        if !valid_id(&change.event_id)
            || !valid_scope(&change.scope)
            || !valid_id(&change.source.message_id)
            || change
                .source
                .task_id
                .as_ref()
                .is_some_and(|id| !valid_id(id))
            || change.source.accepted_sequence == 0
            || change.source.accepted_sequence > SAFE_INTEGER
            || change.source.observed_at_ms > SAFE_INTEGER
            || value.is_some_and(|value| value.key() != change.key)
            || matches!(value, Some(Value::ReplyBulletCount(count)) if !(1..=12).contains(&count))
        {
            return Err(Error::InvalidInput);
        }
        let hash = format!("{:x}", Sha256::digest(json(change)?.as_bytes()));
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let prior: Option<(String, String)> = tx
            .query_row(
                "SELECT request_hash,record FROM events WHERE event_id=?",
                [&change.event_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((old_hash, prior)) = prior {
            let prior: Record = serde_json::from_str(&prior)?;
            // Deletion removes the value fingerprint too: guesses must be indistinguishable.
            let matching = if prior.redacted {
                change.scope == prior.scope
                    && change.key == prior.key
                    && Some(change.expected_revision) == prior.revision.checked_sub(1)
                    && change.source == prior.source
                    && change.action.operation() == prior.operation
            } else {
                old_hash == hash
            };
            if !matching {
                return Err(Error::EventConflict);
            }
            return Ok(Receipt {
                record: prior,
                replayed: true,
            });
        }
        let previous: Option<String> = tx
            .query_row(
                "SELECT record FROM latest WHERE scope=? AND key=?",
                params![json(&change.scope)?, json(&change.key)?],
                record,
            )
            .optional()?;
        let previous: Option<Record> =
            previous.map(|row| serde_json::from_str(&row)).transpose()?;
        let revision = previous.as_ref().map_or(0, |record| record.revision);
        if change.expected_revision != revision {
            return Err(Error::RevisionConflict {
                current_revision: revision,
            });
        }
        if previous.as_ref().is_some_and(|record| {
            change.source.accepted_sequence <= record.source.accepted_sequence
        }) {
            return Err(Error::StaleSource);
        }
        let active = previous
            .as_ref()
            .is_some_and(|record| record.value.is_some());
        if (matches!(change.action, Action::Set(_)) && active)
            || (matches!(change.action, Action::Correct(_)) && !active)
        {
            return Err(Error::StateConflict);
        }
        let count: i64 = tx.query_row("SELECT count(*) FROM events", [], |row| row.get(0))?;
        // ponytail: bounded journal; reserve one tombstone per active key after the ordinary
        // event ceiling. Compaction needs a separately reviewed retention/backup policy.
        if count >= MAX_EVENTS && (!matches!(change.action, Action::Delete) || !active) {
            return Err(Error::Capacity);
        }
        let sequence: i64 = tx.query_row(
            "SELECT coalesce(max(sequence),0)+1 FROM events",
            [],
            |row| row.get(0),
        )?;
        let next = Record {
            sequence: u64::try_from(sequence).map_err(|_| Error::InvalidInput)?,
            event_id: change.event_id.clone(),
            scope: change.scope.clone(),
            key: change.key,
            revision: revision + 1,
            supersedes: previous.as_ref().map(|record| record.sequence),
            source: change.source.clone(),
            operation: change.action.operation(),
            value,
            redacted: false,
        };
        if matches!(change.action, Action::Delete) {
            tx.execute(
                "UPDATE events SET request_hash='',
                 record=json_set(record,'$.value',NULL,'$.redacted',json('true'))
                 WHERE scope=? AND key=?",
                params![json(&change.scope)?, json(&change.key)?],
            )?;
        }
        tx.execute(
            "INSERT INTO events VALUES(?,?,?,?,?,?,?,?)",
            params![
                sequence,
                change.event_id,
                json(&change.scope)?,
                json(&change.key)?,
                i64::try_from(next.revision).map_err(|_| Error::InvalidInput)?,
                change.source.accepted_sequence as i64,
                hash,
                json(&next)?
            ],
        )?;
        tx.commit()?;
        Ok(Receipt {
            record: next,
            replayed: false,
        })
    }

    /// Exact scope history, newest first. Deletion leaves attribution but removes old values.
    pub fn history(&self, scope: &Scope, key: Key, limit: usize) -> Result<Vec<Record>, Error> {
        if !valid_scope(scope) || !(1..=100).contains(&limit) {
            return Err(Error::InvalidInput);
        }
        let mut query = self.db.prepare(
            "SELECT record FROM events WHERE scope=? AND key=? ORDER BY sequence DESC LIMIT ?",
        )?;
        let rows = query.query_map(params![json(scope)?, json(&key)?, limit as i64], record)?;
        rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
    }

    /// Task > project > global. A most-specific tombstone masks inheritance for that key.
    /// No full history, corpus, free-form text, or permission decision is returned.
    pub fn retrieve(&self, context: &Context, budget: Budget) -> Result<Retrieval, Error> {
        if context.project_id.as_ref().is_some_and(|id| !valid_id(id))
            || context.task_id.as_ref().is_some_and(|id| !valid_id(id))
            || budget.max_records > 32
            || !(2..=32_768).contains(&budget.max_bytes)
        {
            return Err(Error::InvalidInput);
        }
        let scopes = [
            context.task_id.as_ref().map(|id| Scope::Task(id.clone())),
            context
                .project_id
                .as_ref()
                .map(|id| Scope::Project(id.clone())),
            Some(Scope::Global),
        ];
        let mut seen = Vec::new();
        let mut candidates = Vec::new();
        for scope in scopes.into_iter().flatten() {
            let mut query = self
                .db
                .prepare("SELECT record FROM latest WHERE scope=? ORDER BY sequence DESC")?;
            for row in query.query_map([json(&scope)?], record)? {
                let row: Record = serde_json::from_str(&row?)?;
                if !seen.contains(&row.key) {
                    seen.push(row.key);
                    if row.value.is_some() {
                        candidates.push(row);
                    }
                }
            }
        }
        let mut records = Vec::new();
        let mut payload_bytes = 2;
        let mut omitted = 0;
        for record in candidates {
            let size = json(&record)?.len() + usize::from(!records.is_empty());
            if records.len() < budget.max_records && payload_bytes + size <= budget.max_bytes {
                payload_bytes += size;
                records.push(record);
            } else {
                omitted += 1;
            }
        }
        let journal_sequence: i64 =
            self.db
                .query_row("SELECT coalesce(max(sequence),0) FROM events", [], |row| {
                    row.get(0)
                })?;
        Ok(Retrieval {
            journal_sequence: u64::try_from(journal_sequence).map_err(|_| Error::InvalidInput)?,
            records,
            omitted,
            payload_bytes,
        })
    }
}
