#![cfg(any(windows, feature = "insecure-plaintext-store"))]
use yorozu_core::{
    frame::b64,
    link::Link,
    store::{FileStore, Loaded, Pairing},
};
fn record() -> Pairing {
    Pairing::new(
        &Link::parse(&format!(
            "yorozu://pair?relay=wss://relay.test&room={}&key={}&token=AQ&secret=Ag",
            b64([1; 32]),
            b64([2; 32])
        ))
        .unwrap(),
        [3; 32],
        [4; 32],
    )
}
fn dir() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("yorozu-store-{}", uuid::Uuid::new_v4()))
}
#[cfg(feature = "insecure-plaintext-store")]
#[test]
fn plain_roundtrip_invalid_and_wipe() {
    use yorozu_core::store::PlainProtector;
    let dir = dir();
    let store = FileStore::new(&dir, Box::new(PlainProtector));
    assert_eq!(store.load(), Loaded::Missing);
    let record = record();
    store.save(&record).unwrap();
    assert_eq!(store.load(), Loaded::Pairing(record.clone()));
    assert!(!dir.join("pairing.bin.tmp").exists());
    let mut bad = record;
    bad.v = 2;
    std::fs::write(dir.join("pairing.bin"), serde_json::to_vec(&bad).unwrap()).unwrap();
    assert_eq!(store.load(), Loaded::Unreadable);
    std::fs::write(dir.join("pairing.bin.tmp"), b"partial").unwrap();
    store.wipe().unwrap();
    assert_eq!(store.load(), Loaded::Missing);
    assert!(!dir.join("pairing.bin.tmp").exists());
    std::fs::remove_dir(dir).unwrap();
}
#[cfg(windows)]
#[test]
fn dpapi_roundtrip_and_tampered_file_launches_removed() {
    use yorozu_core::{
        pairing::{self, Event, Removed, State},
        store::DpapiProtector,
    };
    let dir = dir();
    let store = FileStore::new(&dir, Box::new(DpapiProtector));
    store.save(&record()).unwrap();
    assert_eq!(store.load(), Loaded::Pairing(record()));
    let path = dir.join("pairing.bin");
    let mut blob = std::fs::read(&path).unwrap();
    let n = blob.len() / 2;
    blob[n] ^= 1;
    std::fs::write(path, blob).unwrap();
    assert_eq!(
        pairing::step(State::Unpaired, Event::Launch(store.load())).0,
        State::Removed(Removed::Unreadable)
    );
    store.wipe().unwrap();
    std::fs::remove_dir(dir).unwrap();
}

#[cfg(feature = "insecure-plaintext-store")]
mod driver {
    use super::*;
    use std::{future::Future, pin::Pin, sync::Arc, time::Duration};
    use yorozu_core::{
        driver::{Command, Driver, Notification, Options},
        platform::Platform,
        store::{PlainProtector, Protector},
    };
    struct FakePlatform(std::path::PathBuf);
    impl Platform for FakePlatform {
        fn now_ms(&self) -> u64 {
            1_700_000_000_000
        }
        fn random_bytes(&self, bytes: &mut [u8]) {
            bytes.fill(7);
        }
        fn computer_name(&self) -> String {
            "test PC".into()
        }
        fn data_dir(&self) -> std::path::PathBuf {
            self.0.clone()
        }
        fn sleep(&self, _: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> {
            Box::pin(std::future::pending())
        }
    }
    struct CannotProtect;
    impl Protector for CannotProtect {
        fn protect(&self, _: &[u8]) -> std::io::Result<Vec<u8>> {
            Err(std::io::Error::other("test protection failure"))
        }
        fn unprotect(&self, _: &[u8]) -> std::io::Result<Vec<u8>> {
            Err(std::io::Error::other("test protection failure"))
        }
    }
    #[tokio::test]
    async fn persisted_keys_use_platform_and_snapshot_never_exposes_them() {
        let dir = dir();
        let protector = Box::new(PlainProtector);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let (handle, driver) = Driver::new(
            Arc::new(FakePlatform(dir.clone())),
            protector,
            Options::default(),
            "test",
            move |n| {
                let _ = tx.send(n);
            },
        );
        let task = tokio::spawn(driver.run());
        let r = record();
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("relay", &r.relay)
            .append_pair("room", &r.room)
            .append_pair("key", &r.host_key)
            .append_pair("token", r.token.as_deref().unwrap())
            .append_pair("secret", r.secret.as_deref().unwrap())
            .finish();
        handle
            .command(Command::SubmitLink(format!("yorozu://pair?{query}")))
            .unwrap();
        handle.command(Command::Confirm).unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while let Some(n) = rx.recv().await {
                if matches!(n, Notification::File { .. }) {
                    break;
                }
            }
        })
        .await
        .unwrap();
        handle.command(Command::Quit).unwrap();
        task.await.unwrap();
        let loaded = FileStore::new(&dir, Box::new(PlainProtector)).load();
        let Loaded::Pairing(pairing) = loaded else {
            panic!("pairing not saved");
        };
        assert_eq!(pairing.ed_priv, b64([7; 32]));
        assert_eq!(pairing.x_priv, b64([7; 32]));
        assert!(pairing.secret.is_some());
        let snapshot = serde_json::to_string(&handle.snapshot()).unwrap();
        for secret in [&pairing.ed_priv, &pairing.x_priv, &pairing.host_key] {
            assert!(!snapshot.contains(secret));
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[tokio::test]
    async fn initial_protection_failure_returns_unpaired_with_s13_without_starting_connection() {
        let dir = dir();
        let protector = Box::new(CannotProtect);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let (handle, driver) = Driver::new(
            Arc::new(FakePlatform(dir.clone())),
            protector,
            Options::default(),
            "test",
            move |n| {
                let _ = tx.send(n);
            },
        );
        let task = tokio::spawn(driver.run());
        handle
            .command(Command::SubmitLink(format!(
                "yorozu://pair?relay=wss://relay.test&room={}&key={}&token=AQ&secret=Ag",
                b64([1; 32]),
                b64([2; 32])
            )))
            .unwrap();
        handle.command(Command::Confirm).unwrap();
        let mut saw_notice = false;
        tokio::time::timeout(Duration::from_secs(2), async {
            while let Some(n) = rx.recv().await {
                match n {
                    Notification::Connection(_) => panic!("must not start without a saved pairing"),
                    Notification::Notice { text, .. } => {
                        assert_eq!(text, yorozu_core::pairing::S13);
                        saw_notice = true;
                    }
                    Notification::Changed(_) if saw_notice => break,
                    _ => {}
                }
            }
        })
        .await
        .unwrap();
        handle.command(Command::Quit).unwrap();
        task.await.unwrap();
        assert_eq!(
            serde_json::to_value(handle.snapshot()).unwrap()["pairing"]["state"],
            "unpaired"
        );
        assert!(!dir.exists());
    }
}
