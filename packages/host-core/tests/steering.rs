use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
};
use yorozu_host_core::{history::History, now_ms, steering::Steering};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-steering-{}-{}-{}",
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
fn record() -> Value {
    json!({"eventId":"follow","threadId":"thread","activeEventId":"active","attemptId":"request","identity":"a".repeat(64),"completionId":"native:active:final","sessionId":"native-session","status":"attempting","future":{"retained":true}})
}
fn begin(record: Value) -> Value {
    json!({"op":"steering_begin","record":record})
}
fn event() -> Value {
    json!({"id":"follow","threadId":"thread","ts":1000,"agentId":"phone","kind":"message","clientTs":900,"data":{"role":"user","text":"keep this follow-up","delivery":"steer","runId":"native:active:final","completionId":"native:active:final"}})
}
fn commit() -> Value {
    json!({"op":"steering_commit","eventId":"follow","attemptId":"request","event":event()})
}
fn queued(store: &mut History) {
    assert_eq!(
        store.request(&json!({"op":"queue_enqueue","eventId":"follow","threadId":"thread"}))["stored"],
        true
    );
}
#[test]
fn intent_is_durable_before_execution_and_uncertain_retries_never_reserve_another_effect() {
    let temp = Temp::new();
    let mut store = Steering::open(&temp.0).unwrap();
    assert_eq!(store.request(&begin(record()))["reserved"], true);
    assert_eq!(store.request(&begin(record()))["reserved"], false);
    let mut changed = record();
    changed["attemptId"] = json!("new-request");
    changed["activeEventId"] = json!("other-run");
    assert_eq!(store.request(&begin(changed))["reserved"], false);
    drop(store);
    let mut store = Steering::open(&temp.0).unwrap();
    assert_eq!(store.request(&begin(record()))["reserved"], false);
    assert_eq!(store.get("follow").unwrap()["status"], "attempting");
}
#[test]
fn definite_rejection_allows_only_a_fresh_explicit_attempt_and_never_reuses_attempt_identity() {
    let temp = Temp::new();
    let mut store = Steering::open(&temp.0).unwrap();
    store.request(&begin(record()));
    assert_eq!(
        store.finish("follow", "request", "rejected")["record"]["status"],
        "rejected"
    );
    assert_eq!(store.request(&begin(record()))["reserved"], false);
    let mut next = record();
    next["attemptId"] = json!("fresh");
    next["activeEventId"] = json!("new-active");
    next["completionId"] = json!("native:new-active:final");
    assert_eq!(store.request(&begin(next.clone()))["reserved"], true);
    assert_eq!(
        store.finish("follow", "fresh", "rejected")["record"]["status"],
        "rejected"
    );
    assert!(store.request(&begin(record())).get("error").is_some());
    next["eventId"] = json!("another-follow");
    assert!(store.request(&begin(next)).get("error").is_some());
    drop(store);
    assert!(Steering::open(&temp.0).is_ok());
}
#[test]
fn delivered_projection_outcome_and_queue_cleanup_are_idempotent_and_bound_to_original_run() {
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    queued(&mut store);
    assert_eq!(store.request(&begin(record()))["reserved"], true);
    assert_eq!(store.request(&commit())["record"]["status"], "delivered");
    assert_eq!(store.request(&commit())["record"]["status"], "delivered");
    assert_eq!(
        fs::read_to_string(temp.0.join("threads/thread.jsonl"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    assert_eq!(
        fs::read_to_string(temp.0.join("transcripts/1970-01-01.jsonl"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    assert_eq!(
        fs::read_to_string(temp.0.join("native-turn-queue.json")).unwrap(),
        "[]\n"
    );
    let mut changed = commit();
    changed["event"]["data"]["completionId"] = json!("wrong-run");
    assert!(store.request(&changed).get("error").is_some());
    assert_eq!(store.request(&begin(record()))["reserved"], false);
    drop(store);
    let mut store = History::open(&temp.0).unwrap();
    assert_eq!(
        store.request(&json!({"op":"steering_open"}))["stored"],
        true
    );
    assert_eq!(store.request(&commit())["record"]["status"], "delivered");
}
#[test]
fn interrupted_outcome_or_queue_cleanup_recovers_original_projection_without_repeating_effect() {
    for truncate_projection in [false, true] {
        let temp = Temp::new();
        let mut store = History::open(&temp.0).unwrap();
        queued(&mut store);
        store.request(&begin(record()));
        store.request(&commit());
        drop(store);
        fs::write(
            temp.0.join("native-steering.jsonl"),
            format!("{}\n", record()),
        )
        .unwrap();
        fs::write(
            temp.0.join("native-turn-queue.json"),
            "[{\"eventId\":\"follow\",\"threadId\":\"thread\"}]\n",
        )
        .unwrap();
        if truncate_projection {
            let transaction = fs::read_dir(temp.0.join(".rust-history"))
                .unwrap()
                .map(|item| item.unwrap().path())
                .find(|path| path.extension().is_some_and(|ext| ext == "done"))
                .unwrap();
            fs::remove_file(transaction).unwrap();
            fs::write(
                temp.0.join("transcripts/1970-01-01.jsonl"),
                b"{\"id\":\"follow",
            )
            .unwrap();
        }
        let mut store = History::open(&temp.0).unwrap();
        assert_eq!(
            store.request(&json!({"op":"steering_open"}))["stored"],
            true
        );
        assert_eq!(store.request(&begin(record()))["reserved"], false);
        assert_eq!(
            store.request(&json!({"op":"steering_get","eventId":"follow"}))["record"]["status"],
            "delivered"
        );
        assert_eq!(
            fs::read_to_string(temp.0.join("native-turn-queue.json")).unwrap(),
            "[]\n"
        );
        assert_eq!(
            fs::read_to_string(temp.0.join("threads/thread.jsonl"))
                .unwrap()
                .lines()
                .count(),
            1
        );
        assert_eq!(
            fs::read_to_string(temp.0.join("transcripts/1970-01-01.jsonl"))
                .unwrap()
                .lines()
                .count(),
            1
        );
    }
}
#[test]
fn original_thread_identity_and_terminal_outcome_cannot_be_changed() {
    let temp = Temp::new();
    let mut store = Steering::open(&temp.0).unwrap();
    store.request(&begin(record()));
    for key in ["threadId", "identity"] {
        let mut changed = record();
        changed[key] = json!(if key == "identity" {
            "b".repeat(64)
        } else {
            "other-thread".into()
        });
        assert!(store.request(&begin(changed)).get("error").is_some());
    }
    assert!(
        store
            .finish("follow", "different-attempt", "rejected")
            .get("error")
            .is_some()
    );
    assert_eq!(
        store.finish("follow", "request", "delivered")["record"]["future"],
        json!({"retained":true})
    );
    assert!(
        store
            .finish("follow", "request", "rejected")
            .get("error")
            .is_some()
    );
    assert!(Steering::open(&temp.0).is_err());
}
#[test]
fn actual_worker_termination_after_intent_leaves_effect_uncertain_and_queue_retained() {
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    queued(&mut store);
    drop(store);
    let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .args(["history", temp.0.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut request = begin(record());
    request["id"] = json!("rpc");
    writeln!(child.stdin.as_mut().unwrap(), "{request}").unwrap();
    let mut response = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut response)
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&response).unwrap()["result"]["reserved"],
        true
    );
    child.kill().unwrap();
    child.wait().unwrap();
    let mut store = History::open(&temp.0).unwrap();
    assert_eq!(store.request(&begin(record()))["reserved"], false);
    assert!(
        fs::read_to_string(temp.0.join("native-turn-queue.json"))
            .unwrap()
            .contains("follow")
    );
    assert!(!temp.0.join("threads/thread.jsonl").exists());
}
#[test]
fn incomplete_journal_tail_is_retained_before_a_safe_new_intent_and_malformed_complete_rows_fail() {
    let temp = Temp::new();
    let old = format!("{}\n{{\"incomplete", record());
    fs::write(temp.0.join("native-steering.jsonl"), &old).unwrap();
    let mut store = Steering::open(&temp.0).unwrap();
    let mut next = record();
    next["eventId"] = json!("another");
    next["attemptId"] = json!("another-attempt");
    assert_eq!(store.request(&begin(next))["reserved"], true);
    let backup = fs::read_dir(&temp.0)
        .unwrap()
        .map(|item| item.unwrap().path())
        .find(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(".native-steering-recovery.")
        })
        .unwrap();
    assert_eq!(fs::read_to_string(backup).unwrap(), old);
    drop(store);
    assert!(Steering::open(&temp.0).is_ok());
    let temp = Temp::new();
    let old = b"{\"invalid\":true}\n";
    fs::write(temp.0.join("native-steering.jsonl"), old).unwrap();
    assert!(Steering::open(&temp.0).is_err());
    assert_eq!(fs::read(temp.0.join("native-steering.jsonl")).unwrap(), old);
}
#[test]
fn bounded_snapshot_pages_and_invalid_intents_cannot_start_effects() {
    let temp = Temp::new();
    let mut store = Steering::open(&temp.0).unwrap();
    for i in 0..65 {
        let mut next = record();
        next["eventId"] = json!(format!("follow-{i:03}"));
        next["attemptId"] = json!(format!("attempt-{i}"));
        assert_eq!(store.request(&begin(next))["reserved"], true);
    }
    let first = store.request(&json!({"op":"steering_list","offset":0}));
    assert_eq!(first["records"].as_array().unwrap().len(), 64);
    assert_eq!(first["next"], 64);
    assert_eq!(
        store.request(&json!({"op":"steering_list","offset":64}))["records"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(store.request(&begin(json!([]))).get("error").is_some());
    let mut bad = record();
    bad["eventId"] = bad["activeEventId"].clone();
    assert!(store.request(&begin(bad)).get("error").is_some());
}

#[test]
fn outcome_durable_but_queue_cleanup_failure_recovers_without_fabricating_a_second_delivery() {
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    queued(&mut store);
    store.request(&begin(record()));
    let blocker = temp.0.join("native-turn-queue.json.tmp");
    fs::write(&blocker, b"retained ambiguous queue").unwrap();
    assert!(store.request(&commit()).get("error").is_some());
    assert_eq!(
        fs::read_to_string(temp.0.join("threads/thread.jsonl"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    assert!(
        fs::read_to_string(temp.0.join("native-turn-queue.json"))
            .unwrap()
            .contains("follow")
    );
    drop(store);
    let mut store = History::open(&temp.0).unwrap();
    assert!(
        store
            .request(&json!({"op":"steering_open"}))
            .get("error")
            .is_some()
    );
    drop(store);
    assert_eq!(fs::read(&blocker).unwrap(), b"retained ambiguous queue");
    fs::rename(&blocker, temp.0.join("explicitly-retained-blocker")).unwrap();
    let mut store = History::open(&temp.0).unwrap();
    assert_eq!(
        store.request(&json!({"op":"steering_open"}))["stored"],
        true
    );
    assert_eq!(store.request(&begin(record()))["reserved"], false);
    assert_eq!(
        fs::read_to_string(temp.0.join("native-turn-queue.json")).unwrap(),
        "[]\n"
    );
    assert_eq!(
        fs::read_to_string(temp.0.join("threads/thread.jsonl"))
            .unwrap()
            .lines()
            .count(),
        1
    );
}

#[cfg(unix)]
#[test]
fn linked_journals_are_refused_and_new_steering_files_are_private_without_changing_root_permissions()
 {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let temp = Temp::new();
    fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o755)).unwrap();
    let mut store = Steering::open(&temp.0).unwrap();
    assert_eq!(store.request(&begin(record()))["reserved"], true);
    let file = temp.0.join("native-steering.jsonl");
    assert_eq!(
        fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777,
        0o755
    );
    drop(store);
    let original = fs::read(&file).unwrap();
    fs::rename(&file, temp.0.join("original")).unwrap();
    symlink(temp.0.join("original"), &file).unwrap();
    assert!(Steering::open(&temp.0).is_err());
    assert_eq!(fs::read(temp.0.join("original")).unwrap(), original);
}
