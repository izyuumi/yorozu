//! Executes machine effects. All socket, timer and cryptographic state stays here.
use crate::{
    connection::{self, Effect, Event, EventKind, Machine, Payload, State, Timer},
    events::{Envelope, PeerInfo},
    frame::{b64, Frame},
    pairing::{self, Effect as PairEffect, Event as PairEvent},
    platform::Platform,
    store::{FileStore, Loaded, Pairing, Protector, Standing},
    wire::{self, ClientHandshake, Session},
    Notice, PairingView, Snapshot,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, RwLock},
    time::Duration,
};
use tokio::{sync::mpsc, task::JoinHandle};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{protocol::WebSocketConfig, Message},
};

#[derive(Clone, Debug)]
pub enum Command {
    SubmitLink(String),
    Confirm,
    Cancel,
    Forget,
    PairAgain,
    Retry,
    Drop,
    Quit,
}
#[derive(Clone, Debug)]
pub enum Notification {
    Changed(&'static str),
    Notice {
        state: &'static str,
        text: String,
    },
    Pairing(&'static str),
    Connection(&'static str),
    Close(u16, String),
    File {
        standing: Standing,
        has_token: bool,
        has_secret: bool,
    },
}
#[derive(Clone)]
pub struct Handle {
    tx: mpsc::UnboundedSender<Input>,
    snapshot: Arc<RwLock<Snapshot>>,
}
impl Handle {
    pub fn command(&self, cmd: Command) -> Result<(), String> {
        self.tx
            .send(Input::Command(cmd))
            .map_err(|_| "connection driver stopped".into())
    }
    pub fn snapshot(&self) -> Snapshot {
        self.snapshot
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
}
#[derive(Clone, Copy, Default)]
pub struct Options {
    pub fast: bool,
}
enum Input {
    Command(Command),
    Socket(u64, SocketEvent),
    Timer(Timer, u64),
}
enum SocketEvent {
    Open,
    Json(Value),
    Close(u16, String),
    Error,
}
pub struct Driver {
    platform: Arc<dyn Platform>,
    store: FileStore,
    options: Options,
    notify: Arc<dyn Fn(Notification) + Send + Sync>,
    handle: Handle,
    rx: mpsc::UnboundedReceiver<Input>,
    pairing: pairing::State,
    conn: Machine,
    record: Option<Pairing>,
    socket: Option<JoinHandle<()>>,
    outgoing: Option<mpsc::UnboundedSender<Value>>,
    timers: HashMap<Timer, JoinHandle<()>>,
    handshake: Option<ClientHandshake>,
    session: Option<Session>,
}
impl Driver {
    pub fn new(
        platform: Arc<dyn Platform>,
        protector: Box<dyn Protector>,
        options: Options,
        build: &str,
        notify: impl Fn(Notification) + Send + Sync + 'static,
    ) -> (Handle, Self) {
        let (tx, rx) = mpsc::unbounded_channel();
        let handle = Handle {
            tx,
            snapshot: Arc::new(RwLock::new(Snapshot::initial(crate::VERSION, build))),
        };
        let store = FileStore::new(platform.data_dir(), protector);
        let driver = Self {
            platform,
            store,
            options,
            notify: Arc::new(notify),
            handle: handle.clone(),
            rx,
            pairing: pairing::State::Unpaired,
            conn: Machine::new(Standing::CodeOnly),
            record: None,
            socket: None,
            outgoing: None,
            timers: HashMap::new(),
            handshake: None,
            session: None,
        };
        (handle, driver)
    }
    pub async fn run(mut self) {
        (self.notify)(Notification::Pairing("Unpaired"));
        let loaded = self.store.load();
        if let Loaded::Pairing(record) = &loaded {
            self.record = Some(record.clone());
            self.conn = Machine::new(record.standing);
        }
        self.pair_event(PairEvent::Launch(loaded));
        self.publish();
        while let Some(input) = self.rx.recv().await {
            match input {
                Input::Command(Command::Quit) => break,
                Input::Command(cmd) => match cmd {
                    Command::SubmitLink(link) => self.pair_event(PairEvent::LinkSubmitted(link)),
                    Command::Confirm => self.pair_event(PairEvent::Confirm),
                    Command::Cancel => self.pair_event(PairEvent::Cancel),
                    Command::Forget => self.pair_event(PairEvent::Forget),
                    Command::PairAgain => self.pair_event(PairEvent::PairAgain),
                    Command::Retry => {
                        if self.pairing == pairing::State::Paired
                            && self.conn.state
                                == State::Idle(Some(connection::Terminal::UpdateRequired))
                        {
                            self.conn_event(EventKind::Start, None);
                        }
                    }
                    Command::Drop => self.conn_event(EventKind::Error, None),
                    Command::Quit => unreachable!(),
                },
                Input::Timer(timer, generation) => {
                    self.conn_event(EventKind::Timer(timer), Some(generation))
                }
                Input::Socket(generation, event) => {
                    if generation != self.conn.socket_generation {
                        continue;
                    }
                    match event {
                        SocketEvent::Open => {
                            self.conn_event(EventKind::SocketOpen, Some(generation))
                        }
                        SocketEvent::Error => self.conn_event(EventKind::Error, Some(generation)),
                        SocketEvent::Close(code, reason) => {
                            (self.notify)(Notification::Close(code, reason.clone()));
                            self.conn_event(EventKind::Close { code, reason }, Some(generation));
                        }
                        SocketEvent::Json(value) => self.relay(value, generation),
                    }
                }
            }
            self.publish();
        }
        self.close();
        for (_, task) in self.timers.drain() {
            task.abort();
        }
    }
    fn pair_event(&mut self, event: PairEvent) {
        let before = self.pairing.clone();
        let (state, effects) = pairing::step(self.pairing.clone(), event);
        self.pairing = state;
        if self.pairing != before {
            (self.notify)(Notification::Pairing(self.pairing.name()));
        }
        for effect in effects {
            match effect {
                PairEffect::Create(link) => {
                    let mut ed = [0; 32];
                    let mut x = [0; 32];
                    self.platform.random_bytes(&mut ed);
                    self.platform.random_bytes(&mut x);
                    let record = Pairing::new(&link, ed, x);
                    if self.store.save(&record).is_err() {
                        self.pair_event(PairEvent::SaveFailed { initial: true });
                        continue;
                    }
                    self.record = Some(record);
                    self.conn = Machine::new(Standing::CodeOnly);
                    self.file_notice();
                    self.conn_event(EventKind::Start, None);
                }
                PairEffect::Start => self.conn_event(EventKind::Start, None),
                PairEffect::Stop => self.conn_event(EventKind::Stop, None),
                PairEffect::Wipe => {
                    if self.store.wipe().is_err() {
                        self.notice(pairing::S13);
                    }
                    self.record = None;
                }
                PairEffect::Notice(text) => self.notice(text),
                PairEffect::PersistKnown => {
                    if let Some(record) = &mut self.record {
                        record.standing = Standing::Known;
                        record.token = None;
                    }
                    self.persist();
                }
                PairEffect::PersistPaired(now) => {
                    if let Some(record) = &mut self.record {
                        record.secret = None;
                        record.paired_at = Some(now);
                    }
                    self.persist();
                }
            }
        }
    }
    fn notice(&mut self, text: &str) {
        let mut snapshot = self
            .handle
            .snapshot
            .write()
            .unwrap_or_else(|e| e.into_inner());
        let seq = snapshot.notice.as_ref().map_or(1, |n| n.seq + 1);
        snapshot.notice = Some(Notice {
            seq,
            text: text.into(),
        });
        drop(snapshot);
        (self.notify)(Notification::Notice {
            state: self.pairing.name(),
            text: text.into(),
        });
    }
    fn file_notice(&self) {
        if let Some(record) = &self.record {
            (self.notify)(Notification::File {
                standing: record.standing,
                has_token: record.token.is_some(),
                has_secret: record.secret.is_some(),
            });
        }
    }
    fn persist(&mut self) {
        if let Some(record) = &self.record {
            if self.store.save(record).is_err() {
                self.notice(pairing::S13);
            } else {
                self.file_notice();
            }
        }
    }
    fn conn_event(&mut self, kind: EventKind, generation: Option<u64>) {
        let before = self.conn.state.clone();
        let (machine, effects) = connection::step(
            self.conn.clone(),
            Event {
                kind,
                generation,
                now_ms: self.platform.now_ms(),
            },
        );
        self.conn = machine;
        if self.conn.state != before {
            (self.notify)(Notification::Connection(self.conn.state.name()));
        }
        if matches!(
            self.conn.state,
            State::Joined | State::Idle(_) | State::Backoff
        ) {
            self.session = None;
            self.handshake = None;
        }
        for effect in effects {
            self.execute(effect);
        }
    }
    fn execute(&mut self, effect: Effect) {
        match effect {
            Effect::Dial => self.dial(),
            Effect::Close => self.close(),
            Effect::Arm(timer, generation, ms) => {
                if let Some(task) = self.timers.remove(&timer) {
                    task.abort();
                }
                let ms = if self.options.fast {
                    match timer {
                        Timer::Backoff => {
                            (50u64 << self.conn.attempt.saturating_sub(1).min(4)).min(500)
                        }
                        Timer::Connect => 2000,
                        _ => 1000,
                    }
                } else {
                    ms
                };
                let tx = self.handle.tx.clone();
                let platform = self.platform.clone();
                self.timers.insert(
                    timer,
                    tokio::spawn(async move {
                        platform.sleep(Duration::from_millis(ms)).await;
                        let _ = tx.send(Input::Timer(timer, generation));
                    }),
                );
            }
            Effect::Cancel(timer) => {
                if let Some(task) = self.timers.remove(&timer) {
                    task.abort();
                }
            }
            Effect::Join { nonce, token } => {
                if let Some(record) = &self.record {
                    if let Some((ed, _, _)) = record.keys() {
                        let mut value = json!({"type":"join","roomId":record.room,"phonePubkey":b64(wire::signing_public(&ed)),"sig":wire::sign(&ed,if token { record.token.as_deref().unwrap_or("") } else { &nonce })});
                        if token {
                            value["token"] = json!(record.token);
                        }
                        self.send(value);
                    }
                }
            }
            Effect::PersistKnown => self.pair_event(PairEvent::Joined),
            Effect::Init => {
                self.session = None;
                self.handshake = None;
                if let Some(record) = &self.record {
                    if let Some((ed, x, host)) = record.keys() {
                        match ClientHandshake::new(
                            &x,
                            &ed,
                            &host,
                            &record.room,
                            self.platform.now_ms(),
                            record.secret.as_deref(),
                            self.platform.clone(),
                        ) {
                            Ok(handshake) => {
                                self.send_frame(&handshake.frame);
                                self.handshake = Some(handshake);
                            }
                            Err(_) => self.conn_event(EventKind::Error, None),
                        }
                    }
                }
            }
            Effect::PeerInfo => {
                let bytes = serde_json::to_vec(&Envelope::PeerInfo(PeerInfo::client(
                    &self.platform.computer_name(),
                )))
                .unwrap();
                if let Some(frame) = self.session.as_mut().and_then(|s| s.seal(&bytes)) {
                    self.send_frame(&frame);
                }
            }
            Effect::SendFlowAck(ack) => self.send(serde_json::to_value(ack).unwrap()),
            Effect::Ping => self.send(json!({"type":"ping"})),
            Effect::SessionOpened => {
                self.pair_event(PairEvent::SessionOpened(self.platform.now_ms()))
            }
            Effect::Terminal(terminal) => self.pair_event(PairEvent::Terminal(terminal)),
            Effect::SessionLost => {
                self.handshake = None;
                self.session = None;
            }
            Effect::Accepted(_) | Effect::Chat(_) => {}
        }
    }
    fn relay(&mut self, value: Value, generation: u64) {
        let kind = match value["type"].as_str() {
            Some("nonce") => value["nonce"].as_str().map(|s| EventKind::Nonce(s.into())),
            Some("joined") => Some(EventKind::Joined {
                owner_online: value["ownerOnline"] == true,
                flow_control: value["flowControl"] == true,
            }),
            Some("owner") => value["online"].as_bool().map(EventKind::Owner),
            Some("pong") => Some(EventKind::Pong),
            Some("accepted") => value["sig"].as_str().map(|s| EventKind::Accepted(s.into())),
            Some("frame") => {
                // Ack at the relay layer before decoding or touching handshake/session state.
                self.conn_event(
                    EventKind::RelayFrame {
                        flow_bytes: value["flowBytes"].as_u64(),
                        payload: Payload::Ignored,
                    },
                    Some(generation),
                );
                let frame = value["payload"].as_str().and_then(Frame::decode);
                let payload = match (&self.conn.state, frame.as_ref()) {
                    (State::Handshaking { keys: false }, Some(frame @ Frame::Response { .. })) => {
                        match self.handshake.as_mut().and_then(|h| h.finish(frame)) {
                            Some(session) => {
                                self.session = Some(session);
                                Payload::Response
                            }
                            None => Payload::Ignored,
                        }
                    }
                    (
                        State::Handshaking { keys: true } | State::Open,
                        Some(frame @ Frame::Box { .. }),
                    ) => self
                        .session
                        .as_mut()
                        .and_then(|s| s.open(frame))
                        .and_then(|bytes| Envelope::decode(&bytes))
                        .map(Payload::Box)
                        .unwrap_or(Payload::Ignored),
                    _ => Payload::Ignored,
                };
                if payload == Payload::Ignored {
                    None
                } else {
                    Some(EventKind::RelayFrame {
                        flow_bytes: None,
                        payload,
                    })
                }
            }
            _ => None,
        };
        if let Some(kind) = kind {
            self.conn_event(kind, Some(generation));
        }
    }
    fn send_frame(&self, frame: &Frame) {
        if let Some((ed, _, _)) = self.record.as_ref().and_then(Pairing::keys) {
            let payload = frame.encode();
            self.send(json!({"type":"frame","sig":wire::sign(&ed,&payload),"payload":payload}));
        }
    }
    fn send(&self, value: Value) {
        if value.to_string().len() <= 1_048_576 {
            if let Some(tx) = &self.outgoing {
                let _ = tx.send(value);
            }
        }
    }
    fn close(&mut self) {
        self.outgoing = None;
        if let Some(task) = self.socket.take() {
            task.abort();
        }
        self.handshake = None;
        self.session = None;
    }
    fn dial(&mut self) {
        self.close();
        let Some(record) = &self.record else {
            return;
        };
        let Ok(mut url) = url::Url::parse(&record.relay) else {
            return;
        };
        url.query_pairs_mut()
            .clear()
            .append_pair("room", &record.room);
        let generation = self.conn.socket_generation;
        let tx = self.handle.tx.clone();
        let (outgoing, mut rx) = mpsc::unbounded_channel::<Value>();
        self.outgoing = Some(outgoing);
        static TLS_PROVIDER: std::sync::Once = std::sync::Once::new();
        TLS_PROVIDER.call_once(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
        });
        self.socket = Some(tokio::spawn(async move {
            let config = WebSocketConfig::default()
                .max_message_size(Some(2 * 1024 * 1024))
                .max_frame_size(Some(2 * 1024 * 1024));
            let Ok((socket, _)) =
                connect_async_with_config(url.as_str(), Some(config), false).await
            else {
                let _ = tx.send(Input::Socket(generation, SocketEvent::Error));
                return;
            };
            let _ = tx.send(Input::Socket(generation, SocketEvent::Open));
            let (mut write, mut read) = socket.split();
            loop {
                tokio::select! {
                    value=rx.recv()=>match value { Some(value)=>if write.send(Message::Text(value.to_string().into())).await.is_err() { break; },None=>break },
                    incoming=read.next()=>match incoming {
                        Some(Ok(Message::Text(text)))=>if let Ok(value)=serde_json::from_str(&text) { let _=tx.send(Input::Socket(generation,SocketEvent::Json(value))); },
                        Some(Ok(Message::Close(close)))=> { let (code,reason)=close.map_or((1005,String::new()),|c|(u16::from(c.code),c.reason.to_string()));let _=tx.send(Input::Socket(generation,SocketEvent::Close(code,reason)));return; },
                        Some(Ok(Message::Ping(bytes)))=>if write.send(Message::Pong(bytes)).await.is_err() { break; },
                        Some(Ok(_))=>{},_=>break,
                    }
                }
            }
            let _ = tx.send(Input::Socket(generation, SocketEvent::Error));
        }));
    }
    fn publish(&self) {
        let mut snapshot = self
            .handle
            .snapshot
            .write()
            .unwrap_or_else(|e| e.into_inner());
        snapshot.pairing = match &self.pairing {
            pairing::State::Unpaired => PairingView::Unpaired,
            pairing::State::Confirming(link) => PairingView::Confirming {
                fingerprint: link.fingerprint(),
                relay_host: link.relay_host(),
            },
            pairing::State::Pairing => PairingView::Pairing,
            pairing::State::Paired => PairingView::Paired,
            pairing::State::Removed(reason) => PairingView::Removed {
                reason: match reason {
                    pairing::Removed::Revoked => "revoked",
                    pairing::Removed::Unreadable => "unreadable",
                }
                .into(),
            },
        };
        snapshot.status = crate::status::text(&self.conn);
        snapshot.last_close = self
            .conn
            .last_close
            .as_ref()
            .map(|(code, reason)| format!("{code} {reason}"));
        snapshot.update_required =
            self.conn.state == State::Idle(Some(connection::Terminal::UpdateRequired));
        drop(snapshot);
        (self.notify)(Notification::Changed("pairing"));
        (self.notify)(Notification::Changed("status"));
    }
}
