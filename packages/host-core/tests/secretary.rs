//! Explicit secretary profile contracts; fixtures never contain legacy production state.
use serde_json::json;
use std::{fs, path::PathBuf};
use yorozu_host_core::{alpha::Conversation, now_ms};

fn fixture(name: &str) -> (PathBuf, PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!(
        "yorozu-secretary-{name}-{}-{}",
        std::process::id(),
        now_ms()
    ));
    fs::create_dir(&dir).unwrap();
    let dir = dir.canonicalize().unwrap();
    (
        dir.clone(),
        dir.join("secretary-v1"),
        dir.join("Yorozu Secretary"),
    )
}

#[test]
fn persistent_runs_share_one_locked_workspace_without_a_global_task_limit() {
    let (dir, root, workspace) = fixture("runs");
    for index in 0..14 {
        let run = format!("run-{index}");
        let request = json!({"runId":run,"text":"one accepted task","turn":{"model":"chosen-model","effort":"high"}});
        {
            let mut owner = Conversation::open_secretary(&root, &run, &workspace).unwrap();
            assert_eq!(owner.workspace, workspace);
            assert!(Conversation::open_secretary(&root, "concurrent", &workspace).is_err());
            assert_eq!(owner.submit(&request).unwrap().0["accepted"], true);
            owner
                .record(
                    &run,
                    "session",
                    None,
                    Some(json!({"sessionId":"persistent-provider-session"})),
                )
                .unwrap();
            owner
                .record(
                    &run,
                    "completed",
                    Some("retained answer"),
                    Some(json!({"evidence":"provider-terminal"})),
                )
                .unwrap();
            owner.active = None;
        }
        let mut reopened = Conversation::open_secretary(&root, &run, &workspace).unwrap();
        assert_eq!(reopened.submit(&request).unwrap().0["replayed"], true);
        assert!(reopened.submit(&request).unwrap().1.is_none());
        let snapshot = reopened.snapshot();
        let events = snapshot["events"].as_array().unwrap();
        assert_eq!(events.last().unwrap()["text"], "retained answer");
        assert!(
            events
                .iter()
                .any(|event| event["data"]["sessionId"] == "persistent-provider-session")
        );
    }
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn explicit_mode_refuses_existing_data_and_symlinked_workspaces() {
    let (dir, root, workspace) = fixture("guards");
    let legacy = dir.join("legacy");
    fs::create_dir(&legacy).unwrap();
    fs::write(legacy.join("threads.json"), b"preserve legacy bytes").unwrap();
    assert!(Conversation::open_secretary(&legacy, "run", &workspace).is_err());
    fs::create_dir(&root).unwrap();
    fs::write(root.join("keep"), b"preserve unmarked root").unwrap();
    assert!(Conversation::open_secretary(&root, "run", &workspace).is_err());
    assert_eq!(
        fs::read(root.join("keep")).unwrap(),
        b"preserve unmarked root"
    );
    assert_eq!(
        fs::read(legacy.join("threads.json")).unwrap(),
        b"preserve legacy bytes"
    );
    assert!(!root.join("state").exists());
    fs::remove_file(root.join("keep")).unwrap();
    fs::create_dir(&workspace).unwrap();
    fs::write(workspace.join("keep"), b"existing project").unwrap();
    assert!(Conversation::open_secretary(&root, "run", &workspace).is_err());
    assert_eq!(
        fs::read(workspace.join("keep")).unwrap(),
        b"existing project"
    );
    #[cfg(unix)]
    {
        fs::remove_dir_all(&workspace).unwrap();
        std::os::unix::fs::symlink(&legacy, &workspace).unwrap();
        assert!(Conversation::open_secretary(&root, "run", &workspace).is_err());
        assert!(!legacy.join(".yorozu-secretary-workspace-v1").exists());
    }
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn invalid_payloads_and_conflicting_admissions_never_start_a_run() {
    let (dir, root, workspace) = fixture("payload");
    let mut owner = Conversation::open_secretary(&root, "one-run", &workspace).unwrap();
    for payload in [
        json!({"bypass":true}),
        json!({"effort":"invented"}),
        json!({"attachments":[{"name":"x","mime":"image/png","path":"relative.png"}]}),
    ] {
        let (receipt, event) = owner
            .submit(&json!({"runId":"one-run","text":"task","turn":payload}))
            .unwrap();
        assert_eq!(receipt["error"], "invalid-turn");
        assert!(event.is_none());
    }
    assert!(owner.snapshot()["events"].as_array().unwrap().is_empty());
    let oversized = json!({"runId":"one-run","text":"あ".repeat(22000),"turn":{}});
    assert_eq!(owner.submit(&oversized).unwrap().0["error"], "invalid-text");
    // Long Japanese context and a model-supported effort must survive admission and replay.
    let request = json!({"runId":"one-run","text":"日本語".repeat(6000),"turn":{"sessionId":"resume-me","effort":"persistent"}});
    assert_eq!(owner.submit(&request).unwrap().0["accepted"], true);
    assert_eq!(
        owner
            .submit(
                &json!({"runId":"one-run","text":"task","turn":{"sessionId":"another-session"}})
            )
            .unwrap()
            .0["error"],
        "conflicting-run"
    );
    assert_eq!(
        owner
            .submit(&json!({"runId":"other-run","text":"task","turn":{}}))
            .unwrap()
            .0["error"],
        "invalid-run"
    );
    drop(owner);
    let mut reopened = Conversation::open_secretary(&root, "one-run", &workspace).unwrap();
    assert_eq!(reopened.submit(&request).unwrap().0["replayed"], true);
    assert_eq!(
        reopened.snapshot()["events"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["kind"],
        "unconfirmed"
    );
    drop(reopened);
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn steering_is_immutable_durable_and_never_reissued_after_reopen() {
    let (dir, root, workspace) = fixture("steering");
    let mut owner = Conversation::open_secretary(&root, "run", &workspace).unwrap();
    owner
        .submit(&json!({"runId":"run","text":"write A","turn":{}}))
        .unwrap();
    let change =
        json!({"runId":"run","deliveryId":"change","text":"write B instead","attachments":[]});
    let (receipt, event) = owner.steer(&change).unwrap();
    assert_eq!(receipt["submitted"], true);
    assert_eq!(event.unwrap()["kind"], "steer_requested");
    assert_eq!(owner.steer(&change).unwrap().0["replayed"], true);
    assert!(owner.steer(&change).unwrap().1.is_none());
    let mut conflict = change.clone();
    conflict["text"] = json!("write C");
    assert_eq!(
        owner.steer(&conflict).unwrap().0["error"],
        "conflicting-steer"
    );
    let result = json!({"data":{"deliveryId":"change","accepted":true}});
    assert!(owner.accepts_steer_result("run", &result));
    assert!(!owner.accepts_steer_result(
        "run",
        &json!({"data":{"deliveryId":"unknown","accepted":true}})
    ));
    owner
        .record("run", "steer_result", None, Some(result["data"].clone()))
        .unwrap();
    assert!(!owner.accepts_steer_result("run", &result));
    owner.stop(&json!({"runId":"run"})).unwrap();
    let mut later = change.clone();
    later["deliveryId"] = json!("later");
    assert_eq!(owner.steer(&later).unwrap().0["submitted"], false);
    drop(owner);
    let mut reopened = Conversation::open_secretary(&root, "run", &workspace).unwrap();
    assert!(reopened.steer(&change).unwrap().1.is_none());
    assert_eq!(reopened.steer(&later).unwrap().0["submitted"], false);
    assert_eq!(
        reopened.snapshot()["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["kind"] == "steer_requested")
            .count(),
        1
    );
    drop(reopened);
    fs::remove_dir_all(dir).unwrap();
}
