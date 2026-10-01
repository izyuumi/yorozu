use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{accepted::Accepted, now_ms};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-accepted-{}-{}-{}",
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
fn record(id: &str) -> Value {
    json!({"id":id,"threadId":"thread","identity":"a".repeat(64),"purpose":"conversation",
    "event":{"id":id,"threadId":"thread","ts":1000,"agentId":"mac","kind":"message","data":{"role":"user","text":"keep this","completionId":format!("native:{id}:final")},"future":{"kept":true}}})
}
fn path(temp: &Temp, id: &str) -> PathBuf {
    temp.0
        .join("accepted-messages")
        .join(format!("{:x}.json", Sha256::digest(id.as_bytes())))
}
fn accept(store: &mut Accepted, entry: Value) -> Value {
    store.request(&json!({"op":"accepted_accept","entry":entry}))
}
fn get(store: &mut Accepted, id: &str) -> Value {
    store.request(&json!({"op":"accepted_get","messageId":id}))["entry"].clone()
}
#[test]
fn immutable_receipt_currency_preserves_unknown_fields_and_original_execution_purpose() {
    let temp = Temp::new();
    let mut store = Accepted::open(&temp.0).unwrap();
    let mut original = record("one");
    original["purpose"] = json!("approval-reply");
    original["approvalActionId"] = json!("original-card");
    assert_eq!(accept(&mut store, original.clone())["entry"], original);
    let bytes = fs::read(path(&temp, "one")).unwrap();
    let mut retry = record("one");
    retry["event"]["data"]["delivery"] = json!("steer");
    retry["event"]["data"]["completionId"] = json!("later-run");
    assert_eq!(accept(&mut store, retry)["entry"], original);
    assert_eq!(fs::read(path(&temp, "one")).unwrap(), bytes);
    drop(store);
    let mut reopened = Accepted::open(&temp.0).unwrap();
    assert_eq!(get(&mut reopened, "one"), original);
    let snapshot = reopened.request(&json!({"op":"accepted_snapshot"}));
    assert!(snapshot["entries"][0].get("event").is_none());
}
#[test]
fn changed_client_content_is_refused_even_with_a_forged_unchanged_wire_fingerprint() {
    let temp = Temp::new();
    let mut store = Accepted::open(&temp.0).unwrap();
    let mut original = record("one");
    original["event"]["data"]["attachments"] = json!([{"name":"a","mime":"text/plain","data":"QQ=="},{"name":"b","mime":"text/plain","data":"Qg=="}]);
    accept(&mut store, original.clone());
    let bytes = fs::read(path(&temp, "one")).unwrap();
    for key in [
        "thread",
        "text",
        "time",
        "deadline",
        "attachment",
        "order",
        "model",
        "reply",
        "identity",
    ] {
        let mut changed = original.clone();
        match key {
            "thread" => {
                changed["threadId"] = json!("other");
                changed["event"]["threadId"] = json!("other");
            }
            "text" => changed["event"]["data"]["text"] = json!("changed"),
            "time" => changed["event"]["ts"] = json!(1001),
            "deadline" => changed["event"]["data"]["admissionDeadline"] = json!(9000),
            "attachment" => changed["event"]["data"]["attachments"][0]["data"] = json!("Qw=="),
            "order" => changed["event"]["data"]["attachments"]
                .as_array_mut()
                .unwrap()
                .reverse(),
            "model" => changed["event"]["data"]["channelModel"] = json!({"model":null}),
            "reply" => changed["event"]["data"]["replyTo"] = json!("parent"),
            _ => changed["identity"] = json!("b".repeat(64)),
        }
        assert_eq!(
            accept(&mut store, changed),
            json!({"status":"rejected","reason":"conflicting-message-id"}),
            "{key}"
        );
        assert_eq!(fs::read(path(&temp, "one")).unwrap(), bytes);
    }
}
#[test]
fn legacy_numeric_notation_and_corrected_projection_keep_the_same_client_identity() {
    let temp = Temp::new();
    let mut store = Accepted::open(&temp.0).unwrap();
    let mut original = record("one");
    original["event"]["ts"] = serde_json::from_str("1e3").unwrap();
    original["event"]["data"]["admissionDeadline"] = serde_json::from_str("2e3").unwrap();
    accept(&mut store, original.clone());
    let mut corrected = record("one");
    corrected["event"]["ts"] = json!(3000);
    corrected["event"]["clientTs"] = json!(1000);
    corrected["event"]["data"]["admissionDeadline"] = json!(2000);
    assert_eq!(accept(&mut store, corrected)["entry"], original);
}
#[test]
fn committed_checksums_refuse_corruption_on_restart_and_fence_the_live_owner() {
    let temp = Temp::new();
    let mut store = Accepted::open(&temp.0).unwrap();
    accept(&mut store, record("one"));
    let mut envelope: Value =
        serde_json::from_slice(&fs::read(path(&temp, "one")).unwrap()).unwrap();
    envelope["entry"]["event"]["data"]["completionId"] = json!("tampered-run");
    let bytes = serde_json::to_vec(&envelope).unwrap();
    fs::write(path(&temp, "one"), &bytes).unwrap();
    assert_eq!(
        store.request(&json!({"op":"accepted_get","messageId":"one"})),
        json!({"error":"accepted-storage-failed"})
    );
    assert_eq!(
        accept(&mut store, record("new")),
        json!({"error":"accepted-storage-failed"})
    );
    drop(store);
    assert!(Accepted::open(&temp.0).is_err());
    assert_eq!(fs::read(path(&temp, "one")).unwrap(), bytes);
}
#[test]
fn interrupted_private_temporaries_are_retained_without_becoming_accepted_work() {
    let temp = Temp::new();
    let store = Accepted::open(&temp.0).unwrap();
    drop(store);
    let pending = temp.0.join("accepted-messages/.accepted-previous-1.tmp");
    fs::write(&pending, b"{unfinished").unwrap();
    let mut store = Accepted::open(&temp.0).unwrap();
    assert_eq!(
        store.request(&json!({"op":"accepted_snapshot"})),
        json!({"entries":[],"next":null})
    );
    assert_eq!(accept(&mut store, record("one"))["status"], "accepted");
    assert_eq!(fs::read(&pending).unwrap(), b"{unfinished");
}
#[test]
fn owner_exclusion_and_invalid_record_bounds_retain_original_files() {
    let temp = Temp::new();
    let owner = Accepted::open(&temp.0).unwrap();
    assert!(Accepted::open(&temp.0).is_err());
    drop(owner);
    let bad = path(&temp, "one");
    let file = fs::File::create(&bad).unwrap();
    file.set_len(32 * 1024 * 1024 + 1).unwrap();
    assert!(Accepted::open(&temp.0).is_err());
    assert_eq!(fs::metadata(&bad).unwrap().len(), 32 * 1024 * 1024 + 1);
}
#[test]
fn acknowledged_body_and_attachments_survive_actual_worker_termination() {
    let temp = Temp::new();
    let mut entry = record("one");
    entry["event"]["data"]["attachments"] =
        json!([{"name":"large.txt","mime":"text/plain","data":"A".repeat(2*1024*1024)}]);
    let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .args(["attachments", temp.0.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    writeln!(
        child.stdin.as_mut().unwrap(),
        "{}",
        json!({"id":"rpc","op":"accepted_accept","entry":entry})
    )
    .unwrap();
    let mut response = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut response)
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&response).unwrap()["result"]["entry"],
        entry
    );
    child.kill().unwrap();
    child.wait().unwrap();
    let mut store = Accepted::open(&temp.0).unwrap();
    assert_eq!(get(&mut store, "one"), entry);
}
#[cfg(unix)]
#[test]
fn links_are_refused_and_private_modes_do_not_change_existing_directory_permissions() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let temp = Temp::new();
    fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o750)).unwrap();
    let mut store = Accepted::open(&temp.0).unwrap();
    accept(&mut store, record("one"));
    assert_eq!(
        fs::metadata(path(&temp, "one"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777,
        0o750
    );
    drop(store);
    let link = path(&temp, "linked");
    symlink(path(&temp, "one"), &link).unwrap();
    assert!(Accepted::open(&temp.0).is_err());
    assert!(fs::symlink_metadata(link).unwrap().file_type().is_symlink());
}

#[test]
fn metadata_pages_bound_snapshot_frames_and_cover_each_identity_once() {
    let temp = Temp::new();
    let mut store = Accepted::open(&temp.0).unwrap();
    for index in 0..260 {
        assert_eq!(
            accept(&mut store, record(&format!("operation-{index:03}")))["status"],
            "accepted"
        );
    }
    let first = store.request(&json!({"op":"accepted_snapshot"}));
    assert_eq!(first["entries"].as_array().unwrap().len(), 256);
    assert_eq!(first["next"], json!("operation-255"));
    let second = store.request(&json!({"op":"accepted_snapshot","after":first["next"]}));
    assert_eq!(second["entries"].as_array().unwrap().len(), 4);
    assert_eq!(second["next"], Value::Null);
    assert_eq!(second["entries"][0]["id"], json!("operation-256"));
    assert!(
        first["entries"]
            .as_array()
            .unwrap()
            .iter()
            .all(|entry| entry.get("event").is_none())
    );
}
