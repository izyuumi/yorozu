use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{history::History, now_ms};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "yorozu-history-{}-{}-{}",
            std::process::id(),
            now_ms(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
    fn thread(&self) -> PathBuf {
        self.0.join("threads/thread.jsonl")
    }
    fn transcript(&self) -> PathBuf {
        self.0.join("transcripts/1970-01-01.jsonl")
    }
    fn intents(&self) -> Vec<PathBuf> {
        fs::read_dir(self.0.join(".rust-history"))
            .unwrap()
            .map(|item| item.unwrap().path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
            .collect()
    }
    fn uncommit(&self) {
        let intent = self.intents().into_iter().next().unwrap();
        fs::remove_file(intent.with_extension("done")).unwrap();
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn event(text: &str) -> Value {
    json!({"id":"same-card","threadId":"thread","ts":1000,"agentId":"main","kind":"message","data":{"role":"agent","text":text},"future":{"kept":true}})
}
fn request(op: &str, text: &str) -> Value {
    json!({"op":"history_append","operationId":op,"event":event(text),"thread":true,"transcript":true})
}
fn line(text: &str) -> Vec<u8> {
    format!("{}\n", event(text)).into_bytes()
}
#[test]
fn legacy_complete_bytes_unknown_fields_and_repeated_cards_are_preserved() {
    let temp = Temp::new();
    fs::create_dir(temp.0.join("threads")).unwrap();
    fs::create_dir(temp.0.join("transcripts")).unwrap();
    let old = b"{ \"legacy\": 1e3 }\nmalformed legacy row\n";
    fs::write(temp.thread(), old).unwrap();
    fs::write(temp.transcript(), old).unwrap();
    let mut store = History::open(&temp.0).unwrap();
    assert_eq!(store.request(&request("first", "card"))["stored"], true);
    assert_eq!(
        store.request(&request("repeat-call", "card"))["stored"],
        true
    );
    let expected = [
        old.as_slice(),
        line("card").as_slice(),
        line("card").as_slice(),
    ]
    .concat();
    assert_eq!(fs::read(temp.thread()).unwrap(), expected);
    assert_eq!(fs::read(temp.transcript()).unwrap(), expected);
}
#[test]
fn original_transaction_retry_is_idempotent_and_conflicting_body_or_targets_cannot_retarget_it() {
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    let first = store.request(&request("original", "text"));
    assert_eq!(first["stored"], true);
    assert_eq!(store.request(&request("original", "text")), first);
    assert_eq!(fs::read(temp.thread()).unwrap(), line("text"));
    assert_eq!(
        store.request(&request("original", "changed"))["error"],
        "conflicting-history-operation"
    );
    let mut changed = request("original", "text");
    changed["thread"] = json!(false);
    assert_eq!(
        store.request(&changed)["error"],
        "conflicting-history-operation"
    );
    assert_eq!(store.request(&request("new", "new text"))["stored"], true);
}
#[test]
fn restart_finishes_second_projection_and_partial_append_without_duplicating_first() {
    for suffix in [Vec::new(), line("accepted")[..17].to_vec()] {
        let temp = Temp::new();
        let mut store = History::open(&temp.0).unwrap();
        store.request(&request("crashed", "accepted"));
        drop(store);
        temp.uncommit();
        fs::write(temp.transcript(), &suffix).unwrap();
        let mut recovered = History::open(&temp.0).unwrap();
        assert_eq!(fs::read(temp.thread()).unwrap(), line("accepted"));
        assert_eq!(fs::read(temp.transcript()).unwrap(), line("accepted"));
        assert_eq!(
            recovered.request(&request("crashed", "accepted"))["stored"],
            true
        );
        assert_eq!(fs::read(temp.thread()).unwrap(), line("accepted"));
    }
}
#[test]
fn incomplete_legacy_tail_is_retained_in_exact_private_backup_before_only_tail_is_removed() {
    let temp = Temp::new();
    fs::create_dir(temp.0.join("threads")).unwrap();
    let old = b"{\"old\":true}\n{\"unfinished";
    fs::write(temp.thread(), old).unwrap();
    let mut store = History::open(&temp.0).unwrap();
    assert_eq!(fs::read(temp.thread()).unwrap(), old);
    assert_eq!(store.request(&request("new", "text"))["stored"], true);
    let backup = fs::read_dir(temp.0.join("threads"))
        .unwrap()
        .map(|item| item.unwrap().path())
        .find(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(".history-recovery.")
        })
        .unwrap();
    assert_eq!(fs::read(&backup).unwrap(), old);
    assert_eq!(
        fs::read(temp.thread()).unwrap(),
        [b"{\"old\":true}\n".as_slice(), line("text").as_slice()].concat()
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(backup).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
#[test]
fn ambiguous_recovery_never_truncates_changed_complete_bytes_and_corrupt_intents_remain() {
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    store.request(&request("crashed", "accepted"));
    drop(store);
    temp.uncommit();
    let changed = b"other writer's complete row\n";
    fs::write(temp.transcript(), changed).unwrap();
    assert!(History::open(&temp.0).is_err());
    assert_eq!(fs::read(temp.transcript()).unwrap(), changed);
    assert_eq!(fs::read(temp.thread()).unwrap(), line("accepted"));
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    store.request(&request("valid", "accepted"));
    drop(store);
    let intent = temp.intents().remove(0);
    let original = fs::read(&intent).unwrap();
    let corrupt = String::from_utf8(original)
        .unwrap()
        .replace("accepted", "tampered");
    fs::write(&intent, &corrupt).unwrap();
    assert!(History::open(&temp.0).is_err());
    assert_eq!(fs::read_to_string(intent).unwrap(), corrupt);
}
#[test]
fn bounded_batches_preserve_event_order_and_mixed_destinations_or_oversized_input_fail_closed() {
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    let events: Vec<_> = (0..1024).map(|i| event(&i.to_string())).collect();
    assert_eq!(store.request(&json!({"op":"history_append","operationId":"batch","events":events,"thread":true,"transcript":true}))["stored"], true);
    let bytes = fs::read(temp.thread()).unwrap();
    assert_eq!(bytes.iter().filter(|byte| **byte == b'\n').count(), 1024);
    assert_eq!(fs::read(temp.transcript()).unwrap(), bytes);
    let mut changed = event("different");
    changed["threadId"] = json!("other");
    assert!(store.request(&json!({"op":"history_append","operationId":"mixed","events":[event("one"),changed],"thread":true})).get("error").is_some());
    assert_eq!(fs::read(temp.thread()).unwrap(), bytes);
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    assert!(store.request(&json!({"op":"history_append","operationId":"too-many","events":vec![event("text");1025],"thread":true})).get("error").is_some());
    assert!(!temp.thread().exists());
}
#[test]
fn writer_exclusion_and_oversized_originals_are_retained_without_acknowledgement() {
    let temp = Temp::new();
    let store = History::open(&temp.0).unwrap();
    assert!(History::open(&temp.0).is_err());
    drop(store);
    assert!(History::open(&temp.0).is_ok());
    let temp = Temp::new();
    fs::create_dir(temp.0.join("threads")).unwrap();
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(temp.thread())
        .unwrap()
        .set_len(1024 * 1024 * 1024 + 1)
        .unwrap();
    let mut store = History::open(&temp.0).unwrap();
    assert!(
        store
            .request(&request("large", "text"))
            .get("error")
            .is_some()
    );
    assert_eq!(
        fs::metadata(temp.thread()).unwrap().len(),
        1024 * 1024 * 1024 + 1
    );
}
#[test]
fn actual_worker_termination_after_ack_keeps_both_projections_and_original_retry() {
    let temp = Temp::new();
    let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .args(["history", temp.0.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut req = request("acknowledged", "text");
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
    let mut recovered = History::open(&temp.0).unwrap();
    assert_eq!(
        recovered.request(&request("acknowledged", "text"))["stored"],
        true
    );
    assert_eq!(fs::read(temp.thread()).unwrap(), line("text"));
    assert_eq!(fs::read(temp.transcript()).unwrap(), line("text"));
}
#[cfg(unix)]
#[test]
fn symlink_targets_and_transaction_paths_are_refused_without_changing_existing_permissions() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let temp = Temp::new();
    fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o755)).unwrap();
    fs::create_dir(temp.0.join("threads")).unwrap();
    fs::write(temp.0.join("original"), "saved bytes").unwrap();
    symlink(temp.0.join("original"), temp.thread()).unwrap();
    let mut store = History::open(&temp.0).unwrap();
    assert!(
        store
            .request(&request("link", "text"))
            .get("error")
            .is_some()
    );
    assert_eq!(
        fs::read_to_string(temp.0.join("original")).unwrap(),
        "saved bytes"
    );
    assert_eq!(
        fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777,
        0o755
    );
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    assert_eq!(store.request(&request("private", "text"))["stored"], true);
    assert_eq!(
        fs::metadata(temp.thread()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    drop(store);
    let intent = temp.intents().remove(0);
    fs::remove_file(&intent).unwrap();
    symlink(temp.0.join("missing"), &intent).unwrap();
    assert!(History::open(&temp.0).is_err());
}

#[test]
fn control_events_are_transcript_only_and_calendar_days_handle_negative_leap_and_current_dates() {
    let temp = Temp::new();
    let mut store = History::open(&temp.0).unwrap();
    for (id, ts, day) in [
        ("negative", -1i64, "1969-12-31"),
        ("leap", 951782400000, "2000-02-29"),
        ("current", 1790812800000, "2026-10-01"),
    ] {
        let mut control = event("control");
        control["threadId"] = json!("");
        control["ts"] = json!(ts);
        control["kind"] = json!("device_list");
        assert_eq!(
            store.request(
                &json!({"op":"history_append","operationId":id,"event":control,"transcript":true})
            )["stored"],
            true
        );
        assert!(temp.0.join(format!("transcripts/{day}.jsonl")).exists());
    }
    assert!(!temp.0.join("threads").exists());
    drop(store);
    assert!(History::open(&temp.0).is_ok());
}

#[test]
fn real_owner_large_results_are_bounded_and_tokens_cannot_consume_or_replay_another_result() {
    let temp = Temp::new();
    fs::create_dir(temp.0.join("threads")).unwrap();
    let expected = event(&"日本語🙂".repeat(100_000));
    let original = format!("{expected}\n");
    fs::write(temp.thread(), &original).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .arg("history")
        .arg(&temp.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    fn call(input: &mut impl Write, output: &mut impl BufRead, mut request: Value) -> Value {
        let id = "request";
        request["id"] = json!(id);
        writeln!(input, "{request}").unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        let frame: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(frame["id"], id);
        frame["result"].clone()
    }
    let query =
        json!({"op":"history_page","threadId":"thread","minTs":0,"includeApprovalStatus":true});
    let proof = call(&mut input, &mut output, query.clone());
    assert!(
        proof["responseBytes"]
            .as_u64()
            .is_some_and(|n| n > 1024 * 1024 && n <= 34 * 1024 * 1024)
    );
    assert!(
        call(
            &mut input,
            &mut output,
            json!({"op":"bridge_result","token":"wrong"})
        )
        .get("error")
        .is_some()
    );
    let result = call(
        &mut input,
        &mut output,
        json!({"op":"bridge_result","token":proof["bridgeToken"]}),
    );
    assert_eq!(result["events"][0]["data"], expected["data"]);
    assert!(result["events"][0]["syncCursor"].is_string());
    assert!(
        call(
            &mut input,
            &mut output,
            json!({"op":"bridge_result","token":proof["bridgeToken"]})
        )
        .get("error")
        .is_some()
    );
    let obsolete = call(&mut input, &mut output, query.clone());
    let replacement = call(&mut input, &mut output, query.clone());
    assert_ne!(obsolete["bridgeToken"], replacement["bridgeToken"]);
    assert!(
        call(
            &mut input,
            &mut output,
            json!({"op":"bridge_result","token":obsolete["bridgeToken"]})
        )
        .get("error")
        .is_some()
    );
    assert_eq!(
        call(&mut input, &mut output, json!({"op":"history_open"}))["stored"],
        true
    );
    assert!(
        call(
            &mut input,
            &mut output,
            json!({"op":"bridge_result","token":replacement["bridgeToken"]})
        )
        .get("error")
        .is_some()
    );
    drop(input);
    assert!(child.wait().unwrap().success());
    let mut restarted = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .arg("history")
        .arg(&temp.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = restarted.stdin.take().unwrap();
    let mut output = BufReader::new(restarted.stdout.take().unwrap());
    let fresh = call(&mut input, &mut output, query);
    assert!(
        call(
            &mut input,
            &mut output,
            json!({"op":"bridge_result","token":proof["bridgeToken"]})
        )
        .get("error")
        .is_some()
    );
    assert_eq!(
        call(
            &mut input,
            &mut output,
            json!({"op":"bridge_result","token":fresh["bridgeToken"]})
        )["events"][0]["data"],
        expected["data"]
    );
    drop(input);
    assert!(restarted.wait().unwrap().success());
    assert_eq!(fs::read_to_string(temp.thread()).unwrap(), original);
}

#[test]
fn complete_unterminated_legacy_rows_survive_append_retry_and_restart() {
    for transcript_terminated in [false, true] {
        let temp = Temp::new();
        fs::create_dir(temp.0.join("threads")).unwrap();
        fs::create_dir(temp.0.join("transcripts")).unwrap();
        let old = b"{ \"legacy\": 1e3, \"future\": [true] }";
        fs::write(temp.thread(), old).unwrap();
        let transcript = [
            old.as_slice(),
            if transcript_terminated { b"\n" } else { b"" },
        ]
        .concat();
        fs::write(temp.transcript(), transcript).unwrap();
        let mut store = History::open(&temp.0).unwrap();
        assert_eq!(store.request(&request("new", "next"))["stored"], true);
        let expected = [old.as_slice(), b"\n", line("next").as_slice()].concat();
        assert_eq!(fs::read(temp.thread()).unwrap(), expected);
        assert_eq!(fs::read(temp.transcript()).unwrap(), expected);
        assert_eq!(store.request(&request("new", "next"))["stored"], true);
        drop(store);
        temp.uncommit();
        let mut store = History::open(&temp.0).unwrap();
        assert_eq!(store.request(&request("new", "next"))["stored"], true);
        assert_eq!(fs::read(temp.thread()).unwrap(), expected);
        assert_eq!(fs::read(temp.transcript()).unwrap(), expected);
    }
}

#[test]
fn unsupported_legacy_tails_refuse_append_without_changing_visible_bytes() {
    for tail in [br#"{"legacy":"\ud800"}"#.as_slice(), br#"{"legacy":1e400}"#] {
        let temp = Temp::new();
        fs::create_dir(temp.0.join("threads")).unwrap();
        fs::write(temp.thread(), tail).unwrap();
        let mut store = History::open(&temp.0).unwrap();
        assert_ne!(store.request(&request("new", "next"))["stored"], true);
        assert_eq!(fs::read(temp.thread()).unwrap(), tail);
        assert!(temp.intents().is_empty());
    }
}

#[test]
fn normalized_legacy_row_does_not_accept_event_when_second_projection_fails() {
    let temp = Temp::new();
    fs::create_dir(temp.0.join("threads")).unwrap();
    fs::create_dir(temp.0.join("transcripts")).unwrap();
    fs::create_dir(temp.transcript()).unwrap();
    let old = br#"{ "legacy": 1e3 }"#;
    fs::write(temp.thread(), old).unwrap();
    let mut store = History::open(&temp.0).unwrap();
    assert_ne!(store.request(&request("new", "next"))["stored"], true);
    assert_eq!(
        fs::read(temp.thread()).unwrap(),
        [old.as_slice(), b"\n"].concat()
    );
    assert!(temp.intents().is_empty());
    drop(store);
    fs::remove_dir(temp.transcript()).unwrap();
    let mut store = History::open(&temp.0).unwrap();
    assert_eq!(store.request(&request("new", "next"))["stored"], true);
    assert_eq!(
        fs::read(temp.thread()).unwrap(),
        [old.as_slice(), b"\n", line("next").as_slice()].concat()
    );
}
