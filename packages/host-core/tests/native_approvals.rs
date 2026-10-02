use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{history::History, now_ms};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-native-approval-{}-{}-{}",
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
fn setup(temp: &Temp, tool: &str, ts: u64) -> (History, Value) {
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
    let scope =
        json!({"eventId":"origin","turnId":"native:origin:final","attemptId":claim["attemptId"]});
    let card = json!({"id":"card-event","threadId":"thread","ts":ts,"agentId":"main","kind":"approval_card","data":{"actionId":"action","nativeAgent":"codex","actionClass":tool,"target":"{\"command\":\"pwd\"}"}});
    let proof = host.request(&json!({"op":"native_approval_raise","scope":scope,"event":card}));
    assert_eq!(proof["stored"], true, "{proof}");
    assert_eq!(proof["event"]["data"]["nativeRun"], scope);
    (host, proof["event"].clone())
}
fn decide(host: &mut History, id: &str, source: Option<&str>, ts: u64) -> Value {
    let mut event = json!({"id":id,"threadId":"thread","ts":ts,"agentId":"phone","kind":"approval_answer","data":{"actionId":"action","answer":"yes"}});
    if let Some(source) = source {
        event["data"]["source"] = json!(source);
    }
    host.request(&json!({"op":"native_approval_decide","event":event,"live":true}))
}
#[test]
fn native_permission_admission_is_scoped_durable_and_replays_without_another_effect() {
    let temp = Temp::new();
    let ts = now_ms();
    let (mut host, card) = setup(&temp, "mcp__mail__send", ts);
    let rejected = decide(&mut host, "notification", Some("notification"), ts);
    assert_eq!(rejected["status"]["data"]["status"], "rejected");
    assert_eq!(rejected["execute"], false);
    let applied = decide(&mut host, "app", None, ts);
    assert_eq!(applied["stored"], true);
    assert_eq!(applied["execute"], true);
    assert_eq!(applied["status"]["data"]["status"], "applied");
    assert_eq!(applied["events"].as_array().unwrap().len(), 2);
    let thread = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    let rows: Vec<Value> = String::from_utf8(thread.clone())
        .unwrap()
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect();
    assert_eq!(
        rows.iter()
            .filter(|r| r["kind"] == "approval_answer" && r["id"] == "app")
            .count(),
        1
    );
    assert_eq!(
        rows.iter()
            .filter(|r| r["kind"] == "approval_status"
                && r["data"]["requestId"] == "app"
                && r["data"]["status"] == "applied")
            .count(),
        1
    );
    let again = decide(&mut host, "app", None, ts);
    assert_eq!(again["execute"], false);
    assert_eq!(again["status"], applied["status"]);
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        thread
    );
    let other = decide(&mut host, "other", None, ts);
    assert_eq!(other["status"]["data"]["status"], "no-longer-needed");
    let before = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
    drop(host);
    let mut host = History::open(&temp.0).unwrap();
    let replay = decide(&mut host, "app", None, ts);
    assert_eq!(replay["stored"], true);
    assert_eq!(replay["execute"], false);
    assert_eq!(replay["status"], applied["status"]);
    assert_eq!(
        fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
        before
    );
    let conflicting = decide(&mut host, "app", Some("notification"), ts);
    assert_eq!(conflicting["stored"], false);
    assert_eq!(conflicting["reason"], "conflicting-request");
    assert_eq!(card["data"]["nativeAgent"], "codex");
}
#[test]
fn native_permission_card_age_and_partial_storage_never_authorize_execution() {
    for guard in ["old-card", "storage", "foreign-status"] {
        let temp = Temp::new();
        let ts = now_ms();
        let (mut host, _) = setup(
            &temp,
            "Bash",
            if guard == "old-card" {
                ts - 31 * 60_000
            } else {
                ts
            },
        );
        let before = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        if guard == "foreign-status" {
            let fake = json!({"id":"approval:forged:status","threadId":"thread","ts":ts,"agentId":"main","kind":"approval_status","data":{"requestId":"forged","actionId":"action","status":"applied"}});
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"native-approval-decision:forged","event":fake,"thread":true,"transcript":true}))["error"],"reserved-history-operation");
            assert_eq!(host.request(&json!({"op":"history_append","operationId":"foreign-status","event":fake,"thread":true,"transcript":true}))["stored"],true);
            let result = decide(&mut host, "app", None, ts);
            assert_ne!(result["stored"], true);
            assert_ne!(result["execute"], true);
            let rows = fs::read_to_string(temp.0.join("threads/thread.jsonl")).unwrap();
            assert!(!rows.contains("\"kind\":\"approval_answer\""));
        } else if guard == "storage" {
            let transcript = fs::read_dir(temp.0.join("transcripts"))
                .unwrap()
                .next()
                .unwrap()
                .unwrap()
                .path();
            let backup = transcript.with_extension("backup");
            fs::rename(&transcript, &backup).unwrap();
            fs::create_dir(&transcript).unwrap();
            let result = decide(&mut host, "app", None, ts);
            assert_ne!(result["stored"], true, "{result}");
            assert_ne!(result["execute"], true);
            assert_eq!(
                fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
                before
            );
            fs::remove_dir(&transcript).unwrap();
            fs::rename(backup, transcript).unwrap();
            drop(host);
            let mut host = History::open(&temp.0).unwrap();
            let after = decide(&mut host, "app", None, ts);
            assert_eq!(after["status"]["data"]["status"], "no-longer-needed");
            assert_eq!(after["execute"], false);
        } else {
            let result = decide(&mut host, "fresh-phone-answer", None, ts);
            assert_eq!(result["status"]["data"]["status"], "expired");
            assert_eq!(result["execute"], false);
            let rows = fs::read_to_string(temp.0.join("threads/thread.jsonl")).unwrap();
            assert!(!rows.contains("\"kind\":\"approval_answer\""));
        }
    }
}

#[test]
fn startup_policy_is_root_sampled_transcript_only_and_replays_original_without_starting() {
    for mode in [
        "missing",
        "grant",
        "expired",
        "legacy",
        "malformed",
        "wrong-type",
    ] {
        let temp = Temp::new();
        let ts = now_ms();
        let (mut host, card) = setup(&temp, "Bash", ts);
        let scope = &card["data"]["nativeRun"];
        let settings = temp.0.join("approval.json");
        match mode {
            "grant" => fs::write(
                &settings,
                json!({"yolo":true,"yoloUntil":ts+60_000}).to_string(),
            )
            .unwrap(),
            "expired" => {
                fs::write(&settings, json!({"yolo":true,"yoloUntil":ts-1}).to_string()).unwrap()
            }
            "legacy" => fs::write(&settings, r#"{"yolo":true}"#).unwrap(),
            "malformed" => fs::write(&settings, "{broken").unwrap(),
            "wrong-type" => fs::write(
                &settings,
                json!({"yolo":"true","yoloUntil":ts+60_000}).to_string(),
            )
            .unwrap(),
            _ => {}
        }
        let request = json!({"op":"run_attempt_policy","version":1,"threadId":"thread","eventId":scope["eventId"],"turnId":scope["turnId"],"attemptId":scope["attemptId"],"source":"codex","bypass":true});
        let before = fs::read(temp.0.join("threads/thread.jsonl")).unwrap();
        let proof = host.request(&request);
        assert_eq!(proof["stored"], true, "{mode}: {proof}");
        assert_eq!(proof["execute"], true);
        assert_eq!(proof["replayed"], false);
        assert_eq!(proof["policy"]["bypass"], mode == "grant");
        let sampled = proof["policy"]["sampledAt"].as_u64().unwrap();
        assert!(sampled >= ts && sampled <= now_ms());
        if mode == "grant" {
            assert_eq!(proof["policy"]["yoloUntil"], ts + 60_000);
        } else {
            assert!(proof["policy"]["yoloUntil"].is_null());
        }
        assert_eq!(proof["policy"]["source"], "codex");
        assert_eq!(proof["policy"]["eventId"], "origin");
        assert_eq!(proof["policy"]["turnId"], "native:origin:final");
        assert_eq!(proof["policy"]["attemptId"], scope["attemptId"]);
        assert_eq!(
            fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
            before
        );
        let transcript = fs::read(
            temp.0
                .join("transcripts")
                .read_dir()
                .unwrap()
                .next()
                .unwrap()
                .unwrap()
                .path(),
        )
        .unwrap();
        assert_eq!(
            String::from_utf8(transcript.clone())
                .unwrap()
                .lines()
                .filter(
                    |line| serde_json::from_str::<Value>(line).unwrap()["kind"] == "worker_policy"
                )
                .count(),
            1
        );
        fs::write(
            &settings,
            json!({"yolo":true,"yoloUntil":ts+120_000}).to_string(),
        )
        .unwrap();
        let replay = host.request(&request);
        assert_eq!(replay["stored"], true);
        assert_eq!(replay["execute"], false);
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["policy"], proof["policy"]);
        assert_eq!(
            fs::read(temp.0.join("threads/thread.jsonl")).unwrap(),
            before
        );
        assert_eq!(
            fs::read(
                temp.0
                    .join("transcripts")
                    .read_dir()
                    .unwrap()
                    .next()
                    .unwrap()
                    .unwrap()
                    .path()
            )
            .unwrap(),
            transcript
        );
        drop(host);
        let mut restarted = History::open(&temp.0).unwrap();
        let replay = restarted.request(&request);
        assert_eq!(replay["execute"], false);
        assert_eq!(replay["policy"], proof["policy"]);
        assert_eq!(restarted.request(&json!({"op":"history_append","operationId":proof["operationId"],"event":{"id":"fake","threadId":"thread","ts":ts,"kind":"worker_policy","data":{}},"transcript":true}))["error"], "reserved-history-operation");
    }
}

#[test]
fn startup_policy_cannot_authorize_a_replaced_stopped_or_unstored_attempt() {
    for mode in [
        "current",
        "source",
        "canonical-reply",
        "released",
        "stop",
        "storage",
    ] {
        let temp = Temp::new();
        let ts = now_ms();
        let (mut host, card) = setup(&temp, "Bash", ts);
        let scope = &card["data"]["nativeRun"];
        fs::write(
            temp.0.join("approval.json"),
            json!({"yolo":true,"yoloUntil":ts+60_000}).to_string(),
        )
        .unwrap();
        let request = json!({"op":"run_attempt_policy","version":1,"threadId":"thread","eventId":scope["eventId"],"turnId":scope["turnId"],"attemptId":scope["attemptId"],"source":"codex"});
        match mode {
            "source" | "canonical-reply" => {
                let path = temp.0.join("threads.json");
                let mut rows: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
                if mode == "source" {
                    rows[0]["agent"] = json!("claude-code");
                } else {
                    rows[0]["nativeTurn"]["id"] = json!("foreign-reply");
                }
                fs::write(path, rows.to_string()).unwrap();
            }
            "released" => {
                assert_eq!(host.request(&json!({"op":"run_attempt_release","threadId":"thread","eventId":scope["eventId"],"attemptId":scope["attemptId"]}))["released"], true);
            }
            "stop" => {
                assert_eq!(host.request(&json!({"op":"stop_save","record":{"targetEventId":"origin","threadId":"thread","status":"requested","requestIds":["stop"]}}))["record"]["status"], "requested");
            }
            "storage" => {
                let path = temp
                    .0
                    .join("transcripts")
                    .read_dir()
                    .unwrap()
                    .next()
                    .unwrap()
                    .unwrap()
                    .path();
                fs::rename(&path, path.with_extension("backup")).unwrap();
                fs::create_dir(path).unwrap();
            }
            "current" => {}
            _ => unreachable!(),
        }
        let proof = host.request(&request);
        if mode == "current" {
            assert_eq!(proof["execute"], true, "{mode}: {proof}");
            assert_eq!(proof["stored"], true);
            continue;
        }
        assert_ne!(proof["execute"], true, "{mode}: {proof}");
        assert_ne!(proof["stored"], true, "{mode}: {proof}");
    }
}
