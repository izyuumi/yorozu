//! IPC state invariants for new temporary profiles; no legacy migration/fault injection.
use serde_json::json;
use std::fs;
use yorozu_host_core::{alpha::Conversation, now_ms};
#[test]
fn acceptance_retry_stop_and_restart_never_reissue_an_uncertain_task() {
    let root = std::env::temp_dir().join(format!(
        "yorozu-alpha-test-{}-{}",
        std::process::id(),
        now_ms()
    ));
    let submit = json!({"runId":"unique-run","text":"日本語で結果を確認する"});
    {
        let mut owner = Conversation::open(&root).unwrap();
        let (receipt, event) = owner.submit(&submit).unwrap();
        assert_eq!(
            receipt,
            json!({"accepted":true,"runId":"unique-run","replayed":false})
        );
        assert_eq!(event.unwrap()["kind"], "accepted");
        assert_eq!(owner.submit(&submit).unwrap().0["replayed"], true);
        assert!(owner.submit(&submit).unwrap().1.is_none());
        assert_eq!(
            owner
                .submit(&json!({"runId":"unique-run","text":"changed"}))
                .unwrap()
                .0["error"],
            "conflicting-run"
        );
        assert_eq!(
            owner
                .submit(&json!({"runId":"new-run","text":"another"}))
                .unwrap()
                .0["error"],
            "worker-busy"
        );
        let stop = json!({"runId":"unique-run"});
        let (_, event) = owner.stop(&stop).unwrap();
        assert_eq!(event.unwrap()["kind"], "stop_requested");
        assert!(owner.stop(&stop).unwrap().1.is_none());
        assert_eq!(owner.snapshot()["activeRunId"], "unique-run");
        assert!(
            !owner.snapshot()["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|event| event["kind"] == "stopped")
        );
    }
    {
        let mut owner = Conversation::open(&root).unwrap();
        let snapshot = owner.snapshot();
        assert!(snapshot["activeRunId"].is_null());
        assert_eq!(
            snapshot["events"].as_array().unwrap().last().unwrap()["kind"],
            "unconfirmed"
        );
        assert_eq!(owner.submit(&submit).unwrap().0["replayed"], true);
        assert!(owner.submit(&submit).unwrap().1.is_none());
        assert_eq!(
            owner
                .submit(&json!({"runId":"new-run","text":"new distinct task"}))
                .unwrap()
                .0["accepted"],
            true
        );
    }
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn nonempty_unmarked_directory_is_preserved_and_refused() {
    let root = std::env::temp_dir().join(format!(
        "yorozu-alpha-guard-{}-{}",
        std::process::id(),
        now_ms()
    ));
    fs::create_dir(&root).unwrap();
    fs::write(root.join("keep.txt"), "existing user data").unwrap();
    assert!(Conversation::open(&root).is_err());
    assert_eq!(
        fs::read_to_string(root.join("keep.txt")).unwrap(),
        "existing user data"
    );
    assert!(!root.join("state").exists());
    fs::remove_dir_all(root).unwrap();
}
