use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
};
use yorozu_host_core::{
    crypto::{self, HostCrypto, WireKeys},
    now_ms,
};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-wire-crypto-{}-{}-{}",
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
fn fixture(source: &str) -> Value {
    serde_json::from_str(match source {
        "swift" => include_str!("../../../fixtures/swift-vectors.json"),
        _ => include_str!("../../../fixtures/ts-vectors.json"),
    })
    .unwrap()
}
fn bytes(value: &Value, key: &str) -> Vec<u8> {
    crypto::decode(value[key].as_str().unwrap()).unwrap()
}
fn fixed<const N: usize>(value: &Value, key: &str) -> [u8; N] {
    bytes(value, key).try_into().unwrap()
}
fn keys(temp: &Temp, v: &Value) {
    fs::write(temp.0.join("keys.json"),format!("{{ \"session\": {{\"priv\":{},\"pub\":{}}}, \"signing\": {{\"priv\":{},\"pub\":{}}}, \"unknown\": 1e3 }}\n",v["alicePriv"],v["alicePub"],v["signPriv"],v["signPub"])).unwrap();
}
fn event() -> Value {
    json!({"id":"operation","threadId":"thread","ts":1700000000000u64,"agentId":"phone","kind":"message","data":{"role":"user","text":"cross-language follow-up"},"future":{"retained":true}})
}
#[test]
fn rust_opens_both_committed_swift_and_typescript_vectors_and_verifies_cross_language_signatures() {
    use ed25519_dalek::{Signer, SigningKey};
    for source in ["ts", "swift"] {
        let v = fixture(source);
        let keys = WireKeys::derive(fixed(&v, "alicePriv"), fixed(&v, "bobPub")).unwrap();
        assert_eq!(crypto::encode(&keys.legacy), v["sessionKey"]);
        assert_eq!(crypto::encode(&keys.send), v["channelMacToDevice"]);
        assert_eq!(crypto::encode(&keys.recv), v["channelDeviceToMac"]);
        let plain =
            crypto::open(&keys.legacy, &fixed(&v, "nonce"), &bytes(&v, "ciphertext")).unwrap();
        assert_eq!(crypto::encode(&plain), v["plaintext"]);
        assert_eq!(
            crypto::seal(&keys.legacy, &fixed(&v, "nonce"), &plain).unwrap(),
            bytes(&v, "ciphertext")
        );
        assert!(crypto::verify(
            &fixed(&v, "signPub"),
            &plain,
            &fixed(&v, "signature")
        ));
        let signature = SigningKey::from_bytes(&fixed(&v, "signPriv"))
            .sign(&plain)
            .to_bytes();
        assert!(crypto::verify(&fixed(&v, "signPub"), &plain, &signature));
        if source == "ts" {
            assert_eq!(crypto::encode(&signature), v["signature"]);
        }
        let envelope: Value = serde_json::from_slice(
            &crypto::open(
                &keys.send,
                &fixed(&v, "channelNonce"),
                &bytes(&v, "channelCiphertext"),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(envelope["seq"], v["channelSeq"]);
        assert_eq!(
            envelope["event"]["data"]["text"],
            "yorozu cross-language vector"
        );
        assert!(
            crypto::open(
                &keys.recv,
                &fixed(&v, "channelNonce"),
                &bytes(&v, "channelCiphertext")
            )
            .is_err()
        );
        assert!(
            crypto::open(
                &keys.legacy,
                &fixed(&v, "channelNonce"),
                &bytes(&v, "channelCiphertext")
            )
            .is_err()
        );
    }
}
#[test]
fn rust_worker_keeps_existing_identity_bytes_and_unknown_fields_without_returning_private_material()
{
    let temp = Temp::new();
    let v = fixture("swift");
    keys(&temp, &v);
    let old = fs::read(temp.0.join("keys.json")).unwrap();
    let mut host = HostCrypto::open(&temp.0).unwrap();
    let public = host.request(&json!({"op":"crypto_open"}));
    assert_eq!(
        public,
        json!({"sessionPub":v["alicePub"],"signingPub":v["signPub"]})
    );
    assert_eq!(fs::read(temp.0.join("keys.json")).unwrap(), old);
    assert!(HostCrypto::open(&temp.0).is_err());
    drop(host);
    assert!(HostCrypto::open(&temp.0).is_ok());
    assert_eq!(fs::read(temp.0.join("keys.json")).unwrap(), old);
}
#[test]
fn current_legacy_and_preview_boxes_round_trip_without_reflection_or_direction_downgrade() {
    let temp = Temp::new();
    let v = fixture("ts");
    keys(&temp, &v);
    let mut host = HostCrypto::open(&temp.0).unwrap();
    let wire = WireKeys::derive(fixed(&v, "alicePriv"), fixed(&v, "bobPub")).unwrap();
    let sealed = host.request(
        &json!({"op":"crypto_seal","pub":v["bobPub"],"mode":"current","seq":7,"event":event()}),
    );
    let plain: Value = serde_json::from_slice(
        &crypto::open(
            &wire.send,
            &fixed(&sealed, "nonce"),
            &bytes(&sealed, "ciphertext"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(plain, json!({"seq":7,"event":event()}));
    let reflected=host.request(&json!({"op":"crypto_open_box","pub":v["bobPub"],"mode":"current","nonce":sealed["nonce"],"ciphertext":sealed["ciphertext"]}));
    assert_eq!(reflected["status"], "unauthenticated");
    let nonce = [3; 12];
    let incoming = crypto::seal(&wire.recv, &nonce, &serde_json::to_vec(&plain).unwrap()).unwrap();
    assert_eq!(host.request(&json!({"op":"crypto_open_box","pub":v["bobPub"],"mode":"current","nonce":crypto::encode(&nonce),"ciphertext":crypto::encode(&incoming)})),json!({"status":"opened","seq":7,"event":event()}));
    let legacy = host
        .request(&json!({"op":"crypto_seal","pub":v["bobPub"],"mode":"legacy","event":event()}));
    assert_eq!(host.request(&json!({"op":"crypto_open_box","pub":v["bobPub"],"mode":"legacy","nonce":legacy["nonce"],"ciphertext":legacy["ciphertext"]}))["event"],event());
    let preview=host.request(&json!({"op":"crypto_seal","pub":v["bobPub"],"mode":"preview","plaintext":crypto::encode(b"private notification")}));
    assert_eq!(
        crypto::open(
            &wire.legacy,
            &fixed(&preview, "nonce"),
            &bytes(&preview, "ciphertext")
        )
        .unwrap(),
        b"private notification"
    );
}
#[test]
fn malformed_authenticated_envelopes_and_invalid_sequences_never_become_opened_events() {
    let temp = Temp::new();
    let v = fixture("ts");
    keys(&temp, &v);
    let mut host = HostCrypto::open(&temp.0).unwrap();
    let wire = WireKeys::derive(fixed(&v, "alicePriv"), fixed(&v, "bobPub")).unwrap();
    for envelope in [
        json!({"seq":0,"event":event()}),
        json!({"seq":1.5,"event":event()}),
        json!({"seq":9_007_199_254_740_992u64,"event":event()}),
        json!({"seq":1,"event":{"id":"missing-fields"}}),
    ] {
        let nonce = [4; 12];
        let cipher =
            crypto::seal(&wire.recv, &nonce, &serde_json::to_vec(&envelope).unwrap()).unwrap();
        assert_eq!(host.request(&json!({"op":"crypto_open_box","pub":v["bobPub"],"mode":"current","nonce":crypto::encode(&nonce),"ciphertext":crypto::encode(&cipher)}))["status"],"malformed");
    }
    assert_eq!(host.request(&json!({"op":"crypto_open_box","pub":v["bobPub"],"mode":"current","nonce":"bad","ciphertext":"bad"}))["status"],"unauthenticated");
}
#[test]
fn invalid_identity_and_missing_identity_with_saved_connections_never_regenerate_or_discard_state()
{
    for old in [
        b"{\"half-written\":".as_slice(),
        b"{\"session\":{\"priv\":\"bad\",\"pub\":\"bad\"},\"signing\":{}}",
    ] {
        let temp = Temp::new();
        fs::write(temp.0.join("keys.json"), old).unwrap();
        assert!(HostCrypto::open(&temp.0).is_err());
        assert_eq!(fs::read(temp.0.join("keys.json")).unwrap(), old);
    }
    let temp = Temp::new();
    let old = b"[{\"pub\":\"saved-connection\",\"future\":true}]";
    fs::write(temp.0.join("devices.json"), old).unwrap();
    assert!(HostCrypto::open(&temp.0).is_err());
    assert!(!temp.0.join("keys.json").exists());
    assert_eq!(fs::read(temp.0.join("devices.json")).unwrap(), old);
}
#[test]
fn low_order_exchange_tampered_tags_and_invalid_signatures_are_refused_with_fixed_errors() {
    assert!(WireKeys::derive([1; 32], [0; 32]).is_err());
    let v = fixture("ts");
    let wire = WireKeys::derive(fixed(&v, "alicePriv"), fixed(&v, "bobPub")).unwrap();
    let mut cipher = bytes(&v, "ciphertext");
    cipher[0] ^= 1;
    assert!(crypto::open(&wire.legacy, &fixed(&v, "nonce"), &cipher).is_err());
    let mut signature = fixed::<64>(&v, "signature");
    signature[0] ^= 1;
    assert!(!crypto::verify(
        &fixed(&v, "signPub"),
        &bytes(&v, "plaintext"),
        &signature
    ));
    let temp = Temp::new();
    keys(&temp, &v);
    let mut host = HostCrypto::open(&temp.0).unwrap();
    assert_eq!(
        host.request(&json!({"op":"crypto_peer","pub":crypto::encode(&[0;32])})),
        json!({"error":"crypto-request-failed"})
    );
    assert!(host.request(&json!({"op":"crypto_seal","pub":v["bobPub"],"mode":"preview","plaintext":crypto::encode(&vec![0;700*1024+1])})).get("error").is_some());
}
#[test]
fn actual_worker_termination_after_public_identity_proof_preserves_generated_room_identity() {
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
        json!({"id":"rpc","op":"crypto_open"})
    )
    .unwrap();
    let mut response = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut response)
        .unwrap();
    let public = serde_json::from_str::<Value>(&response).unwrap()["result"].clone();
    assert!(public.get("sessionPub").is_some());
    child.kill().unwrap();
    child.wait().unwrap();
    let bytes = fs::read(temp.0.join("keys.json")).unwrap();
    let mut host = HostCrypto::open(&temp.0).unwrap();
    assert_eq!(host.request(&json!({"op":"crypto_open"})), public);
    assert_eq!(fs::read(temp.0.join("keys.json")).unwrap(), bytes);
}
#[cfg(unix)]
#[test]
fn linked_identity_is_refused_and_new_identity_is_private_without_changing_root_permissions() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let temp = Temp::new();
    fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o755)).unwrap();
    let host = HostCrypto::open(&temp.0).unwrap();
    assert_eq!(
        fs::metadata(temp.0.join("keys.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777,
        0o755
    );
    drop(host);
    let file = temp.0.join("keys.json");
    let bytes = fs::read(&file).unwrap();
    fs::rename(&file, temp.0.join("original")).unwrap();
    symlink(temp.0.join("original"), &file).unwrap();
    assert!(HostCrypto::open(&temp.0).is_err());
    assert_eq!(fs::read(temp.0.join("original")).unwrap(), bytes);
}
