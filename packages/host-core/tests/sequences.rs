use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
};
use yorozu_host_core::{now_ms, sequences::Sequences};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-sequences-{}-{}-{}",
            std::process::id(),
            now_ms(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn projection(&self) -> PathBuf {
        self.0.join("channel-seq.json")
    }
    fn canonical(&self) -> PathBuf {
        self.0.join(".rust-channel-seq-state.json")
    }
    fn backups(&self) -> Vec<PathBuf> {
        fs::read_dir(&self.0)
            .unwrap()
            .map(|item| item.unwrap().path())
            .filter(|path| {
                path.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .contains("-original.")
            })
            .collect()
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn get(store: &mut Sequences, pubkey: &str) -> Value {
    store.request(&json!({"op":"seq_get","pub":pubkey}))
}
fn save(store: &mut Sequences, records: Value) -> Value {
    store.request(&json!({"op":"seq_save","records":records}))
}
fn records(send: u64, recv: u64) -> Value {
    json!({"peer":{"sendSeq":send,"recvSeq":recv}})
}
#[test]
fn exact_legacy_bytes_and_unknown_fields_survive_monotonic_updates_and_peer_removal() {
    let temp = Temp::new();
    let original = b"{ \"peer\": {\"sendSeq\":1e3,\"recvSeq\":2.0,\"future\":{\"keep\":true}},\"omitted\":{\"sendSeq\":5,\"recvSeq\":9} }\n";
    fs::write(temp.projection(), original).unwrap();
    let mut store = Sequences::open(&temp.0).unwrap();
    assert_eq!(get(&mut store, "peer"), json!({"sendSeq":1000,"recvSeq":2}));
    assert_eq!(fs::read(temp.projection()).unwrap(), original);
    assert_eq!(fs::read(&temp.backups()[0]).unwrap(), original);
    assert_eq!(save(&mut store, records(2000, 3))["stored"], true);
    assert_eq!(save(&mut store, json!({}))["stored"], true);
    drop(store);
    let mut store = Sequences::open(&temp.0).unwrap();
    assert_eq!(get(&mut store, "peer"), json!({"sendSeq":2000,"recvSeq":3}));
    assert_eq!(get(&mut store, "omitted"), json!({"sendSeq":5,"recvSeq":9}));
    let projection: Value = serde_json::from_slice(&fs::read(temp.projection()).unwrap()).unwrap();
    assert_eq!(projection["peer"]["future"], json!({"keep":true}));
    assert_eq!(fs::read(&temp.backups()[0]).unwrap(), original);
}
#[test]
fn legacy_devices_are_retained_before_identical_currency_publishes_a_projection() {
    let temp = Temp::new();
    let original = b"[ {\"pub\":\"peer\",\"sendSeq\":20,\"recvSeq\":7,\"future\":true},\"old-peer\",{\"pub\":\"peer\",\"sendSeq\":10,\"recvSeq\":9} ]\n";
    let devices = temp.0.join("devices.json");
    fs::write(&devices, original).unwrap();
    let mut store = Sequences::open(&temp.0).unwrap();
    assert_eq!(
        store.request(&json!({"op":"seq_open"}))["hasProjection"],
        false
    );
    assert_eq!(get(&mut store, "peer"), json!({"sendSeq":20,"recvSeq":9}));
    assert_eq!(
        get(&mut store, "old-peer"),
        json!({"sendSeq":0,"recvSeq":0})
    );
    assert_eq!(save(&mut store, records(20, 9))["hasProjection"], true);
    assert_eq!(fs::read(&devices).unwrap(), original);
    assert_eq!(fs::read(&temp.backups()[0]).unwrap(), original);
}
#[test]
fn invalid_or_lower_currency_never_changes_proved_state_and_does_not_poison_valid_requests() {
    let temp = Temp::new();
    let mut store = Sequences::open(&temp.0).unwrap();
    assert_eq!(save(&mut store, records(1000, 10))["stored"], true);
    let original = fs::read(temp.projection()).unwrap();
    for bad in [
        records(999, 11),
        records(1001, 9),
        json!({"peer":{"sendSeq":1000,"recvSeq":1.5}}),
        json!({"peer":{"sendSeq":9007199254740992u64,"recvSeq":10}}),
        json!({"peer":{"sendSeq":-1,"recvSeq":10}}),
    ] {
        assert!(save(&mut store, bad).get("error").is_some());
        assert_eq!(fs::read(temp.projection()).unwrap(), original);
    }
    let too_many: serde_json::Map<String, Value> = (0..17)
        .map(|i| (format!("peer-{i}"), json!({"sendSeq":0,"recvSeq":0})))
        .collect();
    assert_eq!(
        save(&mut store, json!(too_many))["error"],
        "invalid-sequence-records"
    );
    assert_eq!(
        save(&mut store, records(9007199254740991, 11))["stored"],
        true
    );
}
#[test]
fn interrupted_projection_recovers_from_previous_or_missing_bytes_and_forward_legacy_merges_only() {
    for missing in [false, true] {
        let temp = Temp::new();
        let mut store = Sequences::open(&temp.0).unwrap();
        save(&mut store, records(1000, 1));
        let previous = fs::read(temp.projection()).unwrap();
        save(&mut store, records(2000, 2));
        let current = fs::read(temp.projection()).unwrap();
        drop(store);
        if missing {
            fs::remove_file(temp.projection()).unwrap();
        } else {
            fs::write(temp.projection(), previous).unwrap();
        }
        let mut store = Sequences::open(&temp.0).unwrap();
        assert_eq!(get(&mut store, "peer"), json!({"sendSeq":2000,"recvSeq":2}));
        assert_eq!(fs::read(temp.projection()).unwrap(), current);
        drop(store);
        let newer = b"{\"peer\":{\"sendSeq\":3000,\"recvSeq\":3,\"future\":true},\"new\":{\"sendSeq\":1,\"recvSeq\":0}}";
        fs::write(temp.projection(), newer).unwrap();
        let mut store = Sequences::open(&temp.0).unwrap();
        assert_eq!(get(&mut store, "peer"), json!({"sendSeq":3000,"recvSeq":3}));
        assert_eq!(get(&mut store, "new"), json!({"sendSeq":1,"recvSeq":0}));
        drop(store);
        // A later compatible projection can omit a peer; its proved counters stay authoritative.
        fs::write(
            temp.projection(),
            b"{\"new\":{\"sendSeq\":2,\"recvSeq\":0}}",
        )
        .unwrap();
        let mut store = Sequences::open(&temp.0).unwrap();
        assert_eq!(get(&mut store, "peer")["recvSeq"], 3);
        drop(store);
        let lower = b"{\"peer\":{\"sendSeq\":2999,\"recvSeq\":3}}";
        fs::write(temp.projection(), lower).unwrap();
        assert!(Sequences::open(&temp.0).is_err());
        assert_eq!(fs::read(temp.projection()).unwrap(), lower);
    }
}
#[test]
fn live_owner_and_external_drift_fence_currency_until_restart() {
    let temp = Temp::new();
    let mut store = Sequences::open(&temp.0).unwrap();
    assert!(Sequences::open(&temp.0).is_err());
    save(&mut store, records(1000, 1));
    fs::write(
        temp.projection(),
        serde_json::to_vec(&records(2000, 2)).unwrap(),
    )
    .unwrap();
    assert_eq!(get(&mut store, "peer")["error"], "sequence-storage-failed");
    assert_eq!(
        save(&mut store, records(3000, 3))["error"],
        "sequence-storage-failed"
    );
    drop(store);
    let mut store = Sequences::open(&temp.0).unwrap();
    assert_eq!(get(&mut store, "peer")["recvSeq"], 2);
}
#[test]
fn projection_directory_blocker_is_retryable_without_advancing_accepted_currency() {
    let temp = Temp::new();
    let mut store = Sequences::open(&temp.0).unwrap();
    save(&mut store, records(1000, 1));
    fs::remove_file(temp.projection()).unwrap();
    fs::create_dir(temp.projection()).unwrap();
    assert_eq!(
        save(&mut store, records(1000, 2))["error"],
        "sequence-projection-unavailable"
    );
    fs::remove_dir(temp.projection()).unwrap();
    assert_eq!(get(&mut store, "peer")["recvSeq"], 1);
    assert_eq!(save(&mut store, records(1000, 2))["stored"], true);
}
#[test]
fn malformed_projection_devices_and_corrupt_canonical_are_retained_without_migration() {
    for (name, bad) in [
        ("channel-seq.json", b"{\"half-written\":".as_slice()),
        (
            "devices.json",
            b"[{\"pub\":\"peer\",\"recvSeq\":-1}]".as_slice(),
        ),
    ] {
        let temp = Temp::new();
        let path = temp.0.join(name);
        fs::write(&path, bad).unwrap();
        assert!(Sequences::open(&temp.0).is_err());
        assert_eq!(fs::read(path).unwrap(), bad);
        assert!(!temp.canonical().exists());
        assert!(temp.backups().is_empty());
    }
    let temp = Temp::new();
    let mut store = Sequences::open(&temp.0).unwrap();
    save(&mut store, records(1, 1));
    drop(store);
    let mut corrupt: Value = serde_json::from_slice(&fs::read(temp.canonical()).unwrap()).unwrap();
    corrupt["state"]["records"]["peer"]["recvSeq"] = json!(0);
    let bytes = serde_json::to_vec(&corrupt).unwrap();
    fs::write(temp.canonical(), &bytes).unwrap();
    assert!(Sequences::open(&temp.0).is_err());
    assert_eq!(fs::read(temp.canonical()).unwrap(), bytes);
}
#[test]
fn original_backups_are_bounded_without_deletion_and_exact_existing_backup_can_reopen_at_limit() {
    let temp = Temp::new();
    let original = serde_json::to_vec(&records(1, 1)).unwrap();
    fs::write(temp.projection(), &original).unwrap();
    for i in 0..128 {
        fs::write(
            temp.0.join(format!(
                ".rust-channel-seq-projection-original.retained-{i}.json"
            )),
            b"retained original",
        )
        .unwrap();
    }
    assert!(Sequences::open(&temp.0).is_err());
    assert_eq!(temp.backups().len(), 128);
    assert_eq!(fs::read(temp.projection()).unwrap(), original);
    let temp = Temp::new();
    fs::write(temp.projection(), &original).unwrap();
    drop(Sequences::open(&temp.0).unwrap());
    for i in 0..127 {
        fs::write(
            temp.0.join(format!(
                ".rust-channel-seq-devices-original.retained-{i}.json"
            )),
            b"retained original",
        )
        .unwrap();
    }
    fs::remove_file(temp.canonical()).unwrap();
    assert!(Sequences::open(&temp.0).is_ok());
    assert_eq!(temp.backups().len(), 128);
}
#[test]
fn actual_worker_termination_after_currency_ack_preserves_reserved_sends_and_accepted_receives() {
    let temp = Temp::new();
    let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .args(["history", temp.0.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    writeln!(
        child.stdin.as_mut().unwrap(),
        "{}",
        json!({"id":"rpc","op":"seq_save","records":records(1000, 11)})
    )
    .unwrap();
    let mut response = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut response)
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&response).unwrap()["result"]["stored"],
        true
    );
    child.kill().unwrap();
    child.wait().unwrap();
    let mut store = Sequences::open(&temp.0).unwrap();
    assert_eq!(
        get(&mut store, "peer"),
        json!({"sendSeq":1000,"recvSeq":11})
    );
    assert_eq!(
        save(&mut store, records(999, 11))["error"],
        "conflicting-sequence-currency"
    );
}
#[cfg(unix)]
#[test]
fn symlinks_are_refused_and_generated_files_private_without_changing_existing_directory_permissions()
 {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let temp = Temp::new();
    fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(
        temp.projection(),
        serde_json::to_vec(&records(1, 1)).unwrap(),
    )
    .unwrap();
    let mut store = Sequences::open(&temp.0).unwrap();
    save(&mut store, records(2, 2));
    drop(store);
    for path in [
        temp.canonical(),
        temp.0.join(".rust-channel-seq-owner.lock"),
        temp.projection(),
        temp.backups()[0].clone(),
    ] {
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert_eq!(
        fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777,
        0o755
    );
    let old = fs::read(temp.projection()).unwrap();
    let retained = temp.0.join("retained");
    fs::rename(temp.projection(), &retained).unwrap();
    symlink(&retained, temp.projection()).unwrap();
    assert!(Sequences::open(&temp.0).is_err());
    assert_eq!(fs::read(retained).unwrap(), old);
    let temp = Temp::new();
    fs::write(
        temp.projection(),
        serde_json::to_vec(&records(1, 1)).unwrap(),
    )
    .unwrap();
    symlink(
        temp.projection(),
        temp.0
            .join(".rust-channel-seq-projection-original.link.json"),
    )
    .unwrap();
    assert!(Sequences::open(&temp.0).is_err());
}
