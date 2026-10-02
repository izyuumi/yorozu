//! Offline import-review candidates. Runtime authority remains with the legacy Root writer.
use crate::{digest, history::History, private_dir, private_open, sync_dir};
use rand_core::{OsRng, RngCore};
use rusqlite::{Connection, OpenFlags, params};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, BufRead, BufReader, Read};
use std::path::Path;

const FILE_BYTES: u64 = 1024 * 1024 * 1024;
const TOTAL_BYTES: u64 = 16 * FILE_BYTES;
const FILES: usize = 262_144;
const ROWS: u64 = 4_194_304;
const LINE_BYTES: u64 = 32 * 1024 * 1024;
const OWNERS: &[&str] = &[
    ".rust-history-owner.lock",
    ".rust-thread-index-owner.lock",
    ".rust-accepted-owner.lock",
    ".rust-native-queue-owner.lock",
    ".rust-stop-owner.lock",
    ".rust-steering-owner.lock",
    ".rust-admission-owner.lock",
    ".rust-channel-owner.lock",
];
const TREES: &[&str] = &[
    ".rust-history",
    "threads",
    "transcripts",
    "accepted-messages",
    ".thread-index-recovery",
    ".rust-native-queue-recovery",
];
const FILE_NAMES: &[&str] = &[
    "threads.json",
    "threads.json.tmp",
    "native-turn-queue.json",
    "native-turn-queue.json.tmp",
    "stopped-turns.jsonl",
    "native-steering.jsonl",
    "expired-admissions.jsonl",
    "channel-outbox.json",
    "channel-model-delivery.json",
    "channel-cancelled.json",
    "channel-model-original.json",
    "approval.json",
    "approvals.jsonl",
];
const PREFIXES: &[&str] = &[
    ".thread-index-pending.",
    ".native-queue-pending.",
    ".outbox.",
    ".stopped-turns-recovery.",
    ".native-steering-recovery.",
    ".expired-admissions-recovery.",
];
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
fn sql<T>(value: rusqlite::Result<T>) -> io::Result<T> {
    value.map_err(io::Error::other)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct Stamp {
    length: u64,
    modified: Option<std::time::SystemTime>,
    #[cfg(unix)]
    dev: u64,
    #[cfg(unix)]
    ino: u64,
    #[cfg(unix)]
    ctime: i64,
    #[cfg(unix)]
    ctime_ns: i64,
}
fn stamp(meta: &Metadata) -> Stamp {
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;
    Stamp {
        length: meta.len(),
        modified: meta.modified().ok(),
        #[cfg(unix)]
        dev: meta.dev(),
        #[cfg(unix)]
        ino: meta.ino(),
        #[cfg(unix)]
        ctime: meta.ctime(),
        #[cfg(unix)]
        ctime_ns: meta.ctime_nsec(),
    }
}
fn regular(path: &Path, limit: u64) -> io::Result<File> {
    let before = fs::symlink_metadata(path)?;
    if !before.is_file() || before.file_type().is_symlink() || before.len() > limit {
        return Err(invalid());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() || stamp(&before) != stamp(&file.metadata()?) {
        return Err(invalid());
    }
    Ok(file)
}
fn hash(path: &Path, limit: u64) -> io::Result<String> {
    let mut file = regular(path, limit)?;
    let before = stamp(&file.metadata()?);
    let mut sha = Sha256::new();
    let mut length = 0u64;
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        length += count as u64;
        if length > limit {
            return Err(invalid());
        }
        sha.update(&buffer[..count]);
    }
    if length != before.length
        || stamp(&file.metadata()?) != before
        || stamp(&fs::symlink_metadata(path)?) != before
    {
        return Err(invalid());
    }
    Ok(format!("{:x}", sha.finalize()))
}
struct Leases(Vec<File>);
impl Drop for Leases {
    fn drop(&mut self) {
        for file in self.0.iter().rev() {
            let _ = file.unlock();
        }
    }
}
fn leases(root: &Path) -> io::Result<Leases> {
    let mut held = Leases(Vec::new());
    for name in OWNERS {
        let path = root.join(name);
        match fs::symlink_metadata(&path) {
            Ok(meta) if !meta.is_file() || meta.file_type().is_symlink() => return Err(invalid()),
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            _ => {}
        }
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        let file = options.open(&path)?;
        if !file.metadata()?.is_file()
            || stamp(&fs::symlink_metadata(&path)?) != stamp(&file.metadata()?)
        {
            return Err(invalid());
        }
        file.try_lock().map_err(io::Error::other)?;
        held.0.push(file);
    }
    Ok(held)
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct Source {
    path: String,
    kind: String,
    bytes: u64,
    sha256: Option<String>,
    identity: Stamp,
}
fn selected(name: &str) -> bool {
    TREES.contains(&name)
        || FILE_NAMES.contains(&name)
        || PREFIXES.iter().any(|prefix| name.starts_with(prefix))
}
fn walk(
    root: &Path,
    path: &Path,
    entries: &mut Vec<Source>,
    total: &mut u64,
    depth: u8,
) -> io::Result<()> {
    if entries.len() >= FILES || depth > 32 {
        return Err(invalid());
    }
    let meta = fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() || !(meta.is_file() || meta.is_dir()) {
        return Err(invalid());
    }
    let relative = path
        .strip_prefix(root)
        .map_err(io::Error::other)?
        .components()
        .map(|part| part.as_os_str().to_str().ok_or_else(invalid))
        .collect::<io::Result<Vec<_>>>()?
        .join("/");
    let before = stamp(&meta);
    if meta.is_dir() {
        entries.push(Source {
            path: relative,
            kind: "directory".into(),
            bytes: 0,
            sha256: None,
            identity: before.clone(),
        });
        for item in fs::read_dir(path)? {
            walk(root, &item?.path(), entries, total, depth + 1)?;
        }
    } else {
        *total = total
            .checked_add(meta.len())
            .filter(|n| *n <= TOTAL_BYTES)
            .ok_or_else(invalid)?;
        entries.push(Source {
            path: relative,
            kind: "file".into(),
            bytes: meta.len(),
            sha256: Some(hash(path, FILE_BYTES)?),
            identity: before.clone(),
        });
    }
    if stamp(&fs::symlink_metadata(path)?) != before {
        return Err(invalid());
    }
    Ok(())
}
fn inventory(root: &Path) -> io::Result<Vec<Source>> {
    let mut entries = Vec::new();
    let mut total = 0;
    for item in fs::read_dir(root)? {
        let item = item?;
        let name = item.file_name().into_string().map_err(|_| invalid())?;
        if selected(&name) {
            walk(root, &item.path(), &mut entries, &mut total, 0)?;
        }
    }
    entries.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(entries)
}
fn clone_sources(root: &Path, target: &Path, entries: &[Source]) -> io::Result<()> {
    for entry in entries {
        let dest = target.join(&entry.path);
        if entry.kind == "directory" {
            private_dir(&dest)?;
            sync_dir(&dest)?;
            sync_dir(dest.parent().ok_or_else(invalid)?)?;
            continue;
        }
        private_dir(dest.parent().ok_or_else(invalid)?)?;
        let mut input = regular(&root.join(&entry.path), FILE_BYTES)?;
        if stamp(&input.metadata()?) != entry.identity {
            return Err(invalid());
        }
        let mut output = private_open(&dest, true)?;
        if io::copy(
            &mut Read::by_ref(&mut input).take(entry.bytes + 1),
            &mut output,
        )? != entry.bytes
        {
            return Err(invalid());
        }
        output.sync_all()?;
        if hash(&dest, FILE_BYTES)?.as_str() != entry.sha256.as_deref().ok_or_else(invalid)? {
            return Err(invalid());
        }
        sync_dir(dest.parent().ok_or_else(invalid)?)?;
    }
    Ok(())
}
fn log_path(path: &str) -> bool {
    (path.starts_with("threads/") || path.starts_with("transcripts/"))
        && path.matches('/').count() == 1
        && path.ends_with(".jsonl")
        && !path.split('/').next_back().unwrap().starts_with('.')
}
fn visit_log(
    path: &Path,
    entry: &Source,
    mut visit: impl FnMut(u64, &[u8]) -> io::Result<()>,
) -> io::Result<u64> {
    let file = regular(path, FILE_BYTES)?;
    if stamp(&file.metadata()?) != entry.identity {
        return Err(invalid());
    }
    let mut reader = BufReader::new(file.take(entry.bytes + 1));
    let mut sha = Sha256::new();
    let mut offset = 0;
    let mut rows = 0;
    loop {
        let mut bytes = Vec::new();
        if Read::by_ref(&mut reader)
            .take(LINE_BYTES + 1)
            .read_until(b'\n', &mut bytes)?
            == 0
        {
            break;
        }
        if bytes.len() as u64 > LINE_BYTES || rows >= ROWS {
            return Err(invalid());
        }
        if offset + bytes.len() as u64 > entry.bytes {
            return Err(invalid());
        }
        visit(offset, &bytes)?;
        sha.update(&bytes);
        offset += bytes.len() as u64;
        rows += 1;
    }
    if offset != entry.bytes
        || Some(format!("{:x}", sha.finalize())) != entry.sha256
        || stamp(&reader.get_ref().get_ref().metadata()?) != entry.identity
        || stamp(&fs::symlink_metadata(path)?) != entry.identity
    {
        return Err(invalid());
    }
    Ok(rows)
}
fn store(db: &Connection, root: &Path, phase: &str, entries: &[Source]) -> io::Result<u64> {
    let mut source = sql(db.prepare("INSERT INTO source_entries VALUES(?1,?2,?3,?4,?5)"))?;
    let mut chunk = sql(db.prepare("INSERT INTO source_chunks VALUES(?1,?2,?3,?4)"))?;
    let mut row = sql(db.prepare("INSERT INTO event_occurrences VALUES(?1,?2,?3,?4,?5,?6,?7)"))?;
    let mut rows = 0u64;
    for entry in entries {
        sql(source.execute(params![
            phase,
            entry.path,
            entry.kind,
            entry.bytes as i64,
            entry.sha256
        ]))?;
        if entry.kind != "file" {
            continue;
        }
        let path = root.join(&entry.path);
        let input = regular(&path, FILE_BYTES)?;
        if stamp(&input.metadata()?) != entry.identity {
            return Err(invalid());
        }
        let mut file = input.take(entry.bytes + 1);
        let mut sha = Sha256::new();
        let mut length = 0;
        let mut ordinal = 0;
        let mut buffer = [0; 65536];
        loop {
            let count = file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            length += count as u64;
            if length > entry.bytes {
                return Err(invalid());
            }
            sha.update(&buffer[..count]);
            sql(chunk.execute(params![phase, entry.path, ordinal, &buffer[..count]]))?;
            ordinal += 1;
        }
        if length != entry.bytes
            || Some(format!("{:x}", sha.finalize())) != entry.sha256
            || stamp(&file.get_ref().metadata()?) != entry.identity
            || stamp(&fs::symlink_metadata(&path)?) != entry.identity
        {
            return Err(invalid());
        }
        if phase == "recovered" && log_path(&entry.path) {
            visit_log(&path, entry, |offset, bytes| {
                if rows >= ROWS {
                    return Err(invalid());
                }
                rows += 1;
                let value = serde_json::from_slice::<Value>(bytes).ok();
                let parse = if !bytes.ends_with(b"\n") {
                    "unterminated"
                } else if value.is_some() {
                    "json"
                } else {
                    "malformed"
                };
                sql(row.execute(params![
                    entry.path,
                    offset as i64,
                    bytes,
                    value.as_ref().and_then(|v| v["id"].as_str()),
                    std::str::from_utf8(bytes).ok(),
                    parse,
                    bytes.len() as i64
                ]))?;
                Ok(())
            })?;
            if rows > ROWS {
                return Err(invalid());
            }
        }
    }
    Ok(rows)
}
fn verify(db: &Connection, root: &Path, phase: &str, entries: &[Source]) -> io::Result<u64> {
    let count: i64 = sql(db.query_row(
        "SELECT count(*) FROM source_entries WHERE phase=?1",
        [phase],
        |r| r.get(0),
    ))?;
    if count != entries.len() as i64 {
        return Err(invalid());
    }
    let mut chunks = sql(db.prepare(
        "SELECT ordinal,bytes FROM source_chunks WHERE phase=?1 AND path=?2 ORDER BY ordinal",
    ))?;
    let mut rows = 0;
    for entry in entries {
        let actual: (String, i64, Option<String>) = sql(db.query_row(
            "SELECT kind,bytes,sha256 FROM source_entries WHERE phase=?1 AND path=?2",
            params![phase, entry.path],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        ))?;
        if actual != (entry.kind.clone(), entry.bytes as i64, entry.sha256.clone()) {
            return Err(invalid());
        }
        let mut query = sql(chunks.query(params![phase, entry.path]))?;
        let mut ordinal = 0;
        let mut length = 0;
        let mut sha = Sha256::new();
        while let Some(row) = sql(query.next())? {
            let n: i64 = sql(row.get(0))?;
            let bytes: Vec<u8> = sql(row.get(1))?;
            if n != ordinal || bytes.is_empty() || bytes.len() > 65536 {
                return Err(invalid());
            }
            length += bytes.len() as u64;
            ordinal += 1;
            sha.update(bytes);
        }
        if length != entry.bytes
            || entry.kind == "directory" && ordinal != 0
            || entry.kind == "file" && Some(format!("{:x}", sha.finalize())) != entry.sha256
        {
            return Err(invalid());
        }
        if phase == "recovered" && log_path(&entry.path) && entry.kind == "file" {
            let count = visit_log(&root.join(&entry.path), entry, |offset, bytes| {
                let actual:(Vec<u8>,Option<String>,Option<String>,String,i64)=sql(db.query_row(
                    "SELECT raw,event_id,body,parse_status,length FROM event_occurrences WHERE path=?1 AND offset=?2",
                    params![entry.path,offset as i64],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))))?;
                let value = serde_json::from_slice::<Value>(bytes).ok();
                let parse = if !bytes.ends_with(b"\n") {
                    "unterminated"
                } else if value.is_some() {
                    "json"
                } else {
                    "malformed"
                };
                if actual.0 != bytes
                    || actual.1.as_deref() != value.as_ref().and_then(|v| v["id"].as_str())
                    || actual.2.as_deref() != std::str::from_utf8(bytes).ok()
                    || actual.3 != parse
                    || actual.4 != bytes.len() as i64
                {
                    return Err(invalid());
                }
                Ok(())
            })?;
            let saved: i64 = sql(db.query_row(
                "SELECT count(*) FROM event_occurrences WHERE path=?1",
                [&entry.path],
                |r| r.get(0),
            ))?;
            if saved != count as i64 {
                return Err(invalid());
            }
            rows += count;
        }
    }
    Ok(rows)
}

/// A stopped legacy writer is required. Leases fence cooperating writers; inventory detects drift.
/// This never opens or activates a runtime operational database.
pub fn prepare(root: &Path) -> io::Result<Value> {
    let meta = fs::symlink_metadata(root)?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err(invalid());
    }
    let root = root.canonicalize()?;
    let _leases = leases(&root)?;
    if fs::symlink_metadata(root.join("threads.json.tmp")).is_ok()
        || fs::symlink_metadata(root.join("native-turn-queue.json.tmp")).is_ok()
    {
        return Err(invalid());
    }
    let original = inventory(&root)?;
    let mut nonce = [0; 16];
    OsRng.try_fill_bytes(&mut nonce).map_err(|_| invalid())?;
    let parent = root.join(".rust-operational-candidates");
    private_dir(&parent)?;
    let candidate = parent.join(digest(&nonce));
    fs::DirBuilder::new().create(&candidate)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&candidate, fs::Permissions::from_mode(0o700))?;
    }
    let clone = candidate.join("legacy");
    private_dir(&clone)?;
    clone_sources(&root, &clone, &original)?;
    if inventory(&root)? != original {
        return Err(invalid());
    }
    let path = candidate.join("operational.sqlite");
    drop(private_open(&path, true)?);
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
        | OpenFlags::SQLITE_OPEN_NOFOLLOW
        | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let mut db = sql(Connection::open_with_flags(&path, flags))?;
    sql(db.execute_batch("PRAGMA page_size=4096; PRAGMA foreign_keys=ON; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA trusted_schema=OFF; PRAGMA max_page_count=16777216;"))?;
    let transaction = sql(db.transaction())?;
    sql(transaction.execute_batch("PRAGMA application_id=1499090768; PRAGMA user_version=1;
        CREATE TABLE source_entries(phase TEXT NOT NULL CHECK(phase IN ('original','recovered')),path TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('file','directory')),bytes INTEGER NOT NULL CHECK(bytes>=0),sha256 TEXT,
            PRIMARY KEY(phase,path),CHECK((kind='file' AND length(sha256)=64) OR (kind='directory' AND bytes=0 AND sha256 IS NULL))) STRICT;
        CREATE TABLE source_chunks(phase TEXT NOT NULL,path TEXT NOT NULL,ordinal INTEGER NOT NULL CHECK(ordinal>=0),bytes BLOB NOT NULL,
            PRIMARY KEY(phase,path,ordinal),FOREIGN KEY(phase,path) REFERENCES source_entries(phase,path)) STRICT;
        CREATE TABLE event_occurrences(path TEXT NOT NULL,offset INTEGER NOT NULL CHECK(offset>=0),raw BLOB NOT NULL,event_id TEXT,
            body TEXT,parse_status TEXT NOT NULL CHECK(parse_status IN ('json','malformed','unterminated')),length INTEGER NOT NULL CHECK(length>0),
            PRIMARY KEY(path,offset)) STRICT;
        CREATE TABLE migration(id INTEGER PRIMARY KEY CHECK(id=1),manifest TEXT NOT NULL) STRICT;"))?;
    store(&transaction, &root, "original", &original)?;
    sql(transaction.commit())?;
    if inventory(&root)? != original {
        return Err(invalid());
    }
    // Commit exact original bytes before authenticated recovery can modify the private clone.
    // Failure leaves an unsealed review artifact; it never rewrites the source.
    drop(History::open(&clone)?);
    let recovered = inventory(&clone)?;
    let transaction = sql(db.transaction())?;
    let occurrences = store(&transaction, &clone, "recovered", &recovered)?;
    let manifest = json!({"version":1,"authority":"legacy-root","cutoverReady":false,
        "source":root,"scope":{"trees":TREES,"files":FILE_NAMES,"prefixes":PREFIXES,
        "excluded":["connection identity and sequence stores","credential and provider configuration","attachment ingress staging","Markdown knowledge and derived memory indexes"],
        "validated":["history journal authentication and clone-only intent recovery"],"stoppedWriterRequired":true,"limits":{"fileBytes":FILE_BYTES,"phaseBytes":TOTAL_BYTES,"entries":FILES,"occurrences":ROWS,"lineBytes":LINE_BYTES,"databaseBytes":64 * FILE_BYTES}},
        "original":original,"recovered":recovered,"occurrences":occurrences});
    let encoded = serde_json::to_vec(&manifest).map_err(io::Error::other)?;
    sql(transaction.execute(
        "INSERT INTO migration VALUES(1,?1)",
        [std::str::from_utf8(&encoded).map_err(io::Error::other)?],
    ))?;
    sql(transaction.commit())?;
    drop(db);
    let db = sql(Connection::open_with_flags(
        &path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    ))?;
    let integrity: String = sql(db.query_row("PRAGMA integrity_check", [], |r| r.get(0)))?;
    let violations: i64 = sql(db.query_row(
        "SELECT count(*) FROM pragma_foreign_key_check",
        [],
        |r| r.get(0),
    ))?;
    if integrity != "ok" || violations != 0 {
        return Err(invalid());
    }
    verify(&db, &root, "original", &original)?;
    if verify(&db, &clone, "recovered", &recovered)? != occurrences {
        return Err(invalid());
    }
    let saved: i64 = sql(db.query_row("SELECT count(*) FROM event_occurrences", [], |r| r.get(0)))?;
    let saved_manifest: String = sql(db.query_row(
        "SELECT manifest FROM migration WHERE id=1",
        [],
        |r| r.get(0),
    ))?;
    if saved != occurrences as i64 || saved_manifest.as_bytes() != encoded {
        return Err(invalid());
    }
    drop(db);
    if inventory(&root)? != original || inventory(&clone)? != recovered {
        return Err(invalid());
    }
    let seal = json!({"manifest":manifest,"manifestSha256":digest(&encoded),"databaseSha256":hash(&path, 64 * FILE_BYTES)?});
    crate::history::publish(
        &candidate.join("prepared.json"),
        &serde_json::to_vec(&seal).map_err(io::Error::other)?,
    )?;
    sync_dir(&parent)?;
    Ok(
        json!({"prepared":true,"cutoverReady":false,"candidate":candidate,"occurrences":occurrences}),
    )
}
