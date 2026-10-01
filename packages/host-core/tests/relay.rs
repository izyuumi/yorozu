use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::{Arc, mpsc},
    thread,
    time::{Duration, Instant},
};
use tokio_tungstenite::tungstenite::{Message, accept_hdr};
use yorozu_host_core::relay::Relays;

fn until(receiver: &mpsc::Receiver<Value>, predicate: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(6);
    loop {
        let event = receiver
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .unwrap();
        if predicate(&event) {
            return event;
        }
    }
}
fn owner() -> (Relays, mpsc::Receiver<Value>) {
    let (sender, receiver) = mpsc::channel();
    (
        Relays::new(Arc::new(move |value| {
            sender.send(value).map_err(std::io::Error::other)
        })),
        receiver,
    )
}

#[test]
fn socket_contract_preserves_opaque_frames_and_fences_old_connections() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        for expected in ["sealed-original", "sealed-fresh"] {
            let (stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut socket = accept_hdr(
                stream,
                |request: &tokio_tungstenite::tungstenite::handshake::server::Request, response| {
                    assert_eq!(request.uri().to_string(), "/socket?room=existing-room");
                    Ok(response)
                },
            )
            .unwrap();
            socket
                .send(Message::Text("{\"type\":\"registered\"}".into()))
                .unwrap();
            // Malformed application JSON remains the application's decision, not a lost socket.
            socket.send(Message::Text("not json".into())).unwrap();
            let message = socket.read().unwrap();
            assert_eq!(message, Message::Text(expected.into()));
            socket
                .send(Message::Binary(expected.as_bytes().to_vec().into()))
                .unwrap();
            if expected == "sealed-original" {
                socket.close(None).unwrap();
            } else {
                // The host must answer a WebSocket protocol ping independently of application IO.
                socket.send(Message::Ping(vec![1, 2, 3].into())).unwrap();
                assert_eq!(socket.read().unwrap(), Message::Pong(vec![1, 2, 3].into()));
            }
        }
    });
    let (mut relays, events) = owner();
    let open = json!({"id":"open","op":"relay_open","transportId":"owner","url":format!("ws://localhost:{}/socket?room=existing-room", address.port()),"pingMs":10000,"pongMs":1000});
    assert_eq!(relays.request(&open).unwrap()["ready"], true);
    assert!(relays.request(&open).unwrap().get("error").is_some());
    let first = until(&events, |v| v["event"] == "open")["device"].clone();
    until(&events, |v| v["frame"] == "not json");
    assert!(relays.request(&json!({"id":"original","op":"relay_send","transportId":"owner","device":first,"frame":"sealed-original"})).is_none());
    assert_eq!(
        until(&events, |v| v["id"] == "original")["result"]["sent"],
        true
    );
    until(&events, |v| v["event"] == "close");
    let second = until(&events, |v| v["event"] == "open")["device"].clone();
    assert_ne!(first, second);
    until(&events, |v| v["frame"] == "not json");
    assert!(relays.request(&json!({"id":"stale","op":"relay_send","transportId":"owner","device":first,"frame":"must-not-replay"})).is_none());
    assert!(
        until(&events, |v| v["id"] == "stale")["result"]
            .get("error")
            .is_some()
    );
    assert!(relays.request(&json!({"id":"oversize","op":"relay_send","transportId":"owner","device":second,"frame":"x".repeat(1024*1024+1)})).unwrap().get("error").is_some());
    assert!(relays.request(&json!({"id":"fresh","op":"relay_send","transportId":"owner","device":second,"frame":"sealed-fresh"})).is_none());
    assert_eq!(
        until(&events, |v| v["id"] == "fresh")["result"]["sent"],
        true
    );
    assert_eq!(
        until(&events, |v| v["frame"] == "sealed-fresh")["device"],
        second
    );
    server.join().unwrap();
    assert_eq!(
        relays
            .request(&json!({"op":"relay_close","transportId":"owner"}))
            .unwrap()["closed"],
        true
    );
}

#[test]
fn shutdown_cancels_an_unfinished_handshake_and_wss_never_downgrades() {
    for scheme in ["ws", "wss"] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (accepted, accepted_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut prefix = [0_u8; 3];
            stream.read_exact(&mut prefix).unwrap();
            if scheme == "wss" {
                assert_ne!(&prefix, b"GET");
            } else {
                assert_eq!(&prefix, b"GET");
            }
            accepted.send(()).unwrap();
            // No handshake response: owner shutdown must interrupt the ten-second attempt.
            let mut input = [0_u8; 1024];
            while matches!(stream.read(&mut input), Ok(n) if n > 0) {}
            let _ = stream.flush();
        });
        let (mut relays, events) = owner();
        for url in ["http://127.0.0.1/", "ws://user:secret@127.0.0.1/"] {
            assert!(relays.request(&json!({"op":"relay_open","transportId":"invalid","url":url,"pingMs":1,"pongMs":1})).unwrap().get("error").is_some());
        }
        assert_eq!(relays.request(&json!({"op":"relay_open","transportId":"owner","url":format!("{scheme}://{address}"),"pingMs":10000,"pongMs":1000})).unwrap()["ready"], true);
        accepted_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        let started = Instant::now();
        assert_eq!(
            relays
                .request(&json!({"op":"relay_close","transportId":"owner"}))
                .unwrap()["closed"],
            true
        );
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(!events.try_iter().any(|v| v["event"] == "open"));
        server.join().unwrap();
    }
}

#[test]
fn a_self_signed_relay_cannot_become_an_open_connection() {
    // Synthetic, public test-only credentials. Never trusted by the production client.
    let cert = rustls::pki_types::CertificateDer::from(
        include_bytes!("fixtures/relay-untrusted-cert.der").to_vec(),
    );
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(
        include_bytes!("fixtures/relay-untrusted-key.der").to_vec(),
    );
    let config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key.into())
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (refused, refusal) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut tls = rustls::ServerConnection::new(Arc::new(config)).unwrap();
        let error = loop {
            match tls.complete_io(&mut stream) {
                Err(error) => break error,
                Ok(_) => assert!(tls.is_handshaking(), "untrusted relay completed TLS"),
            }
        };
        assert!(matches!(
            error
                .get_ref()
                .and_then(|e| e.downcast_ref::<rustls::Error>()),
            Some(rustls::Error::AlertReceived(
                rustls::AlertDescription::UnknownCA
            ))
        ));
        refused.send(()).unwrap();
    });
    let (mut relays, events) = owner();
    assert_eq!(relays.request(&json!({"op":"relay_open","transportId":"owner","url":format!("wss://{address}"),"pingMs":10000,"pongMs":1000})).unwrap()["ready"], true);
    refusal.recv_timeout(Duration::from_secs(3)).unwrap();
    let failure = until(&events, |v| {
        v["frame"] == "relay-connect-unavailable" || v["event"] == "open"
    });
    assert_eq!(failure["event"], "error");
    relays.request(&json!({"op":"relay_close","transportId":"owner"}));
    server.join().unwrap();
}
