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

#[cfg(unix)]
#[test]
fn queued_terminal_is_not_lost_when_worker_exits_while_requests_are_waiting() {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let temp = std::env::temp_dir().join(format!(
        "yorozu-alpha-pipe-{}-{}",
        std::process::id(),
        now_ms()
    ));
    fs::create_dir(&temp).unwrap();
    let script = temp.join("worker.sh");
    let mut script_text = String::from("read request\n");
    for _ in 0..48 {
        let packet =
            json!({"version":1,"runId":"fast-worker","kind":"update","text":"x".repeat(4000)});
        script_text.push_str(&format!("printf '%s\\n' '{packet}'\n"));
    }
    script_text.push_str("printf '%s\\n' '{\"version\":1,\"runId\":\"fast-worker\",\"kind\":\"completed\",\"text\":\"synthetic terminal\",\"data\":{\"evidence\":\"provider-terminal\"}}'\n");
    fs::write(&script, script_text).unwrap();
    for attempt in 0..3 {
        let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-alpha-host"))
            .arg(temp.join(format!("profile-{attempt}")))
            .arg("/bin/sh")
            .arg(&script)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut input = child.stdin.take().unwrap();
        writeln!(input, "{}", json!({"version":1,"id":"submit","op":"submit","runId":"fast-worker","text":"one bounded task"})).unwrap();
        // Ordinary concurrent snapshots make the final worker frame wait behind queued input.
        for id in 0..64 {
            writeln!(
                input,
                "{}",
                json!({"version":1,"id":format!("snapshot-{id}"),"op":"snapshot"})
            )
            .unwrap();
        }
        drop(input);
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let frames: Vec<serde_json::Value> = String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert!(
            frames
                .iter()
                .any(|frame| frame["event"]["kind"] == "completed"),
            "queued terminal was lost on iteration {attempt}"
        );
        assert!(
            !frames
                .iter()
                .any(|frame| frame["event"]["kind"] == "unconfirmed"),
            "owned terminal was downgraded on iteration {attempt}"
        );
    }
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn snapshot_budget_refuses_a_new_task_before_the_native_pipe_limit() {
    let root = std::env::temp_dir().join(format!(
        "yorozu-alpha-budget-{}-{}",
        std::process::id(),
        now_ms()
    ));
    let mut owner = Conversation::open(&root).unwrap();
    let mut refused = false;
    for index in 0..12 {
        let run = format!("large-{index}");
        let (receipt, _) = owner
            .submit(&json!({"runId":run,"text":"\"".repeat(16000)}))
            .unwrap();
        if receipt["error"] == "profile-size-limit" {
            refused = true;
            break;
        }
        assert_eq!(receipt["accepted"], true);
        for _ in 0..2 {
            owner
                .record(
                    &run,
                    "activity",
                    None,
                    Some(json!({"output":"x".repeat(4000)})),
                )
                .unwrap();
        }
        owner
            .record(&run, "completed", Some(&"あ".repeat(16000)), None)
            .unwrap();
        owner.active = None;
        let frame = json!({"version":1,"id":"snapshot-request","result":owner.snapshot()});
        assert!(
            serde_json::to_vec(&frame).unwrap().len() <= 1_048_576,
            "valid snapshot exceeded native IPC contract"
        );
    }
    assert!(
        refused,
        "profile must refuse more work before exhausting the response budget"
    );
    drop(owner);
    let reopened = Conversation::open(&root).unwrap();
    assert!(
        serde_json::to_vec(&json!({"version":1,"id":"snapshot","result":reopened.snapshot()}))
            .unwrap()
            .len()
            <= 1_048_576
    );
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}
