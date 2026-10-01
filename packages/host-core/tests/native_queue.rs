use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{native_queue::NativeQueue, now_ms};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "yorozu-native-queue-{}-{}-{}",
            std::process::id(),
            now_ms(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
    fn queue(&self) -> PathBuf {
        self.0.join("native-turn-queue.json")
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn request(op: &str, event: &str, thread: &str) -> Value {
    json!({"op":op,"eventId":event,"threadId":thread})
}
fn rows(temp: &Temp) -> Value {
    serde_json::from_slice(&fs::read(temp.queue()).unwrap()).unwrap()
}
#[test]
fn legacy_exact_bytes_and_unknown_fields_survive_noop_and_are_backed_up_before_mutation() {
    let temp = Temp::new();
    let old = b"[ { \"threadId\": \"thread\", \"eventId\": \"old\", \"future\": 1e3 } ] \n";
    fs::write(temp.queue(), old).unwrap();
    let mut queue = NativeQueue::open(&temp.0).unwrap();
    let proof = queue.request(&json!({"op":"queue_open"}));
    assert_eq!(
        queue.request(&request("queue_enqueue", "old", "thread")),
        proof
    );
    assert_eq!(fs::read(temp.queue()).unwrap(), old);
    assert_eq!(
        queue.request(&request("queue_enqueue", "new", "thread"))["stored"],
        true
    );
    assert_eq!(rows(&temp)[0]["future"], 1000.0);
    let backup = fs::read_dir(temp.0.join(".rust-native-queue-recovery"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(fs::read(backup).unwrap(), old);
    assert_eq!(
        queue.request(&request("queue_remove", "old", "thread"))["stored"],
        true
    );
    assert_eq!(rows(&temp), json!([{"threadId":"thread","eventId":"new"}]));
    drop(queue);
    let mut restarted = NativeQueue::open(&temp.0).unwrap();
    assert_eq!(
        restarted.request(&request("queue_remove", "old", "thread"))["stored"],
        true
    );
    assert_eq!(rows(&temp).as_array().unwrap().len(), 1);
}
#[test]
fn retries_are_idempotent_and_owner_or_readiness_conflicts_do_not_poison_valid_queue() {
    let temp = Temp::new();
    let mut queue = NativeQueue::open(&temp.0).unwrap();
    let first = queue.request(&request("queue_enqueue", "message", "thread"));
    assert_eq!(
        queue.request(&request("queue_enqueue", "message", "thread")),
        first
    );
    for op in ["queue_enqueue", "queue_remove"] {
        assert_eq!(
            queue.request(&request(op, "message", "other"))["error"],
            "conflicting-queue-owner"
        );
    }
    assert_eq!(
        queue.request(&json!({"op":"queue_ready","expectedHash":null}))["error"],
        "conflicting-native-queue"
    );
    assert_eq!(
        queue.request(&json!({"op":"queue_ready","expectedHash":first["hash"]})),
        first
    );
    assert_eq!(
        queue.request(&request("queue_remove", "message", "thread"))["stored"],
        true
    );
    assert_eq!(rows(&temp), json!([]));
}
#[test]
fn concurrent_owners_are_excluded_and_external_mutation_fences_without_overwrite() {
    let temp = Temp::new();
    let mut queue = NativeQueue::open(&temp.0).unwrap();
    assert!(NativeQueue::open(&temp.0).is_err());
    queue.request(&request("queue_enqueue", "original", "thread"));
    let foreign = b"[{\"threadId\":\"other\",\"eventId\":\"foreign\"}]\n";
    fs::write(temp.queue(), foreign).unwrap();
    assert_eq!(
        queue.request(&request("queue_remove", "original", "thread"))["error"],
        "native-queue-storage-failed"
    );
    assert_eq!(
        queue.request(&json!({"op":"queue_ready"}))["error"],
        "native-queue-storage-failed"
    );
    assert_eq!(fs::read(temp.queue()).unwrap(), foreign);
    drop(queue);
    assert!(NativeQueue::open(&temp.0).is_ok());
}
#[test]
fn legacy_ambiguous_temporary_is_retained_and_blocks_until_explicitly_recovered() {
    let temp = Temp::new();
    let mut queue = NativeQueue::open(&temp.0).unwrap();
    let pending = temp.0.join("native-turn-queue.json.tmp");
    fs::write(&pending, b"uncertain legacy bytes").unwrap();
    assert_eq!(
        queue.request(&request("queue_enqueue", "message", "thread"))["error"],
        "queue-recovery-required"
    );
    drop(queue);
    assert!(NativeQueue::open(&temp.0).is_err());
    assert_eq!(fs::read(&pending).unwrap(), b"uncertain legacy bytes");
    fs::rename(&pending, temp.0.join("retained-legacy-temp")).unwrap();
    let mut queue = NativeQueue::open(&temp.0).unwrap();
    assert_eq!(
        queue.request(&request("queue_enqueue", "message", "thread"))["stored"],
        true
    );
}
#[test]
fn malformed_duplicate_or_oversized_legacy_data_is_not_rewritten() {
    for old in [
        b"broken JSON".as_slice(),
        b"[{\"eventId\":\"same\",\"threadId\":\"a\"},{\"eventId\":\"same\",\"threadId\":\"b\"}]",
        b"[{\"eventId\":\"\",\"threadId\":\"a\"}]",
    ] {
        let temp = Temp::new();
        fs::write(temp.queue(), old).unwrap();
        assert!(NativeQueue::open(&temp.0).is_err());
        assert_eq!(fs::read(temp.queue()).unwrap(), old);
    }
    let temp = Temp::new();
    let file = fs::File::create(temp.queue()).unwrap();
    file.set_len(16 * 1024 * 1024 + 1).unwrap();
    assert!(NativeQueue::open(&temp.0).is_err());
    assert_eq!(
        fs::metadata(temp.queue()).unwrap().len(),
        16 * 1024 * 1024 + 1
    );
}
#[test]
fn interrupted_private_temporary_is_retained_but_never_admitted_as_a_queue_transition() {
    let temp = Temp::new();
    let pending = temp.0.join(".native-queue-pending.interrupted.json");
    fs::write(
        &pending,
        b"[{\"eventId\":\"uncertain\",\"threadId\":\"t\"}]",
    )
    .unwrap();
    let mut queue = NativeQueue::open(&temp.0).unwrap();
    assert_eq!(
        queue.request(&json!({"op":"queue_ready"}))["hash"],
        Value::Null
    );
    queue.request(&request("queue_enqueue", "actual", "t"));
    assert_eq!(rows(&temp), json!([{"eventId":"actual","threadId":"t"}]));
    assert!(pending.exists());
    drop(queue);
    let mut queue = NativeQueue::open(&temp.0).unwrap();
    assert_eq!(
        queue.request(&request("queue_remove", "actual", "t"))["stored"],
        true
    );
    assert!(pending.exists());
}
#[test]
fn acknowledged_transition_survives_actual_worker_termination_and_original_retry() {
    let temp = Temp::new();
    for op in ["queue_enqueue", "queue_remove"] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
            .args(["history", temp.0.to_str().unwrap()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut req = request(op, "message", "thread");
        req["id"] = json!("rpc");
        writeln!(child.stdin.as_mut().unwrap(), "{req}").unwrap();
        let mut response = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut response)
            .unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&response).unwrap()["result"]["stored"],
            true
        );
        child.kill().unwrap();
        child.wait().unwrap();
        let mut queue = NativeQueue::open(&temp.0).unwrap();
        assert_eq!(
            queue.request(&request(op, "message", "thread"))["stored"],
            true
        );
        assert_eq!(
            rows(&temp).as_array().unwrap().len(),
            if op == "queue_enqueue" { 1 } else { 0 }
        );
    }
}
#[cfg(unix)]
#[test]
fn symlinks_are_refused_and_only_new_private_files_receive_private_permissions() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let temp = Temp::new();
    fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o755)).unwrap();
    let mut queue = NativeQueue::open(&temp.0).unwrap();
    queue.request(&request("queue_enqueue", "message", "thread"));
    assert_eq!(
        fs::metadata(temp.queue()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777,
        0o755
    );
    drop(queue);
    let original = fs::read(temp.queue()).unwrap();
    fs::rename(temp.queue(), temp.0.join("original")).unwrap();
    symlink(temp.0.join("original"), temp.queue()).unwrap();
    assert!(NativeQueue::open(&temp.0).is_err());
    assert_eq!(fs::read(temp.0.join("original")).unwrap(), original);
}
