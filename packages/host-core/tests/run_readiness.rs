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
        let root = std::env::temp_dir().join(format!(
            "yorozu-run-ready-{}-{}-{}",
            std::process::id(),
            now_ms(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn index() -> Value {
    json!([{"id":"thread","title":"Work","createdAt":"2026-01-01T00:00:00Z","archived":false,"agent":"codex","future":{"kept":true}}])
}
fn open(temp: &Temp) -> (History, Value) {
    let mut host = History::open(&temp.0).unwrap();
    let proof =
        host.request(&json!({"op":"thread_index_replace","expectedHash":null,"threads":index()}));
    assert_eq!(proof["stored"], true);
    (host, proof["hash"].clone())
}
fn seed(host: &mut History, id: &str, purpose: &str) {
    let event = json!({"id":id,"threadId":"thread","ts":1000,"agentId":"phone","kind":"message","data":{"role":"user","text":"keep this","future":{"kept":true}}});
    assert_eq!(host.request(&json!({"op":"accepted_accept","entry":{"id":id,"threadId":"thread","identity":"a".repeat(64),"purpose":purpose,"event":event}}))["status"], "accepted");
    assert_eq!(host.request(&json!({"op":"history_append","operationId":format!("origin:{id}"),"event":event,"thread":true,"transcript":true}))["stored"], true);
    assert_eq!(
        host.request(&json!({"op":"queue_enqueue","eventId":id,"threadId":"thread"}))["stored"],
        true
    );
}
fn ready(host: &mut History, id: &str) -> Value {
    host.request(&json!({"op":"run_ready","threadId":"thread","eventId":id}))
}
#[test]
fn immutable_legacy_purpose_can_recover_but_terminal_evidence_prevents_repeat_execution() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "legacy");
    assert_eq!(
        ready(&mut host, "origin"),
        json!({"ready":true,"eventId":"origin","threadId":"thread","agent":"codex","completionId":"native:origin:final"})
    );
    assert_eq!(
        host.request(&json!({"op":"accepted_get","messageId":"origin"}))["entry"]["purpose"],
        "legacy"
    );
    assert_eq!(host.request(&json!({"op":"history_append","operationId":"final","thread":true,"transcript":true,"event":{"id":"native:origin:final","threadId":"thread","ts":2000,"agentId":"main","kind":"message","data":{"role":"agent","text":"done","done":true}}}))["stored"],true);
    assert_eq!(ready(&mut host, "origin")["reason"], "already-completed");
    assert_eq!(
        host.request(&json!({"op":"queue_head","threadId":"thread"}))["eventId"],
        "origin"
    );
}
#[test]
fn operational_decisions_refuse_stop_expiration_approval_reply_and_uncertain_effects() {
    for guard in [
        "stop",
        "expiration",
        "approval",
        "follow-up",
        "active",
        "failed-journal",
        "foreign-origin",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        seed(
            &mut host,
            "origin",
            if guard == "approval" {
                "approval-reply"
            } else {
                "conversation"
            },
        );
        let expected = match guard {
            "stop" => {
                assert!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"requested","requestIds":["cancel"]}}))["record"].is_object());
                "stopped"
            }
            "expiration" => {
                assert_eq!(host.request(&json!({"op":"admission_expire","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"deadline":1},"now":2}))["status"],"expired");
                "expired"
            }
            "approval" => "not-accepted-conversation",
            "follow-up" | "active" => {
                let (event, active) = if guard == "active" {
                    ("follow-up", "origin")
                } else {
                    ("origin", "another")
                };
                assert_eq!(host.request(&json!({"op":"steering_begin","record":{"eventId":event,"threadId":"thread","attemptId":"attempt","activeEventId":active,"completionId":format!("native:{active}:final"),"identity":"a".repeat(64)}}))["reserved"],true);
                if guard == "active" {
                    "follow-up-unconfirmed"
                } else {
                    "follow-up-owned"
                }
            }
            "foreign-origin" => {
                let foreign = json!({"id":"origin","threadId":"thread","ts":1000,"agentId":"phone","kind":"message","data":{"role":"user","text":"foreign changed content"}});
                fs::write(temp.0.join("threads/thread.jsonl"), format!("{foreign}\n")).unwrap();
                "run-readiness-unconfirmed"
            }
            _ => {
                // Opening the journal is a confirmed empty snapshot; a foreign path then makes append fail.
                assert!(
                    host.request(&json!({"op":"stop_get","targetEventId":"origin"}))["record"]
                        .is_null()
                );
                fs::write(
                    temp.0.join("stopped-turns.jsonl"),
                    "foreign retained bytes\n",
                )
                .unwrap();
                assert_eq!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"other","threadId":"thread","status":"requested","requestIds":["cancel"]}}))["error"],"stop-storage-failed");
                "stop-storage-failed"
            }
        };
        let proof = ready(&mut host, "origin");
        assert_eq!(
            proof[if guard == "failed-journal" || guard == "foreign-origin" {
                "error"
            } else {
                "reason"
            }],
            expected,
            "{guard}"
        );
        if guard == "failed-journal" {
            assert_eq!(
                fs::read_to_string(temp.0.join("stopped-turns.jsonl")).unwrap(),
                "foreign retained bytes\n"
            );
        }
    }
}
#[test]
fn fifo_and_interrupted_ownership_never_discard_or_overwrite_the_paused_origin() {
    let temp = Temp::new();
    let (mut host, hash) = open(&temp);
    seed(&mut host, "origin", "conversation");
    seed(&mut host, "waiting", "conversation");
    let mut paused = index();
    paused[0]["nativeTurn"] = json!({"id":"native:origin:final","state":"interrupted","userEventId":"origin","recoveryAttempts":3});
    let proof =
        host.request(&json!({"op":"thread_index_replace","expectedHash":hash,"threads":paused}));
    assert_eq!(proof["stored"], true);
    let original = fs::read(temp.0.join("threads.json")).unwrap();
    let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
    assert_eq!(ready(&mut host, "waiting")["reason"], "not-queue-head");
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), original);
    assert_eq!(
        fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
        queue
    );
    assert_eq!(
        host.request(&json!({"op":"queue_remove","eventId":"origin","threadId":"thread"}))["stored"],
        true
    );
    assert_eq!(ready(&mut host, "waiting")["reason"], "another-run-owned");
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), original);
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":proof["hash"],"threads":index()})
        )["stored"],
        true
    );
    assert_eq!(ready(&mut host, "waiting")["ready"], true);
}

#[test]
fn issued_attempts_fence_replaced_stopped_and_restarted_workers_without_losing_evidence() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let claim = |host: &mut History, recovering| {
        host.request(&json!({"op":"run_attempt_claim","threadId":"thread","eventId":"origin","recovering":recovering}))
    };
    let query = |host: &mut History, attempt: &Value, mode| {
        host.request(&json!({"op":"run_attempt_current","threadId":"thread","eventId":"origin","attemptId":attempt,"mode":mode}))
    };
    let first = claim(&mut host, false);
    assert_eq!(first["claimed"], true);
    assert_eq!(first["attemptId"].as_str().unwrap().len(), 32);
    assert_eq!(
        query(&mut host, &first["attemptId"], "effect")["current"],
        true
    );
    let session = |host: &mut History, attempt: &Value, mode, id| {
        host.request(&json!({"op":"run_attempt_session","threadId":"thread","eventId":"origin","attemptId":attempt,"mode":mode,"sessionId":id,"rewindId":null}))
    };
    let stored = session(&mut host, &first["attemptId"], "effect", "first-session");
    assert_eq!(stored["stored"], true);
    let bytes = fs::read(temp.0.join("threads.json")).unwrap();
    let mut forged: Value = serde_json::from_slice(&bytes).unwrap();
    forged[0]["nativeSessionId"] = json!("unscoped-session");
    assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":stored["hash"],"threads":forged,"nativeOwned":true}))["error"], "unscoped-native-session-transition");
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
    assert_eq!(claim(&mut host, false)["reason"], "run-active");
    let read = snapshot(&temp);
    let mut index = read["threads"].clone();
    index[0]["nativeTurn"]["state"] = json!("interrupted");
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
        )["stored"],
        true
    );
    let second = claim(&mut host, false);
    assert_eq!(second["recovering"], true);
    assert_eq!(second["recoveryAttempts"], 1);
    assert_ne!(first["attemptId"], second["attemptId"]);
    assert_eq!(
        session(&mut host, &first["attemptId"], "effect", "stale-session")["current"],
        false
    );
    assert_eq!(
        session(&mut host, &second["attemptId"], "effect", "fresh-session")["stored"],
        true
    );
    assert_eq!(
        query(&mut host, &first["attemptId"], "owned")["current"],
        false
    );
    assert_eq!(host.request(&json!({"op":"run_attempt_release","threadId":"thread","eventId":"origin","attemptId":first["attemptId"]}))["released"], false);
    assert_eq!(
        query(&mut host, &second["attemptId"], "effect")["current"],
        true
    );
    assert!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"requested","requestIds":["cancel"]}}))["record"].is_object());
    let denied = query(&mut host, &second["attemptId"], "effect");
    assert_eq!(denied["current"], false);
    assert_eq!(denied["owned"], true);
    assert_eq!(denied["reason"], "stopped");
    assert_eq!(
        session(&mut host, &second["attemptId"], "owned", "bypass-session")["error"],
        "run-attempt-unconfirmed"
    );
    let bytes = fs::read(temp.0.join("threads.json")).unwrap();
    assert_eq!(
        session(&mut host, &second["attemptId"], "effect", "stopped-effect")["current"],
        false
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
    assert_eq!(
        session(
            &mut host,
            &second["attemptId"],
            "terminal",
            "completed-session"
        )["stored"],
        true
    );
    assert_eq!(
        query(&mut host, &second["attemptId"], "terminal")["current"],
        true
    );
    assert_eq!(
        query(&mut host, &second["attemptId"], "owned")["current"],
        true
    );
    assert_eq!(claim(&mut host, true)["reason"], "stopped");
    let retained = fs::read(temp.0.join("threads.json")).unwrap();
    drop(host);
    let mut host = History::open(&temp.0).unwrap();
    assert_eq!(
        query(&mut host, &second["attemptId"], "owned")["current"],
        false
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), retained);
}

fn snapshot(temp: &Temp) -> Value {
    let bytes = fs::read(temp.0.join("threads.json")).unwrap();
    json!({"threads":serde_json::from_slice::<Value>(&bytes).unwrap(),"hash":format!("{:x}",Sha256::digest(&bytes))})
}
fn pause(host: &mut History, temp: &Temp) -> Value {
    let read = snapshot(temp);
    let mut index = read["threads"].clone();
    index[0]["nativeTurn"] = json!({"id":"native:origin:final","state":"interrupted","userEventId":"origin","recoveryAttempts":3,"pauseReason":"unconfirmed","future":{"kept":true}});
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
        )["stored"],
        true
    );
    json!({"threadId":"thread","turnId":"native:origin:final","eventId":"origin","attemptId":null})
}
fn control(host: &mut History, scope: &Value, action: &str) -> Value {
    let mut request = scope.clone();
    request["op"] = json!(action);
    host.request(&request)
}
#[test]
fn interrupted_controls_repair_only_empty_legacy_queue_and_retain_exact_scope() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "legacy");
    let mut scope = pause(&mut host, &temp);
    assert_eq!(
        host.request(&json!({"op":"queue_remove","threadId":"thread","eventId":"origin"}))["stored"],
        true
    );
    assert_eq!(
        control(&mut host, &scope, "run_turn_retry")["applied"],
        true
    );
    let read = snapshot(&temp);
    assert_eq!(read["threads"][0]["nativeTurn"]["recoveryAttempts"], 0);
    assert!(
        read["threads"][0]["nativeTurn"]
            .get("pauseReason")
            .is_none()
    );
    assert_eq!(read["threads"][0]["nativeTurn"]["future"]["kept"], true);
    let claimed = host.request(
        &json!({"op":"run_attempt_claim","threadId":"thread","eventId":"origin","recovering":true}),
    );
    assert_eq!(claimed["recoveryAttempts"], 1);
    let read = snapshot(&temp);
    let mut index = read["threads"].clone();
    index[0]["nativeTurn"]["state"] = json!("interrupted");
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
        )["stored"],
        true
    );
    let retained = fs::read(temp.0.join("threads.json")).unwrap();
    assert_eq!(
        control(&mut host, &scope, "run_turn_retry")["applied"],
        false
    );
    assert_eq!(
        control(&mut host, &scope, "run_turn_dismiss")["applied"],
        false
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), retained);
    scope["attemptId"] = claimed["attemptId"].clone();
    assert_eq!(
        control(&mut host, &scope, "run_turn_retry")["applied"],
        true
    );
}
#[test]
fn interrupted_retry_respects_operational_policy_and_never_reorders_a_successor() {
    for guard in [
        "stop",
        "expiry",
        "steering",
        "terminal",
        "terminal-without-queue",
        "missing-history",
        "successor",
        "metadata",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        seed(&mut host, "origin", "conversation");
        let scope = pause(&mut host, &temp);
        match guard {
            "stop" => {
                assert!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"requested","requestIds":["cancel"]}}))["record"].is_object());
            }
            "expiry" => {
                assert_eq!(host.request(&json!({"op":"admission_expire","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"deadline":1},"now":2}))["status"], "expired");
            }
            "steering" => {
                assert_eq!(host.request(&json!({"op":"steering_begin","record":{"eventId":"follow-up","threadId":"thread","attemptId":"attempt","activeEventId":"origin","completionId":"native:origin:final","identity":"a".repeat(64)}}))["reserved"], true);
            }
            "terminal" | "terminal-without-queue" => {
                if guard == "terminal-without-queue" {
                    assert_eq!(
                        host.request(
                            &json!({"op":"queue_remove","threadId":"thread","eventId":"origin"})
                        )["stored"],
                        true
                    );
                }
                assert_eq!(host.request(&json!({"op":"history_append","operationId":"final","thread":true,"transcript":true,"event":{"id":"native:origin:final","threadId":"thread","ts":2000,"agentId":"main","kind":"message","data":{"role":"agent","text":"done","done":true}}}))["stored"], true);
            }
            "missing-history" => {
                assert_eq!(
                    host.request(
                        &json!({"op":"queue_remove","threadId":"thread","eventId":"origin"})
                    )["stored"],
                    true
                );
                fs::write(temp.0.join("threads/thread.jsonl"), "").unwrap();
            }
            "successor" => {
                assert_eq!(
                    host.request(
                        &json!({"op":"queue_remove","threadId":"thread","eventId":"origin"})
                    )["stored"],
                    true
                );
                seed(&mut host, "waiting", "conversation");
            }
            _ => {
                fs::write(
                    temp.0.join("threads.json.tmp"),
                    "retained metadata conflict",
                )
                .unwrap();
            }
        }
        let metadata = fs::read(temp.0.join("threads.json")).unwrap();
        let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
        assert_ne!(
            control(&mut host, &scope, "run_turn_retry")["applied"],
            true,
            "{guard}"
        );
        assert_eq!(
            fs::read(temp.0.join("threads.json")).unwrap(),
            metadata,
            "{guard}"
        );
        assert_eq!(
            fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
            queue,
            "{guard}"
        );
    }
}
#[test]
fn dismiss_preserves_failed_queue_then_reports_partial_metadata_without_replaying_work() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let scope = pause(&mut host, &temp);
    let metadata = fs::read(temp.0.join("threads.json")).unwrap();
    let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
    fs::write(
        temp.0.join("native-turn-queue.json.tmp"),
        "retained queue conflict",
    )
    .unwrap();
    assert_eq!(
        control(&mut host, &scope, "run_turn_dismiss")["applied"],
        false
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), metadata);
    assert_eq!(
        fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
        queue
    );
    fs::remove_file(temp.0.join("native-turn-queue.json.tmp")).unwrap();
    fs::write(
        temp.0.join("threads.json.tmp"),
        "retained metadata conflict",
    )
    .unwrap();
    let partial = control(&mut host, &scope, "run_turn_dismiss");
    assert_eq!(
        partial,
        json!({"applied":false,"queueRemoved":true,"reason":"metadata-unconfirmed"})
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), metadata);
    assert_eq!(
        host.request(&json!({"op":"queue_head","threadId":"thread"}))["eventId"],
        Value::Null
    );
    fs::remove_file(temp.0.join("threads.json.tmp")).unwrap();
    assert_eq!(
        control(&mut host, &scope, "run_turn_retry")["applied"],
        true
    );
    assert_eq!(
        control(&mut host, &scope, "run_turn_dismiss")["applied"],
        true
    );
    assert!(snapshot(&temp)["threads"][0].get("nativeTurn").is_none());
    assert!(host.request(&json!({"op":"accepted_get","messageId":"origin"}))["entry"].is_object());
}
#[test]
fn no_origin_legacy_dismiss_still_refuses_a_matching_stop() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "legacy");
    let mut scope = pause(&mut host, &temp);
    let read = snapshot(&temp);
    let mut index = read["threads"].clone();
    index[0]["nativeTurn"]
        .as_object_mut()
        .unwrap()
        .remove("userEventId");
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
        )["stored"],
        true
    );
    scope["eventId"] = Value::Null;
    assert!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"requested","requestIds":["cancel"]}}))["record"].is_object());
    let metadata = fs::read(temp.0.join("threads.json")).unwrap();
    assert_eq!(
        control(&mut host, &scope, "run_turn_dismiss")["reason"],
        "stopped"
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), metadata);
}

#[test]
fn claim_budget_comes_from_retained_state_and_explicit_retry_not_caller_flags() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let claim = |host: &mut History, requested| {
        host.request(&json!({"op":"run_attempt_claim","threadId":"thread","eventId":"origin","recovering":requested}))
    };
    let first = claim(&mut host, true);
    assert_eq!(first["recovering"], false);
    assert_eq!(first["recoveryAttempts"], 0);
    for count in 1..=3 {
        let bytes = fs::read(temp.0.join("threads.json")).unwrap();
        assert_eq!(claim(&mut host, false)["reason"], "run-active");
        assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
        let read = snapshot(&temp);
        let mut index = read["threads"].clone();
        index[0]["nativeTurn"]["state"] = json!("interrupted");
        if count == 3 {
            index[0]["nativeTurn"]["recoveryAttempts"] = json!(2.0);
        }
        assert_eq!(
            host.request(
                &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
            )["stored"],
            true
        );
        let recovered = claim(&mut host, false);
        assert_eq!(recovered["recovering"], true);
        assert_eq!(recovered["recoveryAttempts"], count);
    }
    let read = snapshot(&temp);
    let mut index = read["threads"].clone();
    index[0]["nativeTurn"]["state"] = json!("interrupted");
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
        )["stored"],
        true
    );
    let bytes = fs::read(temp.0.join("threads.json")).unwrap();
    assert_eq!(claim(&mut host, false)["reason"], "recovery-exhausted");
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
    let read = snapshot(&temp);
    let mut index = read["threads"].clone();
    index[0]["nativeTurn"]["pauseReason"] = json!("unconfirmed");
    assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index.clone()}))["stored"], true);
    let bytes = fs::read(temp.0.join("threads.json")).unwrap();
    assert_eq!(claim(&mut host, false)["reason"], "retry-required");
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
    let scope = json!({"threadId":"thread","turnId":"native:origin:final","eventId":"origin","attemptId":index[0]["nativeTurn"]["attemptId"]});
    assert_eq!(
        control(&mut host, &scope, "run_turn_retry")["applied"],
        true
    );
    assert_eq!(claim(&mut host, false)["recoveryAttempts"], 1);
}

fn lifecycle(host: &mut History, scope: &Value, op: &str) -> Value {
    let mut request = scope.clone();
    request["op"] = json!(op);
    host.request(&request)
}
fn issued(host: &mut History) -> Value {
    let proof =
        host.request(&json!({"op":"run_attempt_claim","threadId":"thread","eventId":"origin"}));
    assert_eq!(proof["claimed"], true);
    json!({"threadId":"thread","turnId":"native:origin:final","eventId":"origin","attemptId":proof["attemptId"]})
}
#[test]
fn scoped_pause_preserves_retained_budget_and_uncertainty_after_owner_epoch_loss() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let scope = issued(&mut host);
    let read = snapshot(&temp);
    let mut index = read["threads"].clone();
    index[0]["nativeTurn"]["recoveryAttempts"] = json!(2);
    index[0]["nativeTurn"]["pauseReason"] = json!("unconfirmed");
    index[0]["nativeTurn"]["future"] = json!({"kept":true});
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
        )["stored"],
        true
    );
    drop(host);
    let mut host = History::open(&temp.0).unwrap();
    assert_eq!(
        lifecycle(&mut host, &scope, "run_attempt_pause")["applied"],
        true
    );
    let read = snapshot(&temp);
    let marker = &read["threads"][0]["nativeTurn"];
    assert_eq!(marker["state"], "interrupted");
    assert_eq!(marker["recoveryAttempts"], 2);
    assert_eq!(marker["pauseReason"], "unconfirmed");
    assert_eq!(marker["future"]["kept"], true);
    assert_eq!(
        lifecycle(&mut host, &scope, "run_attempt_pause")["applied"],
        true
    );
    assert_eq!(
        control(&mut host, &scope, "run_turn_retry")["applied"],
        true
    );
    let replacement = issued(&mut host);
    assert_ne!(replacement["attemptId"], scope["attemptId"]);
    let bytes = fs::read(temp.0.join("threads.json")).unwrap();
    for op in ["run_attempt_pause", "run_attempt_finish"] {
        assert_eq!(lifecycle(&mut host, &scope, op)["reason"], "scope-replaced");
        assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
    }
}
#[test]
fn scoped_cleanup_requires_canonical_terminal_and_ignores_dispatch_policy() {
    for guard in ["stop", "expiry", "fifo", "wrong-role", "wrong-thread"] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        seed(&mut host, "origin", "conversation");
        let scope = issued(&mut host);
        assert_eq!(host.request(&json!({"op":"history_append","operationId":"advisory","thread":true,"transcript":true,"event":{"id":"unrelated-advisory","threadId":"thread","ts":1500,"agentId":"main","kind":"message","data":{"role":"agent","text":"Retry","done":true,"failed":true}}}))["stored"], true);
        let bytes = fs::read(temp.0.join("threads.json")).unwrap();
        assert_eq!(
            lifecycle(&mut host, &scope, "run_attempt_finish")["reason"],
            "terminal-unconfirmed"
        );
        assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
        if guard.starts_with("wrong-") {
            let thread = if guard == "wrong-thread" {
                "other"
            } else {
                "thread"
            };
            let role = if guard == "wrong-role" {
                "user"
            } else {
                "agent"
            };
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"wrong-final","thread":true,"transcript":true,"event":{"id":"native:origin:final","threadId":thread,"ts":2000,"agentId":"main","kind":"message","data":{"role":role,"text":"wrong proof","done":true}}}))["stored"], true);
            assert_eq!(
                lifecycle(&mut host, &scope, "run_attempt_finish")["reason"],
                "terminal-unconfirmed"
            );
            assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
            assert_eq!(
                lifecycle(&mut host, &scope, "run_attempt_pause")["applied"],
                true
            );
            continue;
        }
        match guard {
            "stop" => {
                assert!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"requested","requestIds":["cancel"]}}))["record"].is_object());
            }
            "expiry" => {
                assert_eq!(host.request(&json!({"op":"admission_expire","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"deadline":1},"now":2}))["status"], "expired");
            }
            _ => {
                seed(&mut host, "waiting", "conversation");
                assert_eq!(
                    host.request(
                        &json!({"op":"queue_remove","threadId":"thread","eventId":"origin"})
                    )["stored"],
                    true
                );
            }
        }
        assert_eq!(host.request(&json!({"op":"history_append","operationId":"final","thread":true,"transcript":true,"event":{"id":"native:origin:final","threadId":"thread","ts":2000,"agentId":"main","kind":"message","data":{"role":"agent","text":"done","done":true}}}))["stored"], true);
        let known = lifecycle(&mut host, &scope, "run_attempt_pause");
        assert_eq!(known["terminal"], true);
        assert_eq!(known["applied"], false);
        assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
        let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
        assert_eq!(
            lifecycle(&mut host, &scope, "run_attempt_finish")["applied"],
            true
        );
        assert!(snapshot(&temp)["threads"][0].get("nativeTurn").is_none());
        assert_eq!(snapshot(&temp)["threads"][0]["future"]["kept"], true);
        assert_eq!(
            fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
            queue
        );
    }
}
#[test]
fn scoped_lifecycle_keeps_expected_marker_and_queue_on_metadata_conflict() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let scope = issued(&mut host);
    let bytes = fs::read(temp.0.join("threads.json")).unwrap();
    let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
    let conflict = temp.0.join("threads.json.tmp");
    fs::write(&conflict, b"owned lifecycle conflict fixture").unwrap();
    assert_eq!(
        lifecycle(&mut host, &scope, "run_attempt_pause")["reason"],
        "metadata-unconfirmed"
    );
    assert_eq!(host.request(&json!({"op":"history_append","operationId":"final","thread":true,"transcript":true,"event":{"id":"native:origin:final","threadId":"thread","ts":2000,"agentId":"main","kind":"message","data":{"role":"agent","text":"done","done":true}}}))["stored"], true);
    assert_eq!(
        lifecycle(&mut host, &scope, "run_attempt_finish")["reason"],
        "metadata-unconfirmed"
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), bytes);
    assert_eq!(
        fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
        queue
    );
    assert_eq!(
        fs::read(&conflict).unwrap(),
        b"owned lifecycle conflict fixture"
    );
    fs::remove_file(conflict).unwrap();
    assert_eq!(
        lifecycle(&mut host, &scope, "run_attempt_finish")["applied"],
        true
    );
}

#[test]
fn complete_unterminated_legacy_origin_survives_sdk_final_and_scoped_cleanup() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    let event = json!({"id":"origin","threadId":"thread","ts":1000,"agentId":"phone","kind":"message","data":{"role":"user","text":"keep this","future":{"kept":true}}});
    assert_eq!(host.request(&json!({"op":"accepted_accept","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"purpose":"legacy","event":event}}))["status"], "accepted");
    fs::create_dir_all(temp.0.join("threads")).unwrap();
    let old = event.to_string().into_bytes();
    fs::write(temp.0.join("threads/thread.jsonl"), &old).unwrap();
    assert_eq!(
        host.request(&json!({"op":"queue_enqueue","threadId":"thread","eventId":"origin"}))["stored"],
        true
    );
    let scope = issued(&mut host);
    assert_eq!(host.request(&json!({"op":"history_append","operationId":"final","thread":true,"transcript":true,"event":{"id":"native:origin:final","threadId":"thread","ts":2000,"agentId":"main","kind":"message","data":{"role":"agent","text":"done","done":true}}}))["stored"], true);
    assert!(
        fs::read(temp.0.join("threads/thread.jsonl"))
            .unwrap()
            .starts_with(&old)
    );
    assert_eq!(
        lifecycle(&mut host, &scope, "run_attempt_finish")["applied"],
        true
    );
}

fn result(
    host: &mut History,
    operation: &str,
    activity: &str,
    thread: &str,
    agent: &str,
    ok: bool,
) {
    assert_eq!(host.request(&json!({"op":"history_append","operationId":operation,"thread":true,"transcript":true,
        "event":{"id":activity,"threadId":thread,"ts":2000,"agentId":agent,"kind":"tool_result","data":{"callId":"call","ok":ok,"output":"retained"}}}))["stored"], true);
}
fn budget(host: &mut History, temp: &Temp, count: u64) {
    let read = snapshot(temp);
    let mut index = read["threads"].clone();
    index[0]["nativeTurn"]["recoveryAttempts"] = json!(count);
    index[0]["nativeTurn"]["future"] = json!({"kept":true});
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
        )["stored"],
        true
    );
}
fn progress(host: &mut History, scope: &Value, activity: &str) -> Value {
    let mut request = scope.clone();
    request["op"] = json!("run_attempt_progress");
    request["activityId"] = json!(activity);
    request["recoveryAttempts"] = json!(0);
    request["ok"] = json!(true);
    host.request(&request)
}
#[test]
fn progress_requires_first_retained_success_after_claim_and_preserves_marker_fields() {
    for mode in [
        "fresh",
        "long-id",
        "prior-success",
        "prior-failed",
        "failed-then-success",
        "new-failed",
        "wrong-thread",
        "wrong-agent",
        "missing",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        seed(&mut host, "origin", "conversation");
        let activity = if mode == "long-id" {
            "activity:".repeat(30)
        } else {
            "activity".to_owned()
        };
        if mode.starts_with("prior-") {
            result(
                &mut host,
                "prior",
                &activity,
                "thread",
                "main",
                mode == "prior-success",
            );
        }
        let scope = issued(&mut host);
        budget(&mut host, &temp, 2);
        if mode == "failed-then-success" {
            result(&mut host, "failed", &activity, "thread", "main", false);
        }
        if mode != "missing" {
            result(
                &mut host,
                "observed",
                &activity,
                if mode == "wrong-thread" {
                    "other"
                } else {
                    "thread"
                },
                if mode == "wrong-agent" {
                    "phone"
                } else {
                    "main"
                },
                mode != "new-failed",
            );
        }
        let before = fs::read(temp.0.join("threads.json")).unwrap();
        let proof = progress(&mut host, &scope, &activity);
        let accepted = ["fresh", "long-id", "prior-failed", "failed-then-success"].contains(&mode);
        assert_eq!(proof["applied"] == true, accepted, "{mode}: {proof}");
        if accepted {
            let marker = &snapshot(&temp)["threads"][0]["nativeTurn"];
            assert_eq!(marker["recoveryAttempts"], 0);
            assert_eq!(marker["future"]["kept"], true);
            assert_eq!(marker["recoveryActive"], false);
            budget(&mut host, &temp, 2);
            result(&mut host, "replay", &activity, "thread", "main", true);
            assert_eq!(progress(&mut host, &scope, &activity)["applied"], false);
            assert_eq!(
                snapshot(&temp)["threads"][0]["nativeTurn"]["recoveryAttempts"],
                2
            );
            result(
                &mut host,
                "next-success",
                "next-success",
                "thread",
                "main",
                true,
            );
            assert_eq!(progress(&mut host, &scope, "next-success")["applied"], true);
            assert_eq!(
                snapshot(&temp)["threads"][0]["nativeTurn"]["recoveryAttempts"],
                0
            );
        } else {
            assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), before);
        }
    }
}
#[test]
fn progress_cursor_advances_only_after_confirmed_metadata_and_rejects_prefix_rewrite() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let scope = issued(&mut host);
    budget(&mut host, &temp, 2);
    result(&mut host, "first", "first", "thread", "main", true);
    let conflict = temp.0.join("threads.json.tmp");
    fs::write(&conflict, b"owned progress conflict").unwrap();
    let before = fs::read(temp.0.join("threads.json")).unwrap();
    assert_eq!(
        progress(&mut host, &scope, "first")["reason"],
        "metadata-unconfirmed"
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), before);
    fs::remove_file(conflict).unwrap();
    assert_eq!(progress(&mut host, &scope, "first")["applied"], true);
    budget(&mut host, &temp, 2);
    result(&mut host, "second", "second", "thread", "main", true);
    let path = temp.0.join("threads/thread.jsonl");
    let raw = fs::read_to_string(&path).unwrap();
    let changed = raw.replacen("retained", "rewritte", 1);
    assert_ne!(raw, changed);
    assert_eq!(raw.len(), changed.len());
    fs::write(&path, changed).unwrap();
    assert!(progress(&mut host, &scope, "second").get("error").is_some());
    assert_eq!(
        snapshot(&temp)["threads"][0]["nativeTurn"]["recoveryAttempts"],
        2
    );
}
#[test]
fn progress_cannot_reset_stopped_expired_replaced_or_restarted_scope() {
    for mode in ["stopped", "expired", "replaced", "restarted"] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        seed(&mut host, "origin", "conversation");
        let scope = issued(&mut host);
        budget(&mut host, &temp, 2);
        result(&mut host, "observed", "fresh", "thread", "main", true);
        match mode {
            "stopped" => {
                assert!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"requested","requestIds":["cancel"]}}))["record"].is_object());
            }
            "expired" => {
                assert_eq!(host.request(&json!({"op":"admission_expire","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"deadline":1},"now":2}))["status"], "expired");
            }
            "replaced" => {
                let read = snapshot(&temp);
                let mut index = read["threads"].clone();
                index[0]["nativeTurn"]["attemptId"] = json!("b".repeat(32));
                assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"], true);
            }
            _ => {
                drop(host);
                host = History::open(&temp.0).unwrap();
            }
        }
        let before = fs::read(temp.0.join("threads.json")).unwrap();
        assert_eq!(
            progress(&mut host, &scope, "fresh")["applied"],
            false,
            "{mode}"
        );
        assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), before);
    }
}

#[cfg(unix)]
#[test]
fn progress_refuses_same_bytes_at_a_replaced_physical_file() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let scope = issued(&mut host);
    budget(&mut host, &temp, 2);
    result(&mut host, "fresh", "fresh", "thread", "main", true);
    let path = temp.0.join("threads/thread.jsonl");
    let bytes = fs::read(&path).unwrap();
    fs::rename(&path, path.with_extension("old")).unwrap();
    fs::write(&path, &bytes).unwrap();
    assert!(progress(&mut host, &scope, "fresh").get("error").is_some());
    assert_eq!(fs::read(&path).unwrap(), bytes);
    assert_eq!(
        snapshot(&temp)["threads"][0]["nativeTurn"]["recoveryAttempts"],
        2
    );
}

fn boot(host: &mut History, marker: &Value, preview: bool) -> Value {
    host.request(&json!({"op":"run_turn_recover","threadId":"thread","expectedTurn":marker,"preview":preview}))
}
#[test]
fn boot_reconciliation_preserves_legacy_identity_and_uses_visible_same_thread_role_evidence() {
    for mode in [
        "inferred",
        "legacy-final",
        "wrong-role",
        "wrong-thread",
        "missing-origin",
        "rewound-origin",
        "hidden-final",
        "arbitrary-legacy",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        if !["legacy-final", "missing-origin", "arbitrary-legacy"].contains(&mode) {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"origin","thread":true,"transcript":true,
                "event":{"id":"origin","threadId":"thread","ts":1000,"agentId":"phone","kind":"message","data":{"role":"user","text":"retained"}}}))["stored"], true);
        }
        let id = if mode == "legacy-final" {
            "final"
        } else if mode == "arbitrary-legacy" {
            "crash"
        } else {
            "native:origin:final"
        };
        let mut marker = json!({"id":id,"state":"running","recoveryAttempts":2,"recoveryActive":true,"future":{"kept":true}});
        if !["inferred", "legacy-final", "arbitrary-legacy"].contains(&mode) {
            marker["userEventId"] = json!("origin");
        }
        let read = snapshot(&temp);
        let mut index = read["threads"].clone();
        index[0]["nativeTurn"] = marker.clone();
        assert_eq!(
            host.request(
                &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
            )["stored"],
            true
        );
        if ["legacy-final", "wrong-role", "wrong-thread", "hidden-final"].contains(&mode) {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"terminal","thread":true,"transcript":true,
                "event":{"id":id,"threadId":if mode == "wrong-thread" { "other" } else { "thread" },"ts":2000,"agentId":"main","kind":"message",
                    "data":{"role":if mode == "wrong-role" { "user" } else { "agent" },"text":"not automatically proof","done":true}}}))["stored"], true);
        }
        if ["rewound-origin", "hidden-final"].contains(&mode) {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"rewind","thread":true,"transcript":true,
                "event":{"id":"rewind","threadId":"thread","ts":3000,"agentId":"main","kind":"thread_rewound",
                    "data":{"requestId":"edit","eventId":"origin","hiddenEventIds":[if mode == "hidden-final" { id } else { "origin" }]}}}))["stored"], true);
        }
        let before = fs::read(temp.0.join("threads.json")).unwrap();
        assert_eq!(boot(&mut host, &marker, true)["checked"], true, "{mode}");
        assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), before);
        let proof = boot(&mut host, &marker, false);
        assert_eq!(proof["applied"], true, "{mode}: {proof}");
        let retained = &snapshot(&temp)["threads"][0]["nativeTurn"];
        if ["legacy-final", "rewound-origin"].contains(&mode) {
            assert!(retained.is_null(), "{mode}");
        } else {
            assert_eq!(retained["state"], "interrupted");
            assert_eq!(retained["recoveryAttempts"], 2);
            assert_eq!(retained["recoveryActive"], true);
            assert_eq!(retained["future"]["kept"], true);
            if mode == "inferred" {
                assert_eq!(retained["userEventId"], "origin");
            }
            if mode == "missing-origin" {
                assert_eq!(retained["pauseReason"], "unconfirmed");
            }
            if mode == "arbitrary-legacy" {
                assert!(retained.get("userEventId").is_none());
            }
        }
        assert!(
            host.request(&json!({"op":"accepted_get","messageId":"origin"}))["entry"].is_null()
        );
    }
}
#[test]
fn boot_reconciliation_refuses_live_and_replaced_scope_and_preserves_metadata_conflicts() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let scope = issued(&mut host);
    let marker = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
    let before = fs::read(temp.0.join("threads.json")).unwrap();
    assert_eq!(boot(&mut host, &marker, true)["reason"], "run-active");
    assert_eq!(boot(&mut host, &marker, false)["reason"], "run-active");
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), before);
    assert_eq!(host.request(&json!({"op":"run_attempt_release","threadId":"thread","eventId":"origin","attemptId":scope["attemptId"]}))["released"], true);
    let mut stale = marker.clone();
    stale["attemptId"] = json!("b".repeat(32));
    assert_eq!(boot(&mut host, &stale, false)["reason"], "scope-replaced");
    let conflict = temp.0.join("threads.json.tmp");
    fs::write(&conflict, b"owned boot conflict").unwrap();
    assert_eq!(
        boot(&mut host, &marker, false)["reason"],
        "metadata-unconfirmed"
    );
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), before);
    assert_eq!(fs::read(&conflict).unwrap(), b"owned boot conflict");
    fs::remove_file(conflict).unwrap();
    assert_eq!(boot(&mut host, &marker, false)["applied"], true);
    assert_eq!(
        snapshot(&temp)["threads"][0]["nativeTurn"]["state"],
        "interrupted"
    );
}

#[test]
fn boot_uses_retained_numeric_values_and_refuses_rounded_opaque_identity() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let read = snapshot(&temp);
    let mut index = read["threads"].clone();
    let retained = json!({"id":"native:origin:final","state":"running","userEventId":"origin",
        "recoveryAttempts":2.0,"future":{"integer":2.0}});
    index[0]["nativeTurn"] = retained;
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
        )["stored"],
        true
    );
    let normalized = json!({"id":"native:origin:final","state":"running","userEventId":"origin",
        "recoveryAttempts":2,"future":{"integer":2}});
    assert_eq!(boot(&mut host, &normalized, false)["applied"], true);
    let read = snapshot(&temp);
    assert_eq!(
        read["threads"][0]["nativeTurn"]["recoveryAttempts"].as_f64(),
        Some(2.0)
    );
    assert!(
        read["threads"][0]["nativeTurn"]["future"]["integer"]
            .as_u64()
            .is_none()
    );
    let mut index = read["threads"].clone();
    index[0]["nativeTurn"]["future"]["opaque"] = json!(9_007_199_254_740_993u64);
    assert_eq!(
        host.request(
            &json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index})
        )["stored"],
        true
    );
    let before = fs::read(temp.0.join("threads.json")).unwrap();
    let mut rounded = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
    rounded["future"]["opaque"] = json!(9_007_199_254_740_992u64);
    assert_eq!(boot(&mut host, &rounded, false)["reason"], "scope-replaced");
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), before);
}

fn clear_stop(host: &mut History, marker: &Value) -> Value {
    host.request(
        &json!({"op":"run_turn_stop_clear","threadId":"thread","eventId":"origin",
        "turnId":"native:origin:final","expectedTurn":marker}),
    )
}
#[test]
fn scoped_stop_clear_requires_durable_uncertainty_and_keeps_queue_history_and_stop_evidence() {
    for guard in [
        "unconfirmed",
        "stopped",
        "missing-stop",
        "requested",
        "wrong-thread",
        "active",
        "replaced",
        "registry-replaced",
        "conflict",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        seed(&mut host, "origin", "conversation");
        let scope = issued(&mut host);
        assert_eq!(
            lifecycle(&mut host, &scope, "run_attempt_pause")["applied"],
            true
        );
        let marker = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
        if guard == "registry-replaced" {
            let newer = issued(&mut host);
            assert_ne!(newer["attemptId"], scope["attemptId"]);
            let read = snapshot(&temp);
            let mut index = read["threads"].clone();
            index[0]["nativeTurn"] = marker.clone();
            assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"], true);
        }
        if guard != "missing-stop" {
            assert!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin",
                "threadId":if guard == "wrong-thread" { "other" } else { "thread" },
                "status":if guard == "requested" { "requested" } else if guard == "stopped" { "stopped" } else { "unconfirmed" },
                "requestIds":["stop"],"future":{"kept":true}}}))["record"].is_object());
        }
        let mut expected = marker.clone();
        if guard == "active" || guard == "replaced" {
            let read = snapshot(&temp);
            let mut index = read["threads"].clone();
            if guard == "active" {
                index[0]["nativeTurn"]["state"] = json!("running");
            } else {
                index[0]["nativeTurn"]["attemptId"] = json!("b".repeat(32));
            }
            assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"], true);
            if guard == "active" {
                expected = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
            }
        }
        let conflict = temp.0.join("threads.json.tmp");
        if guard == "conflict" {
            fs::write(&conflict, b"owned Stop clear conflict").unwrap();
        }
        let metadata = fs::read(temp.0.join("threads.json")).unwrap();
        let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
        let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        let stop = fs::read(temp.0.join("stopped-turns.jsonl")).unwrap_or_default();
        let proof = clear_stop(&mut host, &expected);
        if ["unconfirmed", "stopped"].contains(&guard) {
            assert_eq!(proof["applied"], true, "{guard}: {proof}");
            assert!(snapshot(&temp)["threads"][0]["nativeTurn"].is_null());
            assert_eq!(clear_stop(&mut host, &Value::Null)["applied"], true);
            assert_eq!(host.request(&json!({"op":"run_attempt_current","threadId":"thread","eventId":"origin","attemptId":scope["attemptId"],"mode":"owned"}))["current"], false);
        } else {
            assert_eq!(proof["applied"], false, "{guard}: {proof}");
            assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), metadata);
        }
        assert_eq!(
            fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
            queue
        );
        assert_eq!(
            fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
            history
        );
        assert_eq!(
            fs::read(temp.0.join("stopped-turns.jsonl")).unwrap_or_default(),
            stop
        );
        if guard == "conflict" {
            assert_eq!(proof["reason"], "metadata-unconfirmed");
            assert_eq!(fs::read(&conflict).unwrap(), b"owned Stop clear conflict");
            fs::remove_file(conflict).unwrap();
            drop(host);
            let mut host = History::open(&temp.0).unwrap();
            assert_eq!(clear_stop(&mut host, &expected)["applied"], true);
            assert_eq!(
                host.request(&json!({"op":"stop_get","targetEventId":"origin"}))["record"]["status"],
                "unconfirmed"
            );
            assert_eq!(
                fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
                queue
            );
        }
    }
}

fn reconcile_rewind(host: &mut History, expected: &Value) -> Value {
    host.request(
        &json!({"op":"run_turn_rewind","threadId":"thread","rewindId":"rewind",
        "requestId":"edit","expectedTurn":expected}),
    )
}
#[test]
fn scoped_rewind_retires_only_proven_prior_user_queue_rows_and_preserves_partial_cleanup() {
    for guard in [
        "success",
        "absent",
        "replacement",
        "active",
        "registry-replaced",
        "metadata-conflict",
        "queue-conflict",
        "missing",
        "failed",
        "wrong-thread",
        "agent-anchor",
        "late-anchor",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        seed(&mut host, "origin", "conversation");
        let scope = issued(&mut host);
        assert_eq!(
            lifecycle(&mut host, &scope, "run_attempt_pause")["applied"],
            true
        );
        let expected = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
        if guard == "registry-replaced" {
            let newer = issued(&mut host);
            assert_ne!(newer["attemptId"], scope["attemptId"]);
            let read = snapshot(&temp);
            let mut index = read["threads"].clone();
            index[0]["nativeTurn"] = expected.clone();
            assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"], true);
        }
        seed(&mut host, "hidden", "conversation");
        for id in ["not-user", "missing-row", "late"] {
            assert_eq!(
                host.request(&json!({"op":"queue_enqueue","eventId":id,"threadId":"thread"}))["stored"],
                true
            );
        }
        assert_eq!(
            host.request(&json!({"op":"queue_enqueue","eventId":"other-owner","threadId":"other"}))
                ["stored"],
            true
        );
        assert_eq!(host.request(&json!({"op":"history_append","operationId":"not-user","thread":true,"transcript":true,
            "event":{"id":"not-user","threadId":"thread","ts":2000,"agentId":"main","kind":"message","data":{"role":"agent","text":"retained","done":true}}}))["stored"],true);
        if guard != "missing" {
            let anchor = if guard == "agent-anchor" {
                "not-user"
            } else if guard == "late-anchor" {
                "late"
            } else {
                "origin"
            };
            let mut event = json!({"id":"rewind","threadId":if guard == "wrong-thread" {"other"} else {"thread"},"ts":3000,"agentId":"main",
                "kind":"thread_rewound","data":{"requestId":"edit","eventId":anchor,"hiddenEventIds":["origin","hidden","not-user","missing-row","late","other-owner"]}});
            if guard == "failed" {
                event["data"]["reason"] = json!("busy");
            }
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"rewind","event":event,"thread":true,"transcript":true}))["stored"],true);
        }
        seed(&mut host, "late", "conversation");
        seed(&mut host, "visible", "conversation");
        let mut captured = expected.clone();
        if ["absent", "replacement", "active"].contains(&guard) {
            let read = snapshot(&temp);
            let mut index = read["threads"].clone();
            if guard == "absent" {
                index[0].as_object_mut().unwrap().remove("nativeTurn");
                captured = Value::Null;
            } else if guard == "replacement" {
                index[0]["nativeTurn"] = json!({"id":"native:visible:final","userEventId":"visible","state":"interrupted","recoveryAttempts":3,"future":{"kept":true}});
            } else {
                index[0]["nativeTurn"]["state"] = json!("running");
                captured = index[0]["nativeTurn"].clone();
            }
            assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"],true);
        }
        let conflict = temp.0.join(if guard == "queue-conflict" {
            "native-turn-queue.json.tmp"
        } else {
            "threads.json.tmp"
        });
        if guard.ends_with("conflict") {
            fs::write(&conflict, b"owned rewind conflict").unwrap();
        }
        let metadata = fs::read(temp.0.join("threads.json")).unwrap();
        let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
        let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        let proof = reconcile_rewind(&mut host, &captured);
        let invalid = [
            "missing",
            "failed",
            "wrong-thread",
            "agent-anchor",
            "late-anchor",
            "queue-conflict",
        ]
        .contains(&guard);
        if invalid {
            assert_ne!(proof["queueConfirmed"], true, "{guard}: {proof}");
            assert_eq!(
                fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
                queue
            );
        } else {
            assert_eq!(proof["queueConfirmed"], true, "{guard}: {proof}");
            let remaining: Value =
                serde_json::from_slice(&fs::read(temp.0.join("native-turn-queue.json")).unwrap())
                    .unwrap();
            assert_eq!(proof["queueEntries"], remaining);
            assert_eq!(
                remaining
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|row| row["eventId"].as_str().unwrap())
                    .collect::<Vec<_>>(),
                vec!["not-user", "missing-row", "late", "other-owner", "visible"]
            );
        }
        if ["success", "absent"].contains(&guard) {
            assert_eq!(proof["applied"], true, "{guard}: {proof}");
            assert!(snapshot(&temp)["threads"][0]["nativeTurn"].is_null());
            assert_eq!(
                reconcile_rewind(&mut host, &Value::Null)["queueEntries"],
                proof["queueEntries"]
            );
        } else {
            assert_eq!(proof["applied"], false, "{guard}: {proof}");
            assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), metadata);
        }
        assert_eq!(
            fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
            history
        );
        assert_eq!(
            host.request(&json!({"op":"accepted_get","messageId":"origin"}))["entry"]["purpose"],
            "conversation"
        );
        if guard.ends_with("conflict") {
            assert_eq!(fs::read(&conflict).unwrap(), b"owned rewind conflict");
            fs::remove_file(conflict).unwrap();
            let retry = reconcile_rewind(&mut host, &captured);
            assert_eq!(retry["applied"], true, "{guard}: {retry}");
            assert_eq!(retry["queueConfirmed"], true);
        }
        if guard == "replacement" {
            let marker = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
            let retry = reconcile_rewind(&mut host, &marker);
            assert_eq!(retry["applied"], true);
            assert_eq!(retry["cleared"], false);
            assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), metadata);
        }
    }
}
#[test]
fn durable_rewind_bars_root_dispatch_and_retry_even_if_hidden_origin_still_heads_queue() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let scope = issued(&mut host);
    assert_eq!(
        lifecycle(&mut host, &scope, "run_attempt_pause")["applied"],
        true
    );
    let marker = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
    assert_eq!(host.request(&json!({"op":"history_append","operationId":"rewind","thread":true,"transcript":true,
        "event":{"id":"rewind","threadId":"thread","ts":3000,"agentId":"main","kind":"thread_rewound",
        "data":{"requestId":"edit","eventId":"origin","hiddenEventIds":["origin"]}}}))["stored"],true);
    assert_eq!(ready(&mut host, "origin")["reason"], "rewound-origin");
    assert_eq!(host.request(&json!({"op":"run_turn_retry","threadId":"thread","turnId":marker["id"],"eventId":"origin","attemptId":marker["attemptId"]}))["reason"],"rewound-origin");
    assert_eq!(snapshot(&temp)["threads"][0]["nativeTurn"], marker);
}

fn unissued(host: &mut History, action: &str, marker: &Value) -> Value {
    host.request(
        &json!({"op":action,"threadId":"thread","eventId":"origin","turnId":"native:origin:final",
        "expectedTurn":marker,"pauseReason":"unconfirmed","recoveryAttempts":999}),
    )
}
#[test]
fn unissued_pause_preserves_owned_fields_and_never_claims_or_resurrects_work() {
    for guard in [
        "new",
        "retained",
        "replacement",
        "issued",
        "registry",
        "stop",
        "expired",
        "hidden",
        "terminal",
        "missing-user",
        "successor",
        "metadata-conflict",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        if guard == "successor" {
            seed(&mut host, "first", "conversation");
        }
        seed(&mut host, "origin", "conversation");
        let mut expected = Value::Null;
        if ["retained", "replacement", "issued", "registry"].contains(&guard) {
            let read = snapshot(&temp);
            let mut index = read["threads"].clone();
            index[0]["nativeTurn"] = json!({"id":"native:origin:final","userEventId":"origin","state":"running",
                "recoveryAttempts":2.0,"pauseReason":"unconfirmed","recoveryActive":true,"future":{"kept":true}});
            assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"],true);
            expected = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
            if guard == "issued" || guard == "registry" {
                // Reset the compatibility pause so a real Root-issued registry can be installed.
                let read = snapshot(&temp);
                let mut index = read["threads"].clone();
                index[0].as_object_mut().unwrap().remove("nativeTurn");
                assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"],true);
                let scope = issued(&mut host);
                assert!(scope["attemptId"].is_string());
                if guard == "issued" {
                    expected = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
                } else {
                    let read = snapshot(&temp);
                    let mut index = read["threads"].clone();
                    index[0]["nativeTurn"] = expected.clone();
                    assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"],true);
                }
            }
            if guard == "replacement" {
                let read = snapshot(&temp);
                let mut index = read["threads"].clone();
                index[0]["nativeTurn"]["future"]["newer"] = json!(true);
                assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"],true);
            }
        }
        if guard == "stop" {
            assert!(host.request(&json!({"op":"stop_save","record":{"threadId":"thread","targetEventId":"origin","status":"unconfirmed","requestIds":["cancel"]}}))["record"].is_object());
        }
        if guard == "expired" {
            assert_eq!(host.request(&json!({"op":"admission_expire","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"deadline":1},"now":2}))["status"],"expired");
        }
        if guard == "hidden" {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"rewind","thread":true,"transcript":true,
            "event":{"id":"rewind","threadId":"thread","ts":3000,"agentId":"main","kind":"thread_rewound","data":{"requestId":"edit","eventId":"origin","hiddenEventIds":["origin"]}}}))["stored"],true);
        }
        if guard == "terminal" {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"final","thread":true,"transcript":true,
            "event":{"id":"native:origin:final","threadId":"thread","ts":2000,"agentId":"main","kind":"message","data":{"role":"agent","text":"retained","done":true,"failed":true}}}))["stored"],true);
        }
        if guard == "missing-user" {
            fs::write(temp.0.join("threads/thread.jsonl"), b"\n").unwrap();
        }
        let conflict = temp.0.join("threads.json.tmp");
        if guard == "metadata-conflict" {
            fs::write(&conflict, b"owned unissued pause conflict").unwrap();
        }
        let before = fs::read(temp.0.join("threads.json")).unwrap();
        let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
        let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        let proof = unissued(&mut host, "run_turn_unissued_pause", &expected);
        if ["new", "retained"].contains(&guard) {
            assert_eq!(proof["applied"], true, "{guard}: {proof}");
            let marker = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
            assert_eq!(proof["turn"], marker);
            assert_eq!(marker["state"], "interrupted");
            assert_eq!(marker["pauseReason"], "unconfirmed");
            assert!(marker.get("attemptId").is_none());
            assert_eq!(
                marker["recoveryAttempts"].as_f64(),
                Some(if guard == "new" { 0.0 } else { 2.0 })
            );
            if guard == "retained" {
                assert_eq!(marker["future"], expected["future"]);
                assert_eq!(marker["recoveryActive"], true);
            }
        } else {
            assert_eq!(proof["applied"], false, "{guard}: {proof}");
            assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), before);
        }
        assert_eq!(
            fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
            queue
        );
        assert_eq!(
            fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
            history
        );
        if guard == "metadata-conflict" {
            fs::remove_file(conflict).unwrap();
            assert_eq!(
                unissued(&mut host, "run_turn_unissued_pause", &expected)["applied"],
                true
            );
        }
    }
}
#[test]
fn unissued_terminal_clear_requires_its_exact_returned_scope_and_durable_agent_completion() {
    for guard in [
        "success",
        "null",
        "replacement",
        "issued",
        "wrong-role",
        "missing-final",
        "stop-expired",
        "conflict",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        seed(&mut host, "origin", "conversation");
        let pause = unissued(&mut host, "run_turn_unissued_pause", &Value::Null);
        assert_eq!(pause["applied"], true);
        let mut expected = pause["turn"].clone();
        if guard != "missing-final" {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"final","thread":true,"transcript":true,
            "event":{"id":"native:origin:final","threadId":"thread","ts":2000,"agentId":"main","kind":"message",
            "data":{"role":if guard=="wrong-role"{"user"}else{"agent"},"text":"retained","done":true,"failed":true}}}))["stored"],true);
        }
        if ["null", "replacement", "issued"].contains(&guard) {
            let read = snapshot(&temp);
            let mut index = read["threads"].clone();
            if guard == "null" {
                index[0].as_object_mut().unwrap().remove("nativeTurn");
                expected = Value::Null;
            } else if guard == "issued" {
                index[0]["nativeTurn"]["attemptId"] = json!("b".repeat(32));
                expected = index[0]["nativeTurn"].clone();
            } else {
                index[0]["nativeTurn"]["future"] = json!({"replacement":true});
            }
            assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"],true);
        }
        if guard == "stop-expired" {
            assert!(host.request(&json!({"op":"stop_save","record":{"threadId":"thread","targetEventId":"origin","status":"requested","requestIds":["cancel"]}}))["record"].is_object());
            assert_eq!(host.request(&json!({"op":"admission_expire","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"deadline":1},"now":2}))["status"],"expired");
        }
        let conflict = temp.0.join("threads.json.tmp");
        if guard == "conflict" {
            fs::write(&conflict, b"owned unissued finish conflict").unwrap();
        }
        let before = fs::read(temp.0.join("threads.json")).unwrap();
        let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
        let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        let proof = unissued(&mut host, "run_turn_unissued_finish", &expected);
        if ["success", "null", "stop-expired"].contains(&guard) {
            assert_eq!(proof["applied"], true, "{guard}: {proof}");
            assert!(snapshot(&temp)["threads"][0]["nativeTurn"].is_null());
        } else {
            assert_eq!(proof["applied"], false, "{guard}: {proof}");
            assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), before);
        }
        assert_eq!(
            fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
            queue
        );
        assert_eq!(
            fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
            history
        );
        if guard == "conflict" {
            fs::remove_file(conflict).unwrap();
            assert_eq!(
                unissued(&mut host, "run_turn_unissued_finish", &expected)["applied"],
                true
            );
        }
    }
}

fn preflight(host: &mut History, expected: &Value, ts: u64) -> Value {
    host.request(
        &json!({"op":"run_turn_preflight_finish","threadId":"thread","eventId":"origin",
        "expectedTurn":expected,"reason":"missing-folder","ts":ts}),
    )
}
#[test]
fn preflight_admits_failed_final_only_for_its_captured_paused_scope() {
    for guard in [
        "null",
        "legacy",
        "issued-paused",
        "restart",
        "stopped-expired-noqueue",
        "replacement",
        "running",
        "foreign-registry",
        "hidden",
        "missing-user",
        "writer-lease",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        seed(&mut host, "origin", "conversation");
        let mut expected = Value::Null;
        if ["legacy", "stopped-expired-noqueue", "replacement"].contains(&guard) {
            pause(&mut host, &temp);
            expected = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
        }
        if ["issued-paused", "restart", "running", "foreign-registry"].contains(&guard) {
            let scope = issued(&mut host);
            if guard != "running" {
                assert_eq!(
                    lifecycle(&mut host, &scope, "run_attempt_pause")["applied"],
                    true
                );
            }
            expected = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
            if guard == "restart" {
                drop(host);
                host = History::open(&temp.0).unwrap();
            }
            if guard == "foreign-registry" {
                let read = snapshot(&temp);
                let mut index = read["threads"].clone();
                index[0]["nativeTurn"]["attemptId"] = json!("b".repeat(32));
                expected = index[0]["nativeTurn"].clone();
                assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"],true);
            }
        }
        if guard == "replacement" {
            let read = snapshot(&temp);
            let mut index = read["threads"].clone();
            index[0]["nativeTurn"]["future"] = json!({"replacement":true});
            assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"],true);
        }
        if guard == "stopped-expired-noqueue" {
            assert!(host.request(&json!({"op":"stop_save","record":{"threadId":"thread","targetEventId":"origin","status":"requested","requestIds":["stop"]}}))["record"].is_object());
            assert_eq!(host.request(&json!({"op":"admission_expire","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"deadline":1},"now":2}))["status"],"expired");
            assert_eq!(
                host.request(&json!({"op":"queue_remove","threadId":"thread","eventId":"origin"}))
                    ["stored"],
                true
            );
        }
        if guard == "hidden" {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"rewind","thread":true,"transcript":true,
                "event":{"id":"rewound","threadId":"thread","ts":3000,"agentId":"main","kind":"thread_rewound",
                "data":{"requestId":"rewind","eventId":"origin","hiddenEventIds":["origin"]}}}))["stored"],true);
        }
        if guard == "missing-user" {
            fs::write(temp.0.join("threads/thread.jsonl"), b"").unwrap();
        }
        let lock = if guard == "writer-lease" {
            let file = fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(temp.0.join(".rust-thread-index-owner.lock"))
                .unwrap();
            file.try_lock().unwrap();
            Some(file)
        } else {
            None
        };
        let before = fs::read(temp.0.join("threads.json")).unwrap();
        let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
        let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        let proof = preflight(&mut host, &expected, 4000);
        if [
            "null",
            "legacy",
            "issued-paused",
            "restart",
            "stopped-expired-noqueue",
        ]
        .contains(&guard)
        {
            assert_eq!(proof["stored"], true, "{guard}: {proof}");
            assert_eq!(proof["applied"], true, "{guard}: {proof}");
            assert_eq!(proof["final"]["id"], "native:origin:final");
            assert_eq!(proof["final"]["data"]["failed"], true);
            assert!(snapshot(&temp)["threads"][0].get("nativeTurn").is_none());
            if expected["attemptId"].is_string() {
                let currency = host.request(&json!({"op":"run_attempt_current","threadId":"thread","eventId":"origin","attemptId":expected["attemptId"],"mode":"owned"}));
                assert_eq!(currency["current"], false);
                assert_ne!(currency["owned"], true);
            }
            assert_eq!(
                preflight(&mut host, &expected, 86_404_000)["final"],
                proof["final"]
            );
        } else {
            assert_ne!(proof["stored"], true, "{guard}: {proof}");
            assert!(
                proof["reason"].is_string() || proof["error"].is_string(),
                "{guard}: {proof}"
            );
            assert_eq!(
                fs::read(temp.0.join("threads.json")).unwrap(),
                before,
                "{guard}"
            );
            assert_eq!(
                fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
                history,
                "{guard}"
            );
        }
        assert_eq!(
            fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
            queue,
            "{guard}"
        );
        drop(lock);
    }
}
#[test]
fn preflight_metadata_retry_recovers_original_final_across_restart_and_midnight() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    let scope = issued(&mut host);
    assert_eq!(
        lifecycle(&mut host, &scope, "run_attempt_pause")["applied"],
        true
    );
    let read = snapshot(&temp);
    let mut index_with_future = read["threads"].clone();
    index_with_future[0]["nativeTurn"]["future"] =
        json!({"10":2.0,"2":"kept","nested":{"a":1,"z":true}});
    assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index_with_future}))["stored"],true);
    let expected = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
    let index = fs::read(temp.0.join("threads.json")).unwrap();
    let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
    let snapshots = temp.0.join(".thread-index-recovery");
    fs::rename(&snapshots, temp.0.join("snapshot-backup")).unwrap();
    fs::write(&snapshots, b"retain blocked metadata backup").unwrap();
    let first = preflight(&mut host, &expected, 4000);
    assert_eq!(first["stored"], true, "{first}");
    assert_eq!(first["applied"], false);
    assert_eq!(first["reason"], "metadata-unconfirmed");
    assert_eq!(fs::read(temp.0.join("threads.json")).unwrap(), index);
    let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    let transcript = fs::read(temp.0.join("transcripts/1970-01-01.jsonl")).unwrap();
    drop(host);
    fs::remove_file(&snapshots).unwrap();
    fs::rename(temp.0.join("snapshot-backup"), &snapshots).unwrap();
    let mut host = History::open(&temp.0).unwrap();
    let mut reordered = Value::Object(
        expected
            .as_object()
            .unwrap()
            .iter()
            .rev()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    );
    reordered["future"] = Value::Object(
        expected["future"]
            .as_object()
            .unwrap()
            .iter()
            .rev()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    );
    reordered["future"]["nested"] = json!({"z":true,"a":1.0});
    reordered["recoveryAttempts"] = json!(0.0);
    let retry = preflight(&mut host, &reordered, 86_404_000);
    assert_eq!(retry["stored"], true, "{retry}");
    assert_eq!(retry["applied"], true);
    assert_eq!(retry["final"], first["final"]);
    assert!(snapshot(&temp)["threads"][0].get("nativeTurn").is_none());
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        history
    );
    assert_eq!(
        fs::read(temp.0.join("transcripts/1970-01-01.jsonl")).unwrap(),
        transcript
    );
    assert!(!temp.0.join("transcripts/1970-01-02.jsonl").exists());
    assert_eq!(
        fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
        queue
    );
}

fn stop_fallback(host: &mut History, expected: &Value, ts: u64) -> Value {
    host.request(
        &json!({"op":"run_turn_stop_fallback","threadId":"thread","eventId":"origin",
        "expectedTurn":expected,"ts":ts}),
    )
}
#[test]
fn native_stop_fallback_requires_actual_pending_ownership_and_agent_terminal_evidence() {
    for guard in [
        "pending",
        "paused",
        "issued",
        "replacement",
        "foreign-head",
        "no-queue",
        "user-done",
        "agent-undone",
        "completed",
        "already-stopped",
        "hidden",
    ] {
        let temp = Temp::new();
        let (mut host, _) = open(&temp);
        if guard == "foreign-head" {
            seed(&mut host, "first", "conversation");
        }
        seed(&mut host, "origin", "conversation");
        let mut expected = Value::Null;
        if ["paused", "replacement"].contains(&guard) {
            pause(&mut host, &temp);
            expected = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
        }
        if guard == "replacement" {
            let read = snapshot(&temp);
            let mut index = read["threads"].clone();
            index[0].as_object_mut().unwrap().remove("nativeTurn");
            assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":read["hash"],"threads":index}))["stored"],true);
            issued(&mut host);
        }
        if guard == "issued" {
            issued(&mut host);
            expected = snapshot(&temp)["threads"][0]["nativeTurn"].clone();
        }
        if guard == "no-queue" {
            assert_eq!(
                host.request(&json!({"op":"queue_remove","threadId":"thread","eventId":"origin"}))
                    ["stored"],
                true
            );
        }
        if ["user-done", "agent-undone", "completed", "already-stopped"].contains(&guard) {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"occupied-final","thread":true,"transcript":true,
                "event":{"id":"native:origin:final","threadId":"thread","ts":2000,"agentId":"main","kind":"message",
                "data":{"role":if guard=="user-done"{"user"}else{"agent"},"text":"retained",
                    "done":guard!="agent-undone","interrupted":guard=="already-stopped"}}}))["stored"],true);
        }
        if guard == "hidden" {
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"rewind-stop","thread":true,"transcript":true,
                "event":{"id":"rewound","threadId":"thread","ts":2000,"agentId":"main","kind":"thread_rewound",
                "data":{"requestId":"rewind","eventId":"origin","hiddenEventIds":["origin"]}}}))["stored"],true);
        }
        assert_eq!(host.request(&json!({"op":"stop_save","record":{"threadId":"thread","targetEventId":"origin",
            "status":"requested","requestIds":["stop"],"partialText":"retained partial","future":{"kept":true}}}))["record"]["status"],"requested");
        let before = fs::read(temp.0.join("threads.json")).unwrap();
        let queue = fs::read(temp.0.join("native-turn-queue.json")).unwrap();
        let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        let proof = stop_fallback(&mut host, &expected, 3000);
        let status = if guard == "completed" {
            "completed"
        } else if ["pending", "already-stopped"].contains(&guard) {
            "stopped"
        } else {
            "unconfirmed"
        };
        assert_eq!(proof["stopConfirmed"], true, "{guard}: {proof}");
        assert_eq!(proof["record"]["status"], status, "{guard}: {proof}");
        assert_eq!(proof["record"]["future"], json!({"kept":true}));
        assert_eq!(
            host.request(&json!({"op":"stop_get","targetEventId":"origin"}))["record"],
            proof["record"]
        );
        if guard == "pending" {
            assert_eq!(proof["stored"], true);
            assert_eq!(
                proof["final"]["data"],
                json!({"role":"agent","text":"retained partial","done":true,"interrupted":true})
            );
        } else {
            assert_ne!(proof["stored"], true, "{guard}: {proof}");
            assert_eq!(
                fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
                history,
                "{guard}"
            );
        }
        assert_eq!(
            fs::read(temp.0.join("threads.json")).unwrap(),
            before,
            "{guard}"
        );
        assert_eq!(
            fs::read(temp.0.join("native-turn-queue.json")).unwrap(),
            queue,
            "{guard}"
        );
    }
}
#[test]
fn native_stop_fallback_reuses_saved_final_after_status_failure_restart_and_request_growth() {
    let temp = Temp::new();
    let (mut host, _) = open(&temp);
    seed(&mut host, "origin", "conversation");
    assert_eq!(
        host.request(
            &json!({"op":"stop_save","record":{"threadId":"thread","targetEventId":"origin",
        "status":"requested","requestIds":["first"],"partialText":"original partial"}})
        )["record"]["status"],
        "requested"
    );
    let path = temp.0.join("stopped-turns.jsonl");
    fs::rename(&path, temp.0.join("stop-backup.jsonl")).unwrap();
    fs::create_dir(&path).unwrap();
    let first = stop_fallback(&mut host, &Value::Null, 3000);
    assert_eq!(first["stored"], true, "{first}");
    assert_eq!(first["stopConfirmed"], false);
    assert_eq!(first["record"]["status"], "requested");
    let history = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    let transcript = fs::read(temp.0.join("transcripts/1970-01-01.jsonl")).unwrap();
    drop(host);
    fs::remove_dir(&path).unwrap();
    fs::rename(temp.0.join("stop-backup.jsonl"), &path).unwrap();
    let mut host = History::open(&temp.0).unwrap();
    assert_eq!(
        host.request(
            &json!({"op":"stop_save","record":{"threadId":"thread","targetEventId":"origin",
        "status":"requested","requestIds":["second"]}})
        )["record"]["requestIds"],
        json!(["first", "second"])
    );
    let retry = stop_fallback(&mut host, &Value::Null, 86_403_000);
    assert_eq!(retry["stopConfirmed"], true, "{retry}");
    assert_eq!(retry["record"]["status"], "stopped");
    assert_eq!(retry["record"]["requestIds"], json!(["first", "second"]));
    assert_eq!(retry["final"], first["final"]);
    assert_eq!(
        stop_fallback(&mut host, &Value::Null, 86_403_001)["final"],
        first["final"]
    );
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        history
    );
    assert_eq!(
        fs::read(temp.0.join("transcripts/1970-01-01.jsonl")).unwrap(),
        transcript
    );
    assert!(!temp.0.join("transcripts/1970-01-02.jsonl").exists());
}
