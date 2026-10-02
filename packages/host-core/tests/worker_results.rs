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

#[test]
fn result_cleanup_cannot_pause_or_retire_a_different_worker_source() {
    for op in ["run_attempt_pause", "run_attempt_finish"] {
        let temp = Temp::new();
        let (mut host, claim) = setup(&temp, now_ms());
        if op == "run_attempt_finish" {
            let result = host.request(&packet(&claim, "completed", "returned"));
            assert_eq!(result["stored"], true);
        }
        let path = temp.0.join("threads.json");
        let mut rows: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        rows[0]["agent"] = json!("claude-code");
        fs::write(&path, serde_json::to_vec(&rows).unwrap()).unwrap();
        let metadata = fs::read(&path).unwrap();
        let proof=host.request(&json!({"op":op,"threadId":"thread","eventId":"origin","turnId":"native:origin:final","attemptId":claim["attemptId"]}));
        assert_eq!(proof["applied"], false, "{op}: {proof}");
        assert_eq!(proof["reason"], "scope-replaced");
        assert_eq!(fs::read(&path).unwrap(), metadata);
        assert_eq!(
            host.request(&json!({"op":"queue_head","threadId":"thread"}))["eventId"],
            "origin"
        );
    }
}

fn changed_paused_source(temp: &Temp) -> (History, Value, Value) {
    let (mut host, claim) = setup(temp, now_ms());
    assert_eq!(host.request(&json!({"op":"run_attempt_pause","threadId":"thread","eventId":"origin","turnId":"native:origin:final","attemptId":claim["attemptId"]}))["applied"],true);
    let path = temp.0.join("threads.json");
    let mut rows: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    rows[0]["agent"] = json!("claude-code");
    fs::write(&path, serde_json::to_vec(&rows).unwrap()).unwrap();
    (host, claim, rows[0]["nativeTurn"].clone())
}
#[test]
fn native_controls_preserve_a_live_registry_with_a_different_source() {
    for op in [
        "run_turn_retry",
        "run_turn_dismiss",
        "run_turn_stop_clear",
        "run_turn_rewind",
        "run_attempt_claim",
    ] {
        let temp = Temp::new();
        let (mut host, claim, marker) = changed_paused_source(&temp);
        if op == "run_turn_stop_clear" {
            assert_eq!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"unconfirmed","requestIds":["stop"]}}))["record"]["status"],"unconfirmed");
        }
        if op == "run_turn_rewind" {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"rewind","thread":true,"transcript":true,"event":{"id":"rewind","threadId":"thread","ts":now_ms(),"agentId":"main","kind":"thread_rewound","data":{"requestId":"edit","eventId":"origin","hiddenEventIds":["origin"]}}}))["stored"],true);
        }
        let metadata = fs::read(temp.0.join("threads.json")).unwrap();
        let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        let proof=host.request(&json!({"op":op,"threadId":"thread","eventId":"origin","turnId":"native:origin:final","attemptId":claim["attemptId"],"expectedTurn":marker,"rewindId":"rewind","requestId":"edit"}));
        assert_ne!(proof["applied"], true, "{op}: {proof}");
        assert_ne!(proof["claimed"], true, "{op}: {proof}");
        assert_eq!(
            fs::read(temp.0.join("threads.json")).unwrap(),
            metadata,
            "{op}: {proof}"
        );
        assert_eq!(
            fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
            history
        );
        let head = host.request(&json!({"op":"queue_head","threadId":"thread"}));
        if op == "run_turn_rewind" {
            assert_eq!(proof["queueConfirmed"], true);
            assert!(head["eventId"].is_null());
        } else {
            assert_eq!(head["eventId"], "origin");
        }
        assert_eq!(host.request(&json!({"op":"run_attempt_release","threadId":"thread","eventId":"origin","attemptId":claim["attemptId"]}))["released"],true);
    }
}
#[test]
fn preflight_cannot_publish_a_failure_for_a_different_live_worker_source() {
    let temp = Temp::new();
    let (mut host, _, marker) = changed_paused_source(&temp);
    let metadata = fs::read(temp.0.join("threads.json")).unwrap();
    let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    let proof=host.request(&json!({"op":"run_turn_preflight_finish","threadId":"thread","eventId":"origin","expectedTurn":marker,"reason":"missing-runner","ts":now_ms()}));
    assert_eq!(proof["stored"], false, "{proof}");
    assert_eq!(proof["applied"], false);
    assert_eq!(proof["reason"], "scope-replaced");
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), metadata);
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        history
    );
}
