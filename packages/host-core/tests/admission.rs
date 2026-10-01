use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{admission::Admissions, now_ms};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-admission-{}-{}-{}",
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
fn entry(id: &str) -> Value {
    json!({"id":id,"threadId":"thread","identity":"a".repeat(64),"deadline":1000})
}
fn expire(store: &mut Admissions, value: Value) -> Value {
    store.request(&json!({"op":"admission_expire","entry":value,"now":2000}))
}
#[test]
fn legacy_bytes_and_unknown_fields_survive_open_and_identical_retries() {
    let temp = Temp::new();
    let mut original = entry("old");
    original["future"] = json!({"kept":true});
    let bytes = format!(
        "{}\n",
        serde_json::to_string_pretty(&original)
            .unwrap()
            .replace('\n', " ")
            .replace("1000", "1e3")
    );
    fs::write(temp.0.join("expired-admissions.jsonl"), &bytes).unwrap();
    let mut store = Admissions::open(&temp.0).unwrap();
    assert_eq!(
        expire(&mut store, entry("old")),
        json!({"status":"expired"})
    );
    assert_eq!(
        fs::read_to_string(temp.0.join("expired-admissions.jsonl")).unwrap(),
        bytes
    );
    assert_eq!(
        store.request(&json!({"op":"admission_get","messageId":"old"}))["entry"],
        serde_json::from_str::<Value>(&bytes).unwrap()
    );
}
#[test]
fn expiration_is_irreversible_and_conflicts_cannot_replace_identity_thread_or_deadline() {
    let temp = Temp::new();
    let mut store = Admissions::open(&temp.0).unwrap();
    assert_eq!(
        expire(&mut store, entry("same")),
        json!({"status":"expired"})
    );
    let bytes = fs::read(temp.0.join("expired-admissions.jsonl")).unwrap();
    for (key, changed) in [
        ("threadId", json!("other")),
        ("identity", json!("b".repeat(64))),
        ("deadline", json!(3000)),
    ] {
        let mut value = entry("same");
        value[key] = changed;
        assert_eq!(
            expire(&mut store, value),
            json!({"status":"rejected","reason":"conflicting-message-id"})
        );
    }
    assert_eq!(
        fs::read(temp.0.join("expired-admissions.jsonl")).unwrap(),
        bytes
    );
    drop(store);
    let mut reopened = Admissions::open(&temp.0).unwrap();
    assert_eq!(
        expire(&mut reopened, entry("same")),
        json!({"status":"expired"})
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(temp.0.join("expired-admissions.jsonl"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
#[test]
fn incomplete_tail_is_preserved_until_append_and_recovery_copy_keeps_original_bytes() {
    let temp = Temp::new();
    let original = format!("{}\n{{\"id\":\"unfinished", entry("old"));
    fs::write(temp.0.join("expired-admissions.jsonl"), &original).unwrap();
    let mut store = Admissions::open(&temp.0).unwrap();
    assert_eq!(
        fs::read_to_string(temp.0.join("expired-admissions.jsonl")).unwrap(),
        original
    );
    assert_eq!(
        expire(&mut store, entry("new")),
        json!({"status":"expired"})
    );
    let recovered = fs::read_dir(&temp.0)
        .unwrap()
        .map(|p| p.unwrap().path())
        .find(|p| {
            p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(".expired-admissions-recovery.")
        })
        .unwrap();
    assert_eq!(fs::read_to_string(recovered).unwrap(), original);
    drop(store);
    let mut reopened = Admissions::open(&temp.0).unwrap();
    assert_eq!(
        reopened.request(&json!({"op":"admission_get","messageId":"old"}))["entry"],
        entry("old")
    );
    assert_eq!(
        reopened.request(&json!({"op":"admission_get","messageId":"new"}))["entry"],
        entry("new")
    );
}
#[test]
fn malformed_duplicate_and_oversized_complete_journals_are_retained_and_fail_closed() {
    for bytes in [
        b"invalid\n".to_vec(),
        format!("{0}\n{0}\n", entry("duplicate")).into_bytes(),
        vec![b'x'; 1024 * 1024 + 1],
    ] {
        let temp = Temp::new();
        let file = temp.0.join("expired-admissions.jsonl");
        fs::write(&file, &bytes).unwrap();
        assert!(Admissions::open(&temp.0).is_err());
        assert_eq!(fs::read(file).unwrap(), bytes);
    }
    let temp = Temp::new();
    let file = temp.0.join("expired-admissions.jsonl");
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&file)
        .unwrap()
        .set_len(64 * 1024 * 1024 + 1)
        .unwrap();
    assert!(Admissions::open(&temp.0).is_err());
    assert_eq!(fs::metadata(file).unwrap().len(), 64 * 1024 * 1024 + 1);
}
#[test]
fn future_or_invalid_deadlines_are_never_recorded_and_second_writer_is_excluded() {
    let temp = Temp::new();
    let mut store = Admissions::open(&temp.0).unwrap();
    assert!(Admissions::open(&temp.0).is_err());
    assert_eq!(
        store.request(&json!({"op":"admission_expire","entry":entry("future"),"now":999})),
        json!({"error":"admission-not-expired"})
    );
    for deadline in [json!(1.5), json!(9_007_199_254_740_992_u64), json!(null)] {
        let mut value = entry("invalid");
        value["deadline"] = deadline;
        assert!(expire(&mut store, value).get("error").is_some());
    }
    assert!(!temp.0.join("expired-admissions.jsonl").exists());
    drop(store);
    assert!(Admissions::open(&temp.0).is_ok());
}
#[test]
fn acknowledged_expiration_survives_actual_worker_termination() {
    let temp = Temp::new();
    let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .args(["attachments", temp.0.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let request =
        json!({"id":"rpc","op":"admission_expire","entry":entry("acknowledged"),"now":2000});
    writeln!(child.stdin.as_mut().unwrap(), "{request}").unwrap();
    let mut response = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut response)
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&response).unwrap()["result"],
        json!({"status":"expired"})
    );
    child.kill().unwrap();
    child.wait().unwrap();
    let mut reopened = Admissions::open(&temp.0).unwrap();
    assert_eq!(
        expire(&mut reopened, entry("acknowledged")),
        json!({"status":"expired"})
    );
}
#[cfg(unix)]
#[test]
fn symlink_journal_is_refused_without_modifying_its_target() {
    let temp = Temp::new();
    fs::write(temp.0.join("original"), b"saved data").unwrap();
    std::os::unix::fs::symlink(
        temp.0.join("original"),
        temp.0.join("expired-admissions.jsonl"),
    )
    .unwrap();
    assert!(Admissions::open(&temp.0).is_err());
    assert_eq!(fs::read(temp.0.join("original")).unwrap(), b"saved data");
}
