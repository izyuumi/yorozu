#[cfg(unix)]
mod unix {
    use serde_json::{Value, json};
    use std::fs;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, mpsc};
    use std::time::Duration;
    use yorozu_host_core::{
        now_ms,
        transport::{FRAME_BYTES, PEERS, Transports},
    };

    static ID: AtomicU64 = AtomicU64::new(0);
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "yorozu-port-{}-{}-{}",
                std::process::id(),
                now_ms(),
                ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
            Self(root)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn host(temp: &Temp) -> (Transports, mpsc::Receiver<Value>) {
        let (send, receive) = mpsc::channel();
        (
            Transports::new(
                &temp.0,
                Arc::new(move |frame| send.send(frame).map_err(std::io::Error::other)),
            ),
            receive,
        )
    }
    fn open(host: &mut Transports, id: &str) -> Value {
        host.request(&json!({"op":"transport_open","transportId":id,"name":"local.sock"}))
    }
    fn event(events: &mpsc::Receiver<Value>, kind: &str) -> Value {
        loop {
            let value = events.recv_timeout(Duration::from_secs(3)).unwrap();
            if value["event"] == kind {
                return value;
            }
        }
    }

    #[test]
    fn private_socket_round_trip_keeps_json_order_unicode_and_unknown_fields() {
        let temp = Temp::new();
        let (mut host, events) = host(&temp);
        assert_eq!(open(&mut host, "port"), json!({"ready":true}));
        assert_eq!(
            fs::metadata(temp.0.join("local.sock"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let mut client = UnixStream::connect(temp.0.join("local.sock")).unwrap();
        let opened = event(&events, "open");
        client
            .write_all(b"{\"id\":\"one\",\"kind\":\"message\",\"text\":\"hello\\n")
            .unwrap();
        client
            .write_all("日本語🙂\",\"future\":{\"kept\":true}}\n".as_bytes())
            .unwrap();
        let incoming = event(&events, "frame");
        assert_eq!(incoming["frame"]["text"], "hello\n日本語🙂");
        assert_eq!(incoming["frame"]["future"]["kept"], true);
        assert_eq!(host.request(&json!({"op":"transport_send","transportId":"port","device":opened["device"],"frame":incoming["frame"]})),json!({"sent":true}));
        let mut reply = String::new();
        BufReader::new(client).read_line(&mut reply).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&reply).unwrap(),
            incoming["frame"]
        );
        host.request(&json!({"op":"transport_close","transportId":"port"}));
        assert!(!temp.0.join("local.sock").exists());
    }

    #[test]
    fn malformed_frames_are_reported_without_echoing_data_or_losing_next_valid_frame() {
        let temp = Temp::new();
        let (mut host, events) = host(&temp);
        open(&mut host, "port");
        let mut client = UnixStream::connect(temp.0.join("local.sock")).unwrap();
        event(&events, "open");
        client
            .write_all(b"{secret-invalid\n\n{\"valid\":true}\n")
            .unwrap();
        let failure = event(&events, "error");
        assert_eq!(failure["frame"], "invalid-local-frame");
        assert!(!failure.to_string().contains("secret"));
        assert_eq!(event(&events, "frame")["frame"], json!({"valid":true}));
    }

    #[test]
    fn second_writer_and_existing_live_legacy_listener_are_never_replaced() {
        let temp = Temp::new();
        let (mut first, _) = host(&temp);
        let (mut second, _) = host(&temp);
        open(&mut first, "first");
        assert!(open(&mut second, "second").get("error").is_some());
        first.request(&json!({"op":"transport_close","transportId":"first"}));
        assert_eq!(open(&mut second, "second"), json!({"ready":true}));
        drop(second);
        let legacy = UnixListener::bind(temp.0.join("local.sock")).unwrap();
        let original = fs::symlink_metadata(temp.0.join("local.sock")).unwrap();
        let (mut next, _) = host(&temp);
        assert!(open(&mut next, "next").get("error").is_some());
        use std::os::unix::fs::MetadataExt;
        assert_eq!(
            fs::symlink_metadata(temp.0.join("local.sock"))
                .unwrap()
                .ino(),
            original.ino()
        );
        drop(legacy);
    }

    #[test]
    fn stale_socket_recovers_but_regular_files_links_and_nonprivate_roots_are_retained() {
        let temp = Temp::new();
        drop(UnixListener::bind(temp.0.join("local.sock")).unwrap());
        let (mut host, _) = host(&temp);
        assert_eq!(open(&mut host, "stale"), json!({"ready":true}));
        drop(host);
        fs::write(temp.0.join("local.sock"), b"original draft").unwrap();
        let (mut host, _) = self::host(&temp);
        assert!(open(&mut host, "file").get("error").is_some());
        assert_eq!(
            fs::read(temp.0.join("local.sock")).unwrap(),
            b"original draft"
        );
        fs::remove_file(temp.0.join("local.sock")).unwrap();
        std::os::unix::fs::symlink(temp.0.join("original"), temp.0.join("local.sock")).unwrap();
        assert!(open(&mut host, "link").get("error").is_some());
        assert!(
            fs::symlink_metadata(temp.0.join("local.sock"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(
            host.request(
                &json!({"op":"transport_open","transportId":"public","name":"another.sock"})
            )
            .get("error")
            .is_some()
        );
        assert_eq!(
            fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }

    #[test]
    fn close_does_not_delete_a_replaced_path_and_does_not_wait_for_idle_peers() {
        let temp = Temp::new();
        let (mut host, events) = host(&temp);
        open(&mut host, "port");
        let _client = UnixStream::connect(temp.0.join("local.sock")).unwrap();
        event(&events, "open");
        fs::rename(temp.0.join("local.sock"), temp.0.join("old.sock")).unwrap();
        fs::write(temp.0.join("local.sock"), b"keep me").unwrap();
        host.request(&json!({"op":"transport_close","transportId":"port"}));
        assert_eq!(fs::read(temp.0.join("local.sock")).unwrap(), b"keep me");
    }

    #[test]
    fn peer_and_partial_frame_limits_close_excess_without_unbounded_allocation() {
        let temp = Temp::new();
        let (mut host, events) = host(&temp);
        open(&mut host, "port");
        let mut peers = Vec::new();
        for _ in 0..PEERS {
            peers.push(UnixStream::connect(temp.0.join("local.sock")).unwrap());
            event(&events, "open");
        }
        let excess = UnixStream::connect(temp.0.join("local.sock")).unwrap();
        excess
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut line = String::new();
        assert_eq!(BufReader::new(excess).read_line(&mut line).unwrap(), 0);
        let _ = peers[0].write_all(&vec![b'x'; FRAME_BYTES + 1]);
        assert_eq!(event(&events, "error")["frame"], "transport-input-limit");
        event(&events, "close");
    }
}

#[cfg(not(unix))]
#[test]
fn unsupported_local_transport_is_explicit_and_never_claims_ready() {
    use serde_json::json;
    use std::sync::Arc;
    use yorozu_host_core::transport::Transports;
    let mut host = Transports::new(std::path::Path::new("."), Arc::new(|_| Ok(())));
    assert_eq!(
        host.request(&json!({"op":"transport_open","transportId":"port","name":"local.sock"})),
        json!({"error":"local-transport-unavailable"})
    );
}
