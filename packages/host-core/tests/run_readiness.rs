use serde_json::{Value, json};
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
