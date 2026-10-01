use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{AttachmentStore, CHUNK_BYTES, FILE_BYTES, now_ms};

static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-rust-test-{}-{}-{}",
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
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn chunk(bytes: &[u8], offset: usize, total: &[u8], deadline: u64) -> Value {
    json!({"messageId":"message","index":0,"offset":offset,"totalBytes":total.len(),"sha256":hash(total),"deadline":deadline,"data":STANDARD.encode(bytes)})
}
fn descriptors(bytes: &[u8]) -> Value {
    json!([{"name":"日本語.txt","mime":"text/plain","bytes":bytes.len(),"sha256":hash(bytes)}])
}

#[test]
fn acknowledged_chunks_survive_reopen_and_repeated_chunks_never_duplicate() {
    let temp = Temp::new();
    let bytes = vec![42; 400_000];
    let now = now_ms();
    let deadline = now + 60_000;
    let first = chunk(&bytes[..CHUNK_BYTES as usize], 0, &bytes, deadline);
    let mut store = AttachmentStore::open(&temp.0).unwrap();
    assert_eq!(
        store.chunk("phone", "thread", &first, now),
        json!({"nextOffset":CHUNK_BYTES})
    );
    assert_eq!(
        store.assemble("phone", "message", "thread", &descriptors(&bytes), deadline),
        json!({"missing":{"index":0,"nextOffset":CHUNK_BYTES}})
    );
    drop(store);
    let mut store = AttachmentStore::open(&temp.0).unwrap();
    assert_eq!(
        store.chunk("phone", "thread", &first, now),
        json!({"nextOffset":CHUNK_BYTES})
    );
    assert_eq!(
        store.chunk(
            "phone",
            "thread",
            &chunk(
                &bytes[CHUNK_BYTES as usize..],
                CHUNK_BYTES as usize,
                &bytes,
                deadline
            ),
            now
        ),
        json!({"nextOffset":bytes.len()})
    );
    let assembled = store.assemble("phone", "message", "thread", &descriptors(&bytes), deadline);
    assert_eq!(assembled["attachments"][0]["data"], STANDARD.encode(&bytes));
    assert_eq!(
        store.assemble("other", "message", "thread", &descriptors(&bytes), deadline),
        json!({"missing":{"index":0,"nextOffset":0}})
    );
}

#[test]
fn conflicting_bytes_thread_and_deadline_do_not_replace_original() {
    let temp = Temp::new();
    let mut store = AttachmentStore::open(&temp.0).unwrap();
    let now = now_ms();
    let deadline = now + 60_000;
    let original = b"original";
    let data = chunk(original, 0, original, deadline);
    assert_eq!(store.chunk("phone", "thread", &data, now)["nextOffset"], 8);
    let mut altered = data.clone();
    altered["data"] = json!(STANDARD.encode(b"modified"));
    assert_eq!(
        store.chunk("phone", "thread", &altered, now)["reason"],
        "conflicting-attachment-upload"
    );
    assert_eq!(
        store.chunk("phone", "other-thread", &data, now)["reason"],
        "conflicting-attachment-upload"
    );
    altered = data.clone();
    altered["deadline"] = json!(deadline + 1);
    assert_eq!(
        store.chunk("phone", "thread", &altered, now)["reason"],
        "conflicting-attachment-upload"
    );
    assert_eq!(
        store.assemble(
            "phone",
            "message",
            "thread",
            &descriptors(original),
            deadline
        )["attachments"][0]["data"],
        STANDARD.encode(original)
    );
}

#[test]
fn legacy_node_metadata_and_partial_bytes_resume_without_rewrite_or_migration() {
    let temp = Temp::new();
    let now = now_ms();
    let deadline = now + 60_000;
    let bytes = b"legacy state";
    let folder = temp
        .0
        .join("attachment-uploads")
        .join(hash(b"phone\0message"));
    fs::create_dir_all(&folder).unwrap();
    let legacy = format!(
        "{{\"threadId\":\"thread\",\"totalBytes\":{},\"sha256\":\"{}\",\"deadline\":{}}}",
        bytes.len(),
        hash(bytes),
        deadline
    );
    fs::write(folder.join("0.json"), &legacy).unwrap();
    fs::write(folder.join("0.bin"), &bytes[..4]).unwrap();
    let mut store = AttachmentStore::open(&temp.0).unwrap();
    assert_eq!(
        store.chunk(
            "phone",
            "thread",
            &chunk(&bytes[4..], 4, bytes, deadline),
            now
        )["nextOffset"],
        bytes.len()
    );
    assert_eq!(fs::read_to_string(folder.join("0.json")).unwrap(), legacy);
    assert_eq!(
        store.assemble("phone", "message", "thread", &descriptors(bytes), deadline)["attachments"]
            [0]["data"],
        STANDARD.encode(bytes)
    );
}

#[test]
fn empty_files_and_missing_second_file_report_exact_slot() {
    let temp = Temp::new();
    let store = AttachmentStore::open(&temp.0).unwrap();
    let deadline = now_ms() + 60_000;
    assert_eq!(
        store.assemble("phone", "message", "thread", &descriptors(b""), deadline)["attachments"][0]
            ["data"],
        ""
    );
    let files = json!([{"name":"empty","mime":"text/plain","bytes":0,"sha256":hash(b"")},
        {"name":"missing","mime":"text/plain","bytes":5,"sha256":hash(b"hello")}]);
    assert_eq!(
        store.assemble("phone", "message", "thread", &files, deadline),
        json!({"missing":{"index":1,"nextOffset":0}})
    );
}

#[test]
fn invalid_frames_cannot_reserve_space_and_quota_survives_reopen() {
    let temp = Temp::new();
    let now = now_ms();
    let deadline = now + 60_000;
    let mut store = AttachmentStore::open(&temp.0).unwrap();
    for field in ["index", "offset", "totalBytes", "deadline"] {
        let mut data = chunk(b"a", 0, b"a", deadline);
        data[field] = json!(-1);
        assert_eq!(
            store.chunk("phone", "thread", &data, now)["reason"],
            "invalid-attachment-chunk"
        );
    }
    let mut data = chunk(b"a", 0, b"a", deadline);
    data["totalBytes"] = json!(FILE_BYTES + 1);
    assert_eq!(
        store.chunk("phone", "thread", &data, now)["reason"],
        "invalid-attachment-chunk"
    );
    data["totalBytes"] = json!(FILE_BYTES);
    data["data"] = json!("YQ==");
    for index in 0..4 {
        data["index"] = json!(index);
        assert!(
            store
                .chunk("phone", "thread", &data, now)
                .get("reason")
                .is_none()
        );
    }
    drop(store);
    let mut store = AttachmentStore::open(&temp.0).unwrap();
    data["index"] = json!(4);
    assert_eq!(
        store.chunk("phone", "thread", &data, now)["reason"],
        "oversized-attachments"
    );
}

#[test]
fn global_quota_is_reserved_across_devices_before_bytes_are_complete() {
    let temp = Temp::new();
    let now = now_ms();
    let deadline = now + 60_000;
    let mut store = AttachmentStore::open(&temp.0).unwrap();
    let mut data = chunk(b"a", 0, b"a", deadline);
    data["totalBytes"] = json!(FILE_BYTES);
    for index in 0..51 {
        data["messageId"] = json!(format!("m{index}"));
        assert!(
            store
                .chunk(&format!("device{index}"), "thread", &data, now)
                .get("reason")
                .is_none()
        );
    }
    data["messageId"] = json!("overflow");
    assert_eq!(
        store.chunk("other", "thread", &data, now)["reason"],
        "attachment-storage-full"
    );
}

#[test]
fn second_writer_is_rejected_and_lock_recovers_after_owner_drop() {
    let temp = Temp::new();
    let store = AttachmentStore::open(&temp.0).unwrap();
    assert!(AttachmentStore::open(&temp.0).is_err());
    drop(store);
    assert!(AttachmentStore::open(&temp.0).is_ok());
}

#[test]
fn corrupt_bytes_are_not_assembled_or_deleted() {
    let temp = Temp::new();
    let now = now_ms();
    let deadline = now + 60_000;
    let mut store = AttachmentStore::open(&temp.0).unwrap();
    let bytes = b"original";
    store.chunk("phone", "thread", &chunk(bytes, 0, bytes, deadline), now);
    let path = temp
        .0
        .join("attachment-uploads")
        .join(hash(b"phone\0message"))
        .join("0.bin");
    fs::write(&path, b"modified").unwrap();
    assert_eq!(
        store.assemble("phone", "message", "thread", &descriptors(bytes), deadline)["reason"],
        "corrupt-attachment-upload"
    );
    assert_eq!(fs::read(path).unwrap(), b"modified");
}

#[test]
fn worker_kill_after_ack_keeps_resumable_bytes_and_releases_process_lock() {
    let temp = Temp::new();
    let deadline = now_ms() + 60_000;
    let bytes = b"durable";
    let executable = env!("CARGO_BIN_EXE_yorozu-host-core");
    let mut child = Command::new(executable)
        .arg("attachments")
        .arg(&temp.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let request = json!({"id":"1","op":"chunk","source":"phone","threadId":"thread","data":chunk(bytes,0,bytes,deadline)});
    writeln!(child.stdin.as_mut().unwrap(), "{request}").unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    output.read_line(&mut line).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&line).unwrap()["result"]["nextOffset"],
        bytes.len()
    );
    child.kill().unwrap();
    child.wait().unwrap();
    let store = AttachmentStore::open(&temp.0).unwrap();
    assert_eq!(
        store.assemble("phone", "message", "thread", &descriptors(bytes), deadline)["attachments"]
            [0]["data"],
        STANDARD.encode(bytes)
    );
}

#[cfg(unix)]
#[test]
fn newly_created_private_files_are_owner_only_and_binary_symlink_is_rejected() {
    use std::os::unix::fs::{MetadataExt, symlink};
    let temp = Temp::new();
    let now = now_ms();
    let deadline = now + 60_000;
    let mut store = AttachmentStore::open(&temp.0).unwrap();
    let bytes = b"safe";
    store.chunk("phone", "thread", &chunk(bytes, 0, bytes, deadline), now);
    let folder = temp
        .0
        .join("attachment-uploads")
        .join(hash(b"phone\0message"));
    assert_eq!(
        fs::metadata(folder.join("0.bin")).unwrap().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(folder.join("0.json")).unwrap().mode() & 0o777,
        0o600
    );
    let target = temp.0.join("untouched");
    fs::write(&target, b"keep").unwrap();
    fs::remove_file(folder.join("0.bin")).unwrap();
    symlink(&target, folder.join("0.bin")).unwrap();
    assert_eq!(
        store.chunk("phone", "thread", &chunk(bytes, 0, bytes, deadline), now)["reason"],
        "attachment-storage-failed"
    );
    assert_eq!(fs::read(target).unwrap(), b"keep");
}
