use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{now_ms, thread_index};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-thread-index-{}-{}-{}",
            std::process::id(),
            now_ms(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn index(&self) -> PathBuf {
        self.0.join("threads.json")
    }
    fn bytes(&self) -> Vec<u8> {
        fs::read(self.index()).unwrap()
    }
    fn hash(&self) -> Value {
        if self.index().exists() {
            json!(format!("{:x}", Sha256::digest(self.bytes())))
        } else {
            Value::Null
        }
    }
    fn request(&self, records: Value, expected: Value) -> Value {
        thread_index::request(
            &self.0,
            &json!({"op":"replace", "threads":records, "expectedHash":expected}),
        )
    }
    fn save(&self, records: Value) -> Value {
        self.request(records, self.hash())
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn record(id: &str) -> Value {
    json!({"id":id,"title":"","createdAt":"2026-10-01T00:00:00.000Z","archived":false,"agent":"codex","cwd":"/tmp/project"})
}
fn cli(temp: &Temp, request: Value) -> std::process::Child {
    let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .args(["thread-index", temp.0.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    writeln!(child.stdin.take().unwrap(), "{request}").unwrap();
    child
}
#[test]
fn legacy_bytes_and_safe_numeric_notation_survive_noop_and_mutation_has_exact_recovery_copy() {
    let temp = Temp::new();
    let mut old = record("thread");
    old["future"] = json!({"count":1000});
    let original = serde_json::to_string_pretty(&json!([old.clone()]))
        .unwrap()
        .replace("1000", "1e3");
    fs::write(temp.index(), &original).unwrap();
    assert_eq!(temp.save(json!([old.clone()]))["changed"], false);
    assert_eq!(temp.bytes(), original.as_bytes());
    old["model"] = json!("gpt");
    old["nativeSessionId"] = json!("session");
    old["nativeTurn"] = json!({"id":"native:message:final","state":"running","userEventId":"message","recoveryAttempts":0});
    assert_eq!(temp.save(json!([old.clone()]))["stored"], true);
    assert_eq!(
        serde_json::from_slice::<Value>(&temp.bytes()).unwrap(),
        json!([old])
    );
    let snapshots: Vec<_> = fs::read_dir(temp.0.join(".thread-index-recovery"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(snapshots.len(), 1);
    assert_eq!(fs::read(&snapshots[0]).unwrap(), original.as_bytes());
}
#[test]
fn stale_revision_cannot_clobber_committed_session_and_original_owner_is_immutable() {
    let temp = Temp::new();
    let mut old = record("thread");
    assert_eq!(temp.save(json!([old.clone()]))["stored"], true);
    let stale = temp.hash();
    old["nativeSessionId"] = json!("committed");
    assert_eq!(temp.save(json!([old.clone()]))["stored"], true);
    assert_eq!(
        temp.request(json!([record("thread")]), stale)["error"],
        "conflicting-thread-index"
    );
    let bytes = temp.bytes();
    for (key, value) in [
        ("agent", json!("claude-code")),
        ("cwd", json!("/tmp/other")),
        ("createdAt", json!("2026-09-30")),
        (
            "creation",
            json!({"eventId":"other","identity":"a".repeat(64)}),
        ),
    ] {
        let mut changed = old.clone();
        changed[key] = value;
        assert_eq!(
            temp.save(json!([changed]))["error"],
            "conflicting-thread-owner"
        );
        assert_eq!(temp.bytes(), bytes);
    }
}
#[test]
fn unknown_fields_cannot_be_removed_changed_or_rounded() {
    let temp = Temp::new();
    let mut old = record("thread");
    old["future"] = json!({"count":9_007_199_254_740_993_u64});
    assert_eq!(temp.save(json!([old.clone()]))["stored"], true);
    let bytes = temp.bytes();
    for changed in [record("thread"), {
        let mut changed = old.clone();
        changed["future"] = json!({"count":9_007_199_254_740_992_u64});
        changed
    }] {
        assert_eq!(
            temp.save(json!([changed]))["error"],
            "unsupported-thread-transition"
        );
        assert_eq!(temp.bytes(), bytes);
    }
}
#[test]
fn removal_retains_history_and_only_empty_legacy_home_can_be_removed() {
    let temp = Temp::new();
    assert_eq!(temp.save(json!([record("thread")]))["stored"], true);
    assert_eq!(temp.save(json!([]))["error"], "thread-history-retained");
    for populated in [false, true] {
        let temp = Temp::new();
        assert_eq!(temp.save(json!([record("home")]))["stored"], true);
        fs::create_dir(temp.0.join("threads")).unwrap();
        fs::write(
            temp.0.join("threads/home.jsonl"),
            if populated { "saved history" } else { "" },
        )
        .unwrap();
        let proof = temp.save(json!([]));
        assert_eq!(proof.get("stored") == Some(&json!(true)), !populated);
        assert_eq!(
            fs::read_to_string(temp.0.join("threads/home.jsonl")).unwrap(),
            if populated { "saved history" } else { "" }
        );
    }
}
#[test]
fn corrupt_duplicate_alias_and_oversized_indexes_remain_untouched() {
    for original in [
        b"unfinished".to_vec(),
        serde_json::to_vec(&json!([record("thread"), record("thread")])).unwrap(),
        serde_json::to_vec(&json!([record("a/b"), record("a?b")])).unwrap(),
    ] {
        let temp = Temp::new();
        fs::write(temp.index(), &original).unwrap();
        assert!(temp.save(json!([])).get("error").is_some());
        assert_eq!(temp.bytes(), original);
    }
    let temp = Temp::new();
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(temp.index())
        .unwrap()
        .set_len(16 * 1024 * 1024 + 1)
        .unwrap();
    assert!(temp.save(json!([])).get("error").is_some());
    assert_eq!(
        fs::metadata(temp.index()).unwrap().len(),
        16 * 1024 * 1024 + 1
    );
    let temp = Temp::new();
    assert!(
        temp.save(json!([record("😀"), record("__")]))
            .get("error")
            .is_some()
    );
    assert!(!temp.index().exists());
}
#[test]
fn legacy_pending_and_interrupted_rust_bytes_are_retained_and_bounded() {
    let temp = Temp::new();
    fs::write(temp.0.join("threads.json.tmp"), "unconfirmed legacy data").unwrap();
    assert_eq!(
        temp.save(json!([record("thread")]))["error"],
        "thread-index-recovery-required"
    );
    assert!(!temp.index().exists());
    assert_eq!(
        fs::read_to_string(temp.0.join("threads.json.tmp")).unwrap(),
        "unconfirmed legacy data"
    );
    let temp = Temp::new();
    fs::create_dir(temp.0.join(".thread-index-recovery")).unwrap();
    fs::write(
        temp.0.join(".thread-index-recovery/.pending.interrupted"),
        "partial snapshot",
    )
    .unwrap();
    fs::write(
        temp.0.join(".thread-index-pending.interrupted.json"),
        "partial transition",
    )
    .unwrap();
    assert_eq!(temp.save(json!([record("thread")]))["stored"], true);
    let mut changed = record("thread");
    changed["title"] = json!("Changed");
    assert_eq!(temp.save(json!([changed]))["stored"], true);
    assert_eq!(
        fs::read_to_string(temp.0.join(".thread-index-recovery/.pending.interrupted")).unwrap(),
        "partial snapshot"
    );
    assert_eq!(
        fs::read_to_string(temp.0.join(".thread-index-pending.interrupted.json")).unwrap(),
        "partial transition"
    );
    for i in 1..128 {
        fs::write(
            temp.0.join(format!(".thread-index-pending.{i}.json")),
            "partial",
        )
        .unwrap();
    }
    let bytes = temp.bytes();
    assert!(temp.save(json!([record("thread")])).get("error").is_some());
    assert_eq!(temp.bytes(), bytes);
}
#[test]
fn live_writer_lock_excludes_transactions_and_releases_without_mutating_state() {
    let temp = Temp::new();
    let owner = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(temp.0.join(".rust-thread-index-owner.lock"))
        .unwrap();
    owner.try_lock().unwrap();
    assert!(temp.save(json!([record("thread")])).get("error").is_some());
    assert!(!temp.index().exists());
    drop(owner);
    assert_eq!(temp.save(json!([record("thread")]))["stored"], true);
}
#[test]
fn helper_exit_and_competing_processes_preserve_acknowledged_revision() {
    let temp = Temp::new();
    let output = cli(
        &temp,
        json!({"op":"replace","threads":[record("thread")],"expectedHash":null}),
    )
    .wait_with_output()
    .unwrap();
    assert!(output.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["stored"],
        true
    );
    let mut first = record("thread");
    first["nativeSessionId"] = json!("first");
    let mut second = record("thread");
    second["nativeSessionId"] = json!("second");
    let revision = temp.hash();
    let a = cli(
        &temp,
        json!({"op":"replace","threads":[first.clone()],"expectedHash":revision}),
    );
    let b = cli(
        &temp,
        json!({"op":"replace","threads":[second.clone()],"expectedHash":revision}),
    );
    let proofs: Vec<Value> = [a, b]
        .into_iter()
        .map(|child| serde_json::from_slice(&child.wait_with_output().unwrap().stdout).unwrap())
        .collect();
    assert_eq!(
        proofs
            .iter()
            .filter(|proof| proof["stored"] == true)
            .count(),
        1
    );
    let final_index: Value = serde_json::from_slice(&temp.bytes()).unwrap();
    assert!(final_index == json!([first]) || final_index == json!([second]));
    assert_eq!(temp.save(final_index)["changed"], false);
}
#[cfg(unix)]
#[test]
fn links_and_home_links_are_retained_and_new_files_private_without_changing_existing_root_mode() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let temp = Temp::new();
    fs::write(temp.0.join("original"), "saved data").unwrap();
    symlink(temp.0.join("original"), temp.index()).unwrap();
    assert!(temp.save(json!([record("thread")])).get("error").is_some());
    assert_eq!(
        fs::read_to_string(temp.0.join("original")).unwrap(),
        "saved data"
    );
    let temp = Temp::new();
    fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(temp.save(json!([record("home")]))["stored"], true);
    assert_eq!(
        fs::metadata(temp.index()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777,
        0o755
    );
    fs::create_dir(temp.0.join("threads")).unwrap();
    fs::write(temp.0.join("empty"), "").unwrap();
    symlink(temp.0.join("empty"), temp.0.join("threads/home.jsonl")).unwrap();
    assert_eq!(temp.save(json!([]))["error"], "thread-history-retained");
    let mut changed = record("home");
    changed["model"] = json!("new");
    assert_eq!(temp.save(json!([changed]))["stored"], true);
    for file in fs::read_dir(temp.0.join(".thread-index-recovery")).unwrap() {
        assert_eq!(
            file.unwrap().metadata().unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
