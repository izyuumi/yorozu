use serde_json::{Value, json};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use yorozu_host_core::{history::History, now_ms};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-native-question-{}-{}-{}",
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
fn setup(temp: &Temp, allow_other: bool, ts: u64) -> (History, Value) {
    let mut host = History::open(&temp.0).unwrap();
    assert_eq!(host.request(&json!({"op":"thread_index_replace","expectedHash":null,"threads":[{"id":"thread","title":"Work","createdAt":"2026-01-01T00:00:00Z","archived":false,"agent":"codex"}]}))["stored"],true);
    let event = json!({"id":"origin","threadId":"thread","ts":now_ms(),"agentId":"phone","kind":"message","data":{"role":"user","text":"work"}});
    assert_eq!(host.request(&json!({"op":"accepted_accept","entry":{"id":"origin","threadId":"thread","identity":"a".repeat(64),"purpose":"conversation","event":event}}))["status"],"accepted");
    assert_eq!(host.request(&json!({"op":"history_append","operationId":"origin","event":event,"thread":true,"transcript":true}))["stored"],true);
    assert_eq!(
        host.request(&json!({"op":"queue_enqueue","eventId":"origin","threadId":"thread"}))["stored"],
        true
    );
    let claim =
        host.request(&json!({"op":"run_attempt_claim","threadId":"thread","eventId":"origin"}));
    assert_eq!(claim["claimed"], true);
    let scope =
        json!({"eventId":"origin","turnId":"native:origin:final","attemptId":claim["attemptId"]});
    let card = json!({"id":"card-event","threadId":"thread","ts":ts,"agentId":"main","kind":"question_card","data":{"questionId":"question","nativeAgent":"codex","question":"Which?","options":["A","B"],"allowOther":allow_other}});
    let proof = host.request(&json!({"op":"native_question_raise","scope":scope,"event":card}));
    assert_eq!(proof["stored"], true, "{proof}");
    assert_eq!(proof["event"]["data"]["nativeRun"], scope);
    (host, scope)
}
fn answer(id: &str, text: &str, ts: u64) -> Value {
    json!({"id":id,"threadId":"thread","ts":ts,"agentId":"phone","kind":"question_answer","data":{"questionId":"question","answer":text}})
}
fn decide(host: &mut History, event: &Value, live: bool) -> Value {
    host.request(&json!({"op":"native_question_decide","event":event,"live":live}))
}
#[test]
fn native_question_answer_is_immutable_durable_and_never_reexecutes_on_replay() {
    let temp = Temp::new();
    let ts = now_ms();
    let (mut host, _) = setup(&temp, false, ts);
    let rejected = decide(&mut host, &answer("invalid", "other", ts), true);
    assert_eq!(rejected["status"]["data"]["status"], "rejected");
    assert_eq!(rejected["execute"], false);
    let event = answer("answer", "A", ts);
    let applied = decide(&mut host, &event, true);
    assert_eq!(applied["stored"], true);
    assert_eq!(applied["execute"], true);
    assert_eq!(applied["status"]["kind"], "question_status");
    assert_eq!(applied["events"][0]["data"], event["data"]);
    let before = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    let replay = decide(&mut host, &event, true);
    assert_eq!(replay["execute"], false);
    assert_eq!(replay["events"], applied["events"]);
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        before
    );
    let conflict = decide(&mut host, &answer("answer", "B", ts), true);
    assert_eq!(conflict["reason"], "conflicting-request");
    let other = decide(&mut host, &answer("other", "B", ts), true);
    assert_eq!(other["status"]["data"]["status"], "no-longer-needed");
    drop(host);
    let mut host = History::open(&temp.0).unwrap();
    let before = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    let replay = decide(&mut host, &event, true);
    assert_eq!(replay["execute"], false);
    assert_eq!(replay["events"], applied["events"]);
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        before
    );
}
#[test]
fn native_question_stale_scopes_and_storage_uncertainty_never_deliver_an_answer() {
    for guard in [
        "source",
        "replacement",
        "stop",
        "old-question",
        "not-live",
        "storage",
        "forged-status",
        "free-text",
    ] {
        let temp = Temp::new();
        let ts = now_ms();
        let (mut host, scope) = setup(
            &temp,
            guard == "free-text",
            if guard == "old-question" {
                ts - 31 * 60_000
            } else {
                ts
            },
        );
        match guard {
            "source" => {
                let path = temp.0.join("threads.json");
                let mut rows: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
                rows[0]["agent"] = json!("claude-code");
                fs::write(path, serde_json::to_vec(&rows).unwrap()).unwrap();
            }
            "replacement" => {
                assert_eq!(host.request(&json!({"op":"run_attempt_release","threadId":"thread","eventId":"origin","attemptId":scope["attemptId"]}))["released"],true);
            }
            "stop" => {
                assert_eq!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"requested","requestIds":["stop"]}}))["record"]["status"],"requested");
            }
            "storage" => {
                let path = fs::read_dir(temp.0.join("transcripts"))
                    .unwrap()
                    .next()
                    .unwrap()
                    .unwrap()
                    .path();
                fs::rename(&path, path.with_extension("backup")).unwrap();
                fs::create_dir(path).unwrap();
            }
            "forged-status" => {
                let fake = json!({"id":"question:forged:status","threadId":"thread","ts":ts,"agentId":"main","kind":"question_status","data":{"questionId":"question","requestId":"forged","status":"applied"}});
                assert_eq!(host.request(&json!({"op":"history_append","operationId":"native-question-forged","event":fake,"thread":true,"transcript":true}))["error"],"reserved-history-operation");
                assert_eq!(host.request(&json!({"op":"history_append","operationId":"forged","event":fake,"thread":true,"transcript":true}))["stored"],true);
            }
            _ => {}
        }
        let before = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        let event = answer(
            "answer",
            if guard == "free-text" {
                "Cancelled"
            } else {
                "A"
            },
            ts,
        );
        let proof = decide(&mut host, &event, guard != "not-live");
        if ["free-text", "old-question"].contains(&guard) {
            assert_eq!(proof["execute"], true);
        } else {
            assert_ne!(proof["execute"], true, "{guard}: {proof}");
            let rows = fs::read_to_string(temp.0.join("threads/thread.jsonl")).unwrap();
            assert!(!rows.contains("\"kind\":\"question_answer\""), "{guard}");
            if guard == "not-live" {
                let replay = decide(&mut host, &event, true);
                assert_eq!(replay["execute"], false);
                assert_eq!(replay["events"], proof["events"]);
                drop(host);
                host = History::open(&temp.0).unwrap();
                let replay = decide(&mut host, &event, true);
                assert_eq!(replay["execute"], false);
                assert_eq!(replay["events"], proof["events"]);
            }
            if ["storage", "forged-status"].contains(&guard) {
                assert_eq!(rows.as_bytes(), before);
            }
        }
    }
}
