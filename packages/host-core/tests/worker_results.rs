use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{history::History, now_ms};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-worker-result-{}-{}-{}",
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
fn setup(temp: &Temp, ts: u64) -> (History, Value) {
    let mut host = History::open(&temp.0).unwrap();
    assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":null,"threads":[{"id":"thread","title":"Work","createdAt":"2026-01-01T00:00:00Z","archived":false,"agent":"codex"}]}))["stored"],true);
    let event = json!({"id":"origin","threadId":"thread","ts":ts,"agentId":"phone","kind":"message","data":{"role":"user","text":"work"}});
    assert_eq!(host.request(&json!({"op":"accepted_accept","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"purpose":"conversation","event":event}}))["status"],"accepted");
    assert_eq!(host.request(&json!({"op":"history_append","operationId":"origin","event":event,"thread":true,"transcript":true}))["stored"],true);
    assert_eq!(
        host.request(&json!({"op":"queue_enqueue","eventId":"origin","threadId":"thread"}))["stored"],
        true
    );
    let claim =
        host.request(&json!({"op":"run_attempt_claim","threadId":"thread","eventId":"origin"}));
    assert_eq!(claim["claimed"], true);
    (host, claim)
}
fn packet(claim: &Value, outcome: &str, evidence: &str) -> Value {
    json!({"op":"run_attempt_result","contractVersion":1,"threadId":"thread","eventId":"origin","turnId":"native:origin:final","attemptId":claim["attemptId"],"agent":"codex","outcome":outcome,"evidence":evidence,"text":"answer","failed":false})
}
fn stop(host: &mut History, ids: Value) {
    assert!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"requested","partialText":"partial","requestIds":ids,"future":{"kept":true}}}))["record"].is_object());
}
#[test]
fn worker_results_require_owned_cessation_and_preserve_replacement_metadata() {
    for guard in [
        "settled",
        "returned-completed",
        "failed-completed",
        "replacement",
        "agent",
        "valid",
    ] {
        let temp = Temp::new();
        let (mut host, claim) = setup(&temp, now_ms());
        if guard == "replacement" {
            assert_eq!(host.request(&json!({"op":"run_attempt_release","threadId":"thread","eventId":"origin","attemptId":claim["attemptId"]}))["released"],true);
            let bytes = fs::read(temp.0.join("threads.json")).unwrap();
            let snapshot = json!({"threads":serde_json::from_slice::<Value>(&bytes).unwrap(),"hash":format!("{:x}",Sha256::digest(&bytes))});
            let mut rows = snapshot["threads"].clone();
            rows[0].as_object_mut().unwrap().remove("nativeTurn");
            assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":snapshot["hash"],"threads":rows}))["stored"],true);
            assert_eq!(
                host.request(
                    &json!({"op":"run_attempt_claim","threadId":"thread","eventId":"origin"})
                )["claimed"],
                true
            );
        }
        if guard == "agent" {
            let bytes = fs::read(temp.0.join("threads.json")).unwrap();
            let snapshot = json!({"threads":serde_json::from_slice::<Value>(&bytes).unwrap(),"hash":format!("{:x}",Sha256::digest(&bytes))});
            let mut rows = snapshot["threads"].clone();
            rows[0]["agent"] = json!("claude-code");
            // Model an out-of-process metadata change; the public CAS correctly refuses
            // changing an active worker's source, and Root must also guard retained bytes.
            fs::write(
                temp.0.join("threads.json"),
                serde_json::to_vec(&rows).unwrap(),
            )
            .unwrap();
        }
        stop(&mut host, json!(["stop"]));
        let metadata = fs::read(temp.0.join("threads.json")).unwrap();
        let mut request = packet(
            &claim,
            "stopped",
            if guard == "settled" {
                "unconfirmed"
            } else {
                "provider-terminal"
            },
        );
        if guard == "returned-completed" {
            request["outcome"] = json!("completed");
            request["evidence"] = json!("returned");
        }
        if guard == "failed-completed" {
            request["outcome"] = json!("completed");
            request["failed"] = json!(true);
        }
        let proof = host.request(&request);
        assert_eq!(proof["stopConfirmed"], true, "{guard}: {proof}");
        assert_eq!(
            proof["record"]["status"],
            if guard == "valid" {
                "stopped"
            } else {
                "unconfirmed"
            },
            "{guard}: {proof}"
        );
        assert_eq!(proof["stored"], guard == "valid", "{proof}");
        assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), metadata);
        assert_eq!(
            host.request(&json!({"op":"queue_head","threadId":"thread"}))["eventId"],
            "origin"
        );
    }
}
#[test]
fn worker_result_replay_keeps_original_bytes_and_rejects_conflicting_results() {
    let temp = Temp::new();
    let (mut host, claim) = setup(&temp, now_ms());
    let request = packet(&claim, "completed", "returned");
    let mut malformed = request.clone();
    malformed["failed"] = json!("true");
    assert!(host.request(&malformed).get("error").is_some());
    let first = host.request(&request);
    assert_eq!(first["stored"], true, "{first}");
    let original = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    let mut alternate = request.clone();
    alternate["text"] = json!("different");
    assert_eq!(host.request(&alternate)["stored"], false);
    drop(host);
    let mut host = History::open(&temp.0).unwrap();
    let again = host.request(&request);
    assert_eq!(again["stored"], true, "{again}");
    assert_eq!(again["final"], first["final"]);
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        original
    );
    stop(&mut host, json!(["stop", "second"]));
    let late = host.request(&request);
    assert_eq!(late["record"]["status"], "completed", "{late}");
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        original
    );
    assert_eq!(host.request(&json!({"op":"history_append","operationId":"worker-result:forged","event":first["final"],"thread":true,"transcript":true}))["error"],"reserved-history-operation");
}

#[test]
fn worker_final_survives_stop_status_failure_and_replays_after_restart() {
    let temp = Temp::new();
    let (mut host, claim) = setup(&temp, now_ms());
    stop(&mut host, json!(["first"]));
    let path = temp.0.join("stopped-turns.jsonl");
    let backup = temp.0.join("stop-backup.jsonl");
    fs::rename(&path, &backup).unwrap();
    fs::create_dir(&path).unwrap();
    let request = packet(&claim, "stopped", "process-exited");
    let first = host.request(&request);
    assert_eq!(first["stored"], true, "{first}");
    assert_eq!(first["stopConfirmed"], false);
    assert_eq!(first["record"]["status"], "requested");
    let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    let metadata = fs::read(temp.0.join("threads.json")).unwrap();
    drop(host);
    fs::remove_dir(&path).unwrap();
    fs::rename(&backup, &path).unwrap();
    let mut host = History::open(&temp.0).unwrap();
    stop(&mut host, json!(["first", "second"]));
    let retry = host.request(&request);
    assert_eq!(retry["stored"], true, "{retry}");
    assert_eq!(retry["stopConfirmed"], true);
    assert_eq!(retry["record"]["status"], "stopped");
    assert_eq!(retry["final"], first["final"]);
    assert_eq!(retry["record"]["requestIds"], json!(["first", "second"]));
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        history
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), metadata);
}

#[test]
fn terminal_stop_never_authorizes_a_fresh_conflicting_worker_final() {
    for status in ["stopped", "completed", "withdrawn"] {
        let temp = Temp::new();
        let (mut host, claim) = setup(&temp, now_ms());
        assert_eq!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":status,"requestIds":["stop"]}}))["record"]["status"],status);
        let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        for outcome in ["completed", "stopped"] {
            let proof = host.request(&packet(&claim, outcome, "provider-terminal"));
            assert_eq!(proof["stored"], false, "{proof}");
            assert_eq!(proof["stopConfirmed"], true);
            assert_eq!(proof["record"]["status"], status);
            assert_eq!(
                fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
                history
            );
        }
    }
}
