use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    process::{Command, Stdio},
};

// Owns the actual OS pipe framing contract; no desktop factory or credential lookup.
#[test]
fn helper_pipe_roundtrip_and_rejected_frames() {
    let request = json!({"version":1,"goal":{"ids":{"task_id":"t","parent_id":"p","origin_id":"o","attempt_id":"a"},"goal":"synthetic","context":"","authorization":"transport only"},"process_id":1,"window_id":1,"display_id":1,"allowed":[],"action_budget":1,"duration_ms":1000,"model":"fixture","api_key":"synthetic-not-a-secret"});
    let good = serde_json::to_vec(&request).unwrap();
    for (index, bytes) in [good, b"{}".to_vec(), vec![0; 65537]]
        .into_iter()
        .enumerate()
    {
        let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-computer-use-helper"))
            .arg("--check-stdio")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut input = child.stdin.take().unwrap();
        input
            .write_all(&(bytes.len() as u32).to_be_bytes())
            .unwrap();
        if bytes.len() <= 65536 {
            input.write_all(&bytes).unwrap();
        }
        drop(input);
        let mut output = Vec::new();
        child
            .stdout
            .take()
            .unwrap()
            .read_to_end(&mut output)
            .unwrap();
        assert!(child.wait().unwrap().success());
        assert_eq!(
            u32::from_be_bytes(output[..4].try_into().unwrap()) as usize,
            output.len() - 4
        );
        let response: Value = serde_json::from_slice(&output[4..]).unwrap();
        if index == 0 {
            assert_eq!(response["outcome"]["status"], "stuck");
            assert_eq!(response["outcome"]["ids"]["attempt_id"], "a");
            assert_eq!(response["outcome"]["evidence_ids"], json!([]));
        } else {
            assert!(response["error"].is_string());
        }
        assert!(
            !String::from_utf8(output[4..].to_vec())
                .unwrap()
                .contains("synthetic-not-a-secret")
        );
    }
}
