use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{history::History, now_ms};

static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-operational-{}-{}-{}",
            std::process::id(),
            now_ms(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn prepare(root: &Path) -> Output {
    Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .arg("operational-prepare")
        .arg(root)
        .output()
        .unwrap()
}
fn event(text: &str) -> Value {
    json!({"id":"same-card","threadId":"thread","ts":1000,"agentId":"main",
        "kind":"message","data":{"role":"user","text":text},"unknown":{"retained":true}})
}
fn raw(db: &Connection, phase: &str, path: &str) -> Vec<u8> {
    db.prepare("SELECT bytes FROM source_chunks WHERE phase=?1 AND path=?2 ORDER BY ordinal")
        .unwrap()
        .query_map([phase, path], |row| row.get::<_, Vec<u8>>(0))
        .unwrap()
        .flat_map(Result::unwrap)
        .collect()
}
#[test]
fn offline_candidate_preserves_occurrences_original_bytes_and_recovers_only_its_clone() {
    let temp = Temp::new();
    fs::create_dir(temp.0.join("threads")).unwrap();
    let legacy = b"{ \"legacy\": 1e3 }\nmalformed row\n";
    fs::write(temp.0.join("threads/thread.jsonl"), legacy).unwrap();
    let mut host = History::open(&temp.0).unwrap();
    for (op, text) in [("first", "before"), ("corrected", "after")] {
        let mut row = event(text);
        if op == "corrected" {
            row["clientTs"] = json!(2);
        }
        assert_eq!(
            host.request(&json!({"op":"history_append","operationId":op,
            "event":row,"thread":true,"transcript":true}))["stored"],
            true
        );
    }
    assert_eq!(
        host.request(&json!({"op":"queue_enqueue","eventId":"same-card","threadId":"thread"}))["stored"],
        true
    );
    assert_eq!(
        host.request(
            &json!({"op":"stop_save","record":{"targetEventId":"same-card",
        "threadId":"thread","status":"requested","requestIds":["stop"]}})
        )["record"]["status"],
        "requested"
    );
    drop(host);
    // A real committed journal becomes an interrupted projection; keep the intent identity.
    let intent = fs::read_dir(temp.0.join(".rust-history"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .find(|p| {
            fs::read_to_string(p)
                .unwrap()
                .contains("\"operation_id\":\"corrected\"")
        })
        .unwrap();
    fs::remove_file(intent.with_extension("done")).unwrap();
    let transcript = temp.0.join("transcripts/1970-01-01.jsonl");
    let original = fs::read(&transcript).unwrap();
    let first_end = original.iter().position(|b| *b == b'\n').unwrap() + 1;
    fs::write(&transcript, &original[..first_end + 9]).unwrap();
    let interrupted = fs::read(&transcript).unwrap();
    let thread = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    let payload = vec![0xA5; 131_079];
    fs::create_dir(temp.0.join("threads/thread.results")).unwrap();
    fs::write(
        temp.0.join("threads/thread.results/evidence.json"),
        &payload,
    )
    .unwrap();
    fs::create_dir(temp.0.join(".thread-index-recovery")).unwrap();
    fs::write(
        temp.0.join(".thread-index-recovery/original.json"),
        b"retained backup",
    )
    .unwrap();
    fs::write(temp.0.join("approval.json"), b"{\"autoApproveRead\":false}").unwrap();
    fs::write(temp.0.join("credentials.json"), b"never import").unwrap();
    fs::create_dir(temp.0.join("threads/empty.attachments")).unwrap();
    fs::write(temp.0.join("threads/zero.jsonl"), b"").unwrap();
    fs::write(temp.0.join("threads/raw.jsonl"), b"\xff\n{\"unfinished").unwrap();
    #[cfg(unix)]
    fs::write(
        temp.0.join("threads/back\\slash.result.json"),
        b"exact filename",
    )
    .unwrap();
    let output = prepare(&temp.0);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let proof: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(proof["prepared"], true);
    assert_eq!(proof["cutoverReady"], false);
    let candidate = PathBuf::from(proof["candidate"].as_str().unwrap());
    let seal: Value =
        serde_json::from_slice(&fs::read(candidate.join("prepared.json")).unwrap()).unwrap();
    assert_eq!(seal["manifest"]["version"], 1);
    assert_eq!(seal["manifest"]["authority"], "legacy-root");
    use sha2::{Digest, Sha256};
    assert_eq!(
        seal["databaseSha256"],
        format!(
            "{:x}",
            Sha256::digest(fs::read(candidate.join("operational.sqlite")).unwrap())
        )
    );
    assert_eq!(
        seal["manifestSha256"],
        format!(
            "{:x}",
            Sha256::digest(serde_json::to_vec(&seal["manifest"]).unwrap())
        )
    );
    let db = Connection::open_with_flags(
        candidate.join("operational.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    assert_eq!(
        db.query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    assert_eq!(raw(&db, "original", "threads/thread.jsonl"), thread);
    assert_eq!(
        raw(&db, "original", "transcripts/1970-01-01.jsonl"),
        interrupted
    );
    assert_eq!(
        raw(&db, "recovered", "transcripts/1970-01-01.jsonl"),
        original
    );
    assert_eq!(
        raw(&db, "original", "threads/thread.results/evidence.json"),
        payload
    );
    assert_eq!(
        raw(&db, "original", ".thread-index-recovery/original.json"),
        b"retained backup"
    );
    assert_eq!(db.query_row("SELECT kind FROM source_entries WHERE phase='original' AND path='threads/empty.attachments'",[],|r|r.get::<_,String>(0)).unwrap(),"directory");
    assert_eq!(
        db.query_row(
            "SELECT bytes FROM source_entries WHERE phase='original' AND path='threads/zero.jsonl'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    assert_eq!(db.query_row("SELECT count(*) FROM event_occurrences WHERE path='threads/raw.jsonl' AND parse_status IN ('malformed','unterminated')",[],|r|r.get::<_,i64>(0)).unwrap(),2);
    assert_eq!(
        raw(&db, "original", "threads/raw.jsonl"),
        b"\xff\n{\"unfinished"
    );
    #[cfg(unix)]
    assert_eq!(
        raw(&db, "original", "threads/back\\slash.result.json"),
        b"exact filename"
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM source_entries WHERE path='credentials.json'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    let rows:Vec<(String,String)>=db.prepare("SELECT event_id,body FROM event_occurrences WHERE path='threads/thread.jsonl' AND event_id='same-card' ORDER BY offset").unwrap()
        .query_map([],|row|Ok((row.get(0)?,row.get(1)?))).unwrap().map(Result::unwrap).collect();
    assert_eq!(rows.len(), 2);
    assert_eq!(
        serde_json::from_str::<Value>(&rows[0].1).unwrap()["data"]["text"],
        "before"
    );
    assert_eq!(
        serde_json::from_str::<Value>(&rows[1].1).unwrap()["clientTs"],
        2
    );
    assert_eq!(fs::read(&transcript).unwrap(), interrupted);
    assert!(!intent.with_extension("done").exists());
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        thread
    );
    // Actual cooperating writers can reopen: preparation releases every source lease.
    assert!(History::open(&temp.0).is_ok());
}
#[test]
fn preparation_refuses_active_writers_or_untrusted_sources_without_a_seal() {
    for mode in [
        "history",
        "queue",
        "stop",
        "index-lock",
        "pending-index",
        "corrupt-intent",
        "symlink",
    ] {
        let temp = Temp::new();
        let mut host = History::open(&temp.0).unwrap();
        assert_eq!(
            host.request(&json!({"op":"history_append","operationId":"operation",
            "event":event("original"),"thread":true,"transcript":true}))["stored"],
            true
        );
        drop(host);
        let log = temp.0.join("threads/thread.jsonl");
        let mut owner: Option<Box<dyn std::any::Any>> = None;
        match mode {
            "history" => owner = Some(Box::new(History::open(&temp.0).unwrap())),
            "queue" => {
                owner = Some(Box::new(
                    yorozu_host_core::native_queue::NativeQueue::open(&temp.0).unwrap(),
                ))
            }
            "stop" => {
                owner = Some(Box::new(
                    yorozu_host_core::stops::Stops::open(&temp.0).unwrap(),
                ))
            }
            "index-lock" => {
                let file = fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(true)
                    .truncate(false)
                    .open(temp.0.join(".rust-thread-index-owner.lock"))
                    .unwrap();
                file.try_lock().unwrap();
                owner = Some(Box::new(file));
            }
            "pending-index" => {
                fs::write(temp.0.join("threads.json.tmp"), b"uncertain metadata").unwrap()
            }
            "corrupt-intent" => {
                let path = fs::read_dir(temp.0.join(".rust-history"))
                    .unwrap()
                    .map(|x| x.unwrap().path())
                    .find(|p| p.extension().is_some_and(|x| x == "json"))
                    .unwrap();
                let bytes = fs::read_to_string(&path).unwrap();
                fs::write(path, bytes.replace("original", "tampered")).unwrap();
            }
            "symlink" => {
                #[cfg(unix)]
                std::os::unix::fs::symlink(&log, temp.0.join("threads/foreign.jsonl")).unwrap();
                #[cfg(not(unix))]
                continue;
            }
            _ => unreachable!(),
        }
        let before = fs::read(&log).unwrap();
        assert!(!prepare(&temp.0).status.success(), "{mode}");
        assert_eq!(fs::read(&log).unwrap(), before, "{mode}");
        let directory = temp.0.join(".rust-operational-candidates");
        if directory.exists() {
            for item in fs::read_dir(directory).unwrap() {
                let candidate = item.unwrap().path();
                assert!(!candidate.join("prepared.json").exists(), "{mode}");
                if mode == "corrupt-intent" {
                    let db = Connection::open_with_flags(
                        candidate.join("operational.sqlite"),
                        OpenFlags::SQLITE_OPEN_READ_ONLY,
                    )
                    .unwrap();
                    assert_eq!(raw(&db, "original", "threads/thread.jsonl"), before);
                    assert_eq!(
                        db.query_row("SELECT count(*) FROM migration", [], |r| r.get::<_, i64>(0))
                            .unwrap(),
                        0
                    );
                    assert_eq!(
                        db.query_row(
                            "SELECT count(*) FROM source_entries WHERE phase='recovered'",
                            [],
                            |r| r.get::<_, i64>(0)
                        )
                        .unwrap(),
                        0
                    );
                }
            }
        }
        drop(owner);
    }
}
