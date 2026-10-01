use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{now_ms, outbox::ChannelOutbox};

static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-outbox-{}-{}-{}",
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
fn message() -> Value {
    json!({"id":"m","threadId":"t","ts":1,"text":"hello","replyContext":{"id":"quote","text":"quoted","sender":"Agent"},"legacyExtra":{"kept":true}})
}
fn write(temp: &Temp, name: &str, value: Value) {
    fs::write(temp.0.join(name), serde_json::to_vec(&value).unwrap()).unwrap();
}

#[test]
fn legacy_unknown_fields_and_original_bytes_survive_open() {
    let temp = Temp::new();
    let raw = format!("[\n {}\n]", message());
    fs::write(temp.0.join("channel-outbox.json"), &raw).unwrap();
    let store = ChannelOutbox::open(&temp.0).unwrap();
    assert_eq!(store.get("m"), Some(message()));
    assert_eq!(
        fs::read_to_string(temp.0.join("channel-outbox.json")).unwrap(),
        raw
    );
    assert!(ChannelOutbox::open(&temp.0).is_err());
    drop(store);
    assert!(ChannelOutbox::open(&temp.0).is_ok());
}

#[test]
fn duplicate_identity_is_bound_and_conflicts_do_not_overwrite() {
    let temp = Temp::new();
    let mut store = ChannelOutbox::open(&temp.0).unwrap();
    store.enqueue(message()).unwrap();
    store.enqueue(message()).unwrap();
    let raw = fs::read(temp.0.join("channel-outbox.json")).unwrap();
    let mut conflicting = message();
    conflicting["text"] = json!("different");
    assert!(store.enqueue(conflicting).is_err());
    assert_eq!(fs::read(temp.0.join("channel-outbox.json")).unwrap(), raw);
    assert_eq!(store.snapshot()["outbox"].as_array().unwrap().len(), 1);
}

#[test]
fn preparation_intent_recovers_interrupted_second_write_without_restoring_pin() {
    let temp = Temp::new();
    let mut original = message();
    original["channelModel"] = json!({"model":"a"});
    write(&temp, "channel-outbox.json", json!([original]));
    write(
        &temp,
        "channel-model-delivery.json",
        json!({"m":"prepared"}),
    );
    let mut store = ChannelOutbox::open(&temp.0).unwrap();
    store.prepared("m").unwrap();
    assert!(store.get("m").unwrap().get("channelModel").is_none());
    let mut conflicting = original.clone();
    conflicting["channelModel"] = json!({"model":"different"});
    assert!(store.enqueue(conflicting).is_err());
    store.enqueue(original).unwrap();
    store.acknowledge("m").unwrap();
    drop(store);
    let mut store = ChannelOutbox::open(&temp.0).unwrap();
    store.enqueue(message()).unwrap();
    assert!(store.get("m").is_none());
    assert_eq!(store.snapshot()["modelDelivery"]["m"], "delivered");
}

#[test]
fn delivered_intent_recovers_interrupted_outbox_removal() {
    let temp = Temp::new();
    write(&temp, "channel-outbox.json", json!([message()]));
    write(
        &temp,
        "channel-model-delivery.json",
        json!({"m":"delivered"}),
    );
    let store = ChannelOutbox::open(&temp.0).unwrap();
    assert!(store.get("m").is_none());
    assert_eq!(
        serde_json::from_slice::<Value>(&fs::read(temp.0.join("channel-outbox.json")).unwrap())
            .unwrap(),
        json!([])
    );
}

#[test]
fn uncertain_reply_survives_actual_worker_kill_and_cannot_be_rejected_or_withdrawn() {
    let temp = Temp::new();
    let mut worker = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .arg("attachments")
        .arg(&temp.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = worker.stdin.take().unwrap();
    let mut output = BufReader::new(worker.stdout.take().unwrap());
    for (id, op) in [
        ("enqueue", "outbox_enqueue"),
        ("attempt", "outbox_attempted"),
    ] {
        writeln!(
            input,
            "{}",
            json!({"id":id,"op":op,"message":message(),"messageId":"m"})
        )
        .unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        let frame: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(frame["id"], id);
        assert!(frame["result"].get("error").is_none());
    }
    worker.kill().unwrap();
    worker.wait().unwrap();
    let mut store = ChannelOutbox::open(&temp.0).unwrap();
    assert_eq!(store.get("m").unwrap()["replyAttempted"], true);
    assert!(store.reject("m").is_err());
    assert!(store.withdraw("m").is_err());
    store.enqueue(message()).unwrap();
    assert_eq!(store.get("m").unwrap()["legacyExtra"]["kept"], true);
}

#[test]
fn withdrawal_tombstone_and_prior_host_journal_prevent_redispatch() {
    let temp = Temp::new();
    let mut store = ChannelOutbox::open(&temp.0).unwrap();
    store.enqueue(message()).unwrap();
    store.withdraw("m").unwrap();
    drop(store);
    write(&temp, "channel-outbox.json", json!([message()]));
    let mut store = ChannelOutbox::open(&temp.0).unwrap();
    assert!(store.get("m").is_none());
    store.enqueue(message()).unwrap();
    assert!(store.get("m").is_none());
    drop(store);
    fs::remove_file(temp.0.join("channel-cancelled.json")).unwrap();
    write(&temp, "channel-outbox.json", json!([message()]));
    fs::write(temp.0.join("stopped-turns.jsonl"),"{\"targetEventId\":\"m\",\"threadId\":\"t\",\"status\":\"withdrawn\",\"requestIds\":[\"stop\"]}\n{partial").unwrap();
    assert!(ChannelOutbox::open(&temp.0).unwrap().get("m").is_none());
}

#[test]
fn malformed_and_conflicting_legacy_data_remain_untouched() {
    let temp = Temp::new();
    let raw = b"[{broken";
    fs::write(temp.0.join("channel-outbox.json"), raw).unwrap();
    assert!(ChannelOutbox::open(&temp.0).is_err());
    assert_eq!(fs::read(temp.0.join("channel-outbox.json")).unwrap(), raw);
    write(&temp, "channel-outbox.json", json!([message(), message()]));
    let raw = fs::read(temp.0.join("channel-outbox.json")).unwrap();
    assert!(ChannelOutbox::open(&temp.0).is_err());
    assert_eq!(fs::read(temp.0.join("channel-outbox.json")).unwrap(), raw);
}

#[test]
fn withdrawal_from_another_thread_cannot_remove_existing_data() {
    let temp = Temp::new();
    write(&temp, "channel-outbox.json", json!([message()]));
    let original = fs::read(temp.0.join("channel-outbox.json")).unwrap();
    fs::write(temp.0.join("stopped-turns.jsonl"),"{\"targetEventId\":\"m\",\"threadId\":\"another\",\"status\":\"withdrawn\",\"requestIds\":[\"stop\"]}\n").unwrap();
    assert!(ChannelOutbox::open(&temp.0).is_err());
    assert_eq!(
        fs::read(temp.0.join("channel-outbox.json")).unwrap(),
        original
    );
}

#[test]
fn repeated_ack_is_idempotent_and_metadata_snapshot_excludes_attachment_bytes() {
    let temp = Temp::new();
    let mut store = ChannelOutbox::open(&temp.0).unwrap();
    let mut payload = message();
    payload["attachments"] = json!([{"name":"large","data":"X".repeat(2*1024*1024)}]);
    store.enqueue(payload.clone()).unwrap();
    assert!(serde_json::to_vec(&store.snapshot()).unwrap().len() < 1000);
    assert_eq!(store.get("m"), Some(payload));
    store.acknowledge("m").unwrap();
    store.acknowledge("m").unwrap();
    drop(store);
    assert!(ChannelOutbox::open(&temp.0).unwrap().get("m").is_none());
}
