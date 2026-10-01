//! Bounded relay socket ownership. Sealed payloads remain opaque; no provider credentials.
use crate::transport::Emit;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io,
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    sync::Arc,
    thread,
    time::Duration,
};
use tokio::time::{Instant, sleep, sleep_until, timeout};
use tokio::{
    net::TcpStream,
    sync::{Semaphore, mpsc, watch},
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, client_async_tls_with_config,
    tungstenite::{
        Error, Message, client::IntoClientRequest, handshake::client::Response,
        protocol::WebSocketConfig,
    },
};

const FRAME_BYTES: usize = 1024 * 1024;
const COMMANDS: usize = 32;
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const FIRST_RETRY: Duration = Duration::from_secs(2);
const MAX_RETRY: Duration = Duration::from_secs(30);

struct Command {
    id: String,
    connection: String,
    frame: Option<String>,
}
struct Relay {
    commands: mpsc::Sender<Command>,
    stop: watch::Sender<bool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Drop for Relay {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
struct Events {
    id: String,
    emit: Emit,
}
impl Events {
    fn event(&self, connection: &str, event: &str, frame: Value) -> bool {
        (self.emit)(json!({"type":"transport_event","transportId":self.id,"device":connection,"event":event,"frame":frame})).is_ok()
    }
    fn answer(&self, id: &str, sent: bool) -> bool {
        let result = if sent {
            json!({"sent":true})
        } else {
            json!({"error":"relay-write-unconfirmed"})
        };
        (self.emit)(json!({"id":id,"result":result})).is_ok()
    }
}

// System DNS cannot be cancelled. Keep its one process-owner permit inside the blocking
// task, so timeout/reopen cannot enqueue unlimited resolver work. Literal IPs stay independent.
async fn dial(
    url: &str,
    resolver: Arc<Semaphore>,
    config: WebSocketConfig,
) -> Result<(WebSocketStream<MaybeTlsStream<TcpStream>>, Response), Error> {
    let request = url.into_client_request()?;
    let host = request
        .uri()
        .host()
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_owned();
    let port = request
        .uri()
        .port_u16()
        .unwrap_or(if request.uri().scheme_str() == Some("wss") {
            443
        } else {
            80
        });
    let addresses = if let Ok(ip) = host.parse::<IpAddr>() {
        vec![SocketAddr::new(ip, port)]
    } else {
        let permit = resolver.acquire_owned().await.map_err(io::Error::other)?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            (host.as_str(), port)
                .to_socket_addrs()
                .map(|addresses| addresses.collect::<Vec<_>>())
        })
        .await
        .map_err(io::Error::other)??
    };
    let stream = TcpStream::connect(addresses.as_slice()).await?;
    stream.set_nodelay(true)?;
    // Preserve hostname/SNI/verification and routing, never rewrite the URL to a resolved IP.
    client_async_tls_with_config(request, stream, Some(config), None).await
}

async fn run(
    url: String,
    ping_ms: u64,
    pong_ms: u64,
    events: Events,
    resolver: Arc<Semaphore>,
    mut commands: mpsc::Receiver<Command>,
    mut stop: watch::Receiver<bool>,
) {
    let mut retry = FIRST_RETRY;
    let mut generation = 0_u64;
    'owner: loop {
        if *stop.borrow() || !events.event("", "error", json!("connecting")) {
            break;
        }
        // DNS, TCP, TLS and handshake all obey the same cancellable connection deadline.
        let config = WebSocketConfig::default()
            .max_message_size(Some(FRAME_BYTES))
            .max_frame_size(Some(FRAME_BYTES));
        let attempt = timeout(
            CONNECT_TIMEOUT,
            dial(url.as_str(), resolver.clone(), config),
        );
        tokio::pin!(attempt);
        let connected = loop {
            tokio::select! {
                _ = stop.changed() => break 'owner,
                command = commands.recv() => {
                    let Some(command) = command else { break 'owner; };
                    if !events.answer(&command.id, false) { break 'owner; }
                },
                result = &mut attempt => break result,
            }
        };
        if let Ok(Ok((mut socket, _))) = connected {
            let Some(next) = generation.checked_add(1) else {
                break;
            };
            generation = next;
            let connection = format!("relay-{generation}");
            if !events.event(&connection, "open", Value::Null) {
                break;
            }
            let mut next_ping = Instant::now() + Duration::from_millis(ping_ms);
            let mut pong_deadline: Option<Instant> = None;
            loop {
                let wake = pong_deadline.unwrap_or(next_ping);
                tokio::select! {
                    _ = stop.changed() => break 'owner,
                    command = commands.recv() => {
                        let Some(command) = command else { break 'owner; };
                        if command.connection != connection {
                            if !events.answer(&command.id, false) { break 'owner; }
                            continue;
                        }
                        let Some(frame) = command.frame else {
                            if !events.answer(&command.id, true) { break 'owner; }
                            break;
                        };
                        // A completed write only confirms transport IO, never delivery/admission.
                        let written = tokio::select! {
                            _ = stop.changed() => { let _ = events.answer(&command.id, false); break 'owner; },
                            result = timeout(WRITE_TIMEOUT, socket.send(Message::Text(frame.into()))) => matches!(result, Ok(Ok(()))),
                        };
                        if !events.answer(&command.id, written) { break 'owner; }
                        if !written { break; }
                    },
                    incoming = socket.next() => match incoming {
                        Some(Ok(Message::Text(text))) => {
                            if let Ok(value) = serde_json::from_str::<Value>(&text) {
                                if value["type"] == "pong" { pong_deadline = None; }
                                if value["type"] == "registered" { retry = FIRST_RETRY; }
                            }
                            if !events.event(&connection, "frame", json!(text.as_str())) { break 'owner; }
                        },
                        Some(Ok(Message::Binary(bytes))) => {
                            // The historical host also reads binary JSON as UTF-8 text.
                            let Ok(text) = String::from_utf8(bytes.to_vec()) else { break; };
                            if let Ok(value) = serde_json::from_str::<Value>(&text) {
                                if value["type"] == "pong" { pong_deadline = None; }
                                if value["type"] == "registered" { retry = FIRST_RETRY; }
                            }
                            if !events.event(&connection, "frame", json!(text)) { break 'owner; }
                        },
                        Some(Ok(Message::Ping(_))) => {
                            // Tungstenite queues the protocol pong; flush it even on a quiet link.
                            let flushed = tokio::select! {
                                _ = stop.changed() => break 'owner,
                                result = timeout(WRITE_TIMEOUT, socket.flush()) => matches!(result, Ok(Ok(()))),
                            };
                            if !flushed { break; }
                        },
                        Some(Ok(Message::Pong(_))) => {},
                        _ => break,
                    },
                    _ = sleep_until(wake) => {
                        if pong_deadline.is_some() {
                            if !events.event(&connection, "error", json!("heartbeat-timeout")) { break 'owner; }
                            break;
                        }
                        let written = tokio::select! {
                            _ = stop.changed() => break 'owner,
                            result = timeout(WRITE_TIMEOUT, socket.send(Message::Text("{\"type\":\"ping\"}".into()))) => matches!(result, Ok(Ok(()))),
                        };
                        if !written { break; }
                        pong_deadline = Some(Instant::now() + Duration::from_millis(pong_ms));
                        next_ping = Instant::now() + Duration::from_millis(ping_ms);
                    },
                }
            }
            // Dropping the socket abandons half-open handshakes and all connection-bound work.
            drop(socket);
            if !events.event(&connection, "close", Value::Null) {
                break;
            }
        } else if !events.event("", "error", json!("relay-connect-unavailable")) {
            break;
        }
        // Reject old-generation work during backoff; never replay arbitrary outgoing commands.
        let wait = sleep(retry);
        tokio::pin!(wait);
        loop {
            tokio::select! {
                _ = stop.changed() => break 'owner,
                command = commands.recv() => {
                    let Some(command) = command else { break 'owner; };
                    if !events.answer(&command.id, false) { break 'owner; }
                },
                _ = &mut wait => break,
            }
        }
        retry = (retry * 2).min(MAX_RETRY);
    }
    commands.close();
    while let Some(command) = commands.recv().await {
        let _ = events.answer(&command.id, false);
    }
}

pub struct Relays {
    relays: HashMap<String, Relay>,
    emit: Emit,
    resolver: Arc<Semaphore>,
}
impl Relays {
    pub fn new(emit: Emit) -> Self {
        Self {
            relays: HashMap::new(),
            emit,
            resolver: Arc::new(Semaphore::new(1)),
        }
    }
    /// None means the network owner will answer this exact request after bounded socket IO.
    pub fn request(&mut self, request: &Value) -> Option<Value> {
        let id = request["transportId"].as_str().unwrap_or("");
        if id.is_empty() || id.len() > 128 {
            return Some(json!({"error":"invalid-relay-request"}));
        }
        match request["op"].as_str() {
            Some("relay_open") => {
                if self.relays.contains_key(id) || self.relays.len() >= 8 {
                    return Some(json!({"error":"relay-owner-unavailable"}));
                }
                let Some(url) = request["url"].as_str().filter(|url| url.len() <= 4096) else {
                    return Some(json!({"error":"invalid-relay-request"}));
                };
                let Ok(handshake) = url.into_client_request() else {
                    return Some(json!({"error":"invalid-relay-request"}));
                };
                if !matches!(handshake.uri().scheme_str(), Some("ws" | "wss"))
                    || handshake
                        .uri()
                        .authority()
                        .is_none_or(|a| a.as_str().contains('@'))
                {
                    return Some(json!({"error":"invalid-relay-request"}));
                }
                let durations = (request["pingMs"].as_u64(), request["pongMs"].as_u64());
                let (Some(ping_ms), Some(pong_ms)) = durations else {
                    return Some(json!({"error":"invalid-relay-request"}));
                };
                if !(1..=3_600_000).contains(&ping_ms) || !(1..=3_600_000).contains(&pong_ms) {
                    return Some(json!({"error":"invalid-relay-request"}));
                }
                let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                else {
                    return Some(json!({"error":"relay-owner-unavailable"}));
                };
                let (sender, receiver) = mpsc::channel(COMMANDS);
                let (stop, stopped) = watch::channel(false);
                let events = Events {
                    id: id.to_owned(),
                    emit: self.emit.clone(),
                };
                let url = url.to_owned();
                let resolver = self.resolver.clone();
                let Ok(thread) =
                    thread::Builder::new()
                        .name("yorozu-relay".into())
                        .spawn(move || {
                            runtime.block_on(run(
                                url, ping_ms, pong_ms, events, resolver, receiver, stopped,
                            ));
                            // Cancelling DNS wait does not cancel OS getaddrinfo. Never join it.
                            runtime.shutdown_background();
                        })
                else {
                    return Some(json!({"error":"relay-owner-unavailable"}));
                };
                self.relays.insert(
                    id.to_owned(),
                    Relay {
                        commands: sender,
                        stop,
                        thread: Some(thread),
                    },
                );
                Some(json!({"ready":true}))
            }
            Some("relay_send" | "relay_disconnect") => {
                let Some(relay) = self.relays.get(id) else {
                    return Some(json!({"error":"relay-write-unconfirmed"}));
                };
                let Some(connection) = request["device"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() <= 128)
                else {
                    return Some(json!({"error":"invalid-relay-request"}));
                };
                let frame = if request["op"] == "relay_send" {
                    let Some(frame) = request["frame"]
                        .as_str()
                        .filter(|frame| frame.len() <= FRAME_BYTES)
                    else {
                        return Some(json!({"error":"relay-output-limit"}));
                    };
                    Some(frame.to_owned())
                } else {
                    None
                };
                let command = Command {
                    id: request["id"].as_str().unwrap_or("").to_owned(),
                    connection: connection.to_owned(),
                    frame,
                };
                if relay.commands.try_send(command).is_err() {
                    return Some(json!({"error":"relay-output-limit"}));
                }
                None
            }
            Some("relay_close") => {
                self.relays.remove(id);
                Some(json!({"closed":true}))
            }
            _ => Some(json!({"error":"invalid-relay-request"})),
        }
    }
}
