use crate::{
    events::Envelope,
    flow::{self, Flow, FlowAck},
    store::Standing,
};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Terminal {
    Revoked,
    PairingFailed,
    UpdateRequired,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    Idle(Option<Terminal>),
    Backoff,
    Dialing,
    AwaitNonce,
    Joining,
    Joined,
    Handshaking { keys: bool },
    Open,
}
impl State {
    pub fn socket(&self) -> bool {
        matches!(
            self,
            Self::Dialing
                | Self::AwaitNonce
                | Self::Joining
                | Self::Joined
                | Self::Handshaking { .. }
                | Self::Open
        )
    }
    pub fn name(&self) -> &'static str {
        match self {
            Self::Idle(_) => "Idle",
            Self::Backoff => "Backoff",
            Self::Dialing => "Dialing",
            Self::AwaitNonce => "AwaitNonce",
            Self::Joining => "Joining",
            Self::Joined => "Joined",
            Self::Handshaking { .. } => "Handshaking",
            Self::Open => "Open",
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Timer {
    Backoff,
    Connect,
    Handshake,
    Ping,
    Pong,
}
impl Timer {
    pub fn index(self) -> usize {
        self as usize
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Payload {
    Response,
    Box(Envelope),
    Ignored,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EventKind {
    Start,
    Stop,
    SocketOpen,
    Nonce(String),
    Joined {
        owner_online: bool,
        flow_control: bool,
    },
    Owner(bool),
    RelayFrame {
        flow_bytes: Option<u64>,
        payload: Payload,
    },
    Accepted(String),
    Close {
        code: u16,
        reason: String,
    },
    Error,
    Timer(Timer),
    Pong,
}
#[derive(Clone, Debug)]
pub struct Event {
    pub kind: EventKind,
    pub generation: Option<u64>,
    pub now_ms: u64,
}
impl Event {
    pub fn command(kind: EventKind, now_ms: u64) -> Self {
        Self {
            kind,
            generation: None,
            now_ms,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    Dial,
    Close,
    Arm(Timer, u64, u64),
    Cancel(Timer),
    Join { nonce: String, token: bool },
    PersistKnown,
    Init,
    PeerInfo,
    SendFlowAck(FlowAck),
    Ping,
    SessionOpened,
    SessionLost,
    Terminal(Terminal),
    Accepted(String),
    Chat(Envelope),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Machine {
    pub state: State,
    pub standing: Standing,
    pub attempt: u32,
    pub inits: u32,
    pub opened_at: Option<u64>,
    pub retried_as_known: bool,
    pub socket_generation: u64,
    pub timer_generations: [u64; 5],
    pub flow: Flow,
    pub last_close: Option<(u16, String)>,
}
impl Machine {
    pub fn new(standing: Standing) -> Self {
        Self {
            state: State::Idle(None),
            standing,
            attempt: 0,
            inits: 0,
            opened_at: None,
            retried_as_known: false,
            socket_generation: 0,
            timer_generations: [0; 5],
            flow: Flow::default(),
            last_close: None,
        }
    }
    fn arm(&mut self, t: Timer, ms: u64, effects: &mut Vec<Effect>) {
        self.timer_generations[t.index()] += 1;
        effects.push(Effect::Arm(t, self.timer_generations[t.index()], ms));
    }
    fn cancel(&mut self, t: Timer, effects: &mut Vec<Effect>) {
        self.timer_generations[t.index()] += 1;
        effects.push(Effect::Cancel(t));
    }
    fn cancel_all(&mut self, effects: &mut Vec<Effect>) {
        for t in [
            Timer::Backoff,
            Timer::Connect,
            Timer::Handshake,
            Timer::Ping,
            Timer::Pong,
        ] {
            self.cancel(t, effects);
        }
    }
    fn end_session(&mut self, now: u64) {
        if self.state == State::Open
            && self
                .opened_at
                .is_some_and(|at| now.saturating_sub(at) >= 10_000)
        {
            self.attempt = 0;
        }
        self.opened_at = None;
    }
    fn dial(&mut self, effects: &mut Vec<Effect>) {
        self.cancel_all(effects);
        self.socket_generation += 1;
        self.state = State::Dialing;
        effects.push(Effect::Dial);
        self.arm(Timer::Connect, 20_000, effects);
    }
    fn init(&mut self, effects: &mut Vec<Effect>) {
        self.state = State::Handshaking { keys: false };
        self.inits = self.inits.saturating_add(1);
        effects.push(Effect::Init);
        self.arm(Timer::Handshake, 15_000, effects);
    }
}
pub fn close_outcome(code: u16, reason: &str, standing: Standing) -> Option<Terminal> {
    if code != 4001 {
        return None;
    }
    match reason {
        "revoked" => Some(Terminal::Revoked),
        "unknown device" if standing == Standing::Known => Some(Terminal::Revoked),
        "unknown token" | "expired token" | "unknown device" => Some(Terminal::PairingFailed),
        _ => None,
    }
}
pub fn backoff_ms(attempt: u32) -> u64 {
    1000 * (1u64 << attempt.saturating_sub(1).min(5)).min(30)
}
pub fn step(mut m: Machine, event: Event) -> (Machine, Vec<Effect>) {
    use Effect as F;
    use EventKind as E;
    use State as S;
    let mut effects = Vec::new();
    if let Some(generation) = event.generation {
        let expected = if let E::Timer(t) = &event.kind {
            m.timer_generations[t.index()]
        } else {
            m.socket_generation
        };
        if generation != expected {
            return (m, effects);
        }
    }
    // C0 precedes all payload handling, including foreign and malformed frames.
    if m.state.socket() {
        if let E::RelayFrame { flow_bytes, .. } = &event.kind {
            if let Some(ack) = flow::on_relay_frame(&mut m.flow, *flow_bytes) {
                effects.push(F::SendFlowAck(ack));
            }
        }
    }
    match (&m.state, &event.kind) {
        (S::Idle(_) | S::Backoff, E::Start) | (S::Backoff, E::Timer(Timer::Backoff)) => {
            m.dial(&mut effects)
        } // C1
        (S::Dialing, E::SocketOpen) => m.state = S::AwaitNonce, // C2
        (S::AwaitNonce, E::Nonce(nonce)) => {
            m.state = S::Joining;
            effects.push(F::Join {
                nonce: nonce.clone(),
                token: m.standing == Standing::CodeOnly && !m.retried_as_known,
            });
        } // C3
        (
            S::Joining,
            E::Joined {
                owner_online,
                flow_control,
            },
        ) => {
            // C4, C5
            m.state = S::Joined;
            m.cancel(Timer::Connect, &mut effects);
            m.flow = Flow {
                enabled: *flow_control,
                ..Flow::default()
            };
            if m.standing == Standing::CodeOnly {
                m.standing = Standing::Known;
                effects.push(F::PersistKnown);
            }
            m.arm(Timer::Ping, 25_000, &mut effects);
            if *owner_online {
                m.init(&mut effects);
            }
        }
        (S::Joined, E::Owner(true)) => m.init(&mut effects), // C5
        (
            S::Handshaking { keys: false },
            E::RelayFrame {
                payload: Payload::Response,
                ..
            },
        ) => {
            m.state = S::Handshaking { keys: true };
            effects.push(F::PeerInfo);
        } // C6
        (
            S::Handshaking { keys: true },
            E::RelayFrame {
                payload: Payload::Box(Envelope::PeerInfo(peer)),
                ..
            },
        ) if peer.compatible() => {
            // C7
            m.state = S::Open;
            m.cancel(Timer::Handshake, &mut effects);
            m.inits = 0;
            m.opened_at = Some(event.now_ms);
            effects.push(F::SessionOpened);
        }
        (
            S::Handshaking { keys: true } | S::Open,
            E::RelayFrame {
                payload: Payload::Box(envelope),
                ..
            },
        ) if matches!(envelope, Envelope::PeerInfo(peer) if !peer.compatible())
            || matches!(envelope, Envelope::Error(error) if error.code == "update_required")
            || matches!(envelope, Envelope::MessageError(error) if error.code == "update_required") =>
        {
            // C8
            m.end_session(event.now_ms);
            m.state = S::Idle(Some(Terminal::UpdateRequired));
            m.socket_generation += 1;
            effects.push(F::Close);
            m.cancel_all(&mut effects);
            effects.push(F::Terminal(Terminal::UpdateRequired));
        }
        (S::Handshaking { .. }, E::Timer(Timer::Handshake)) => m.init(&mut effects), // C9
        (S::Handshaking { .. } | S::Open, E::Owner(false)) => {
            // C10
            if m.state == S::Open {
                effects.push(F::SessionLost);
            }
            m.end_session(event.now_ms);
            m.state = S::Joined;
            m.cancel(Timer::Handshake, &mut effects);
        }
        (
            S::Open,
            E::RelayFrame {
                payload: Payload::Box(envelope),
                ..
            },
        ) => effects.push(F::Chat(envelope.clone())), // C11
        (S::Joined | S::Handshaking { .. } | S::Open, E::Accepted(sig)) => {
            effects.push(F::Accepted(sig.clone()))
        } // C12
        (state, E::Close { code: 4001, reason })
            if state.socket()
                && reason == "unknown token"
                && m.standing == Standing::CodeOnly
                && !m.retried_as_known =>
        {
            m.last_close = Some((4001, reason.clone()));
            m.retried_as_known = true;
            effects.push(F::Close);
            m.dial(&mut effects);
        } // C13a
        (state, E::Close { code, reason })
            if state.socket() && close_outcome(*code, reason, m.standing).is_some() =>
        {
            // C13
            let Some(terminal) = close_outcome(*code, reason, m.standing) else {
                return (m, effects);
            };
            m.last_close = Some((*code, reason.clone()));
            m.state = S::Idle(Some(terminal));
            m.socket_generation += 1;
            effects.push(F::Close);
            m.cancel_all(&mut effects);
            effects.push(F::Terminal(terminal));
        }
        (state, E::Close { .. } | E::Error | E::Timer(Timer::Connect | Timer::Pong))
            if state.socket() =>
        {
            // C14
            if let E::Close { code, reason } = &event.kind {
                m.last_close = Some((*code, reason.clone()));
            }
            if m.state == S::Open {
                effects.push(F::SessionLost);
            }
            m.end_session(event.now_ms);
            m.opened_at = None;
            m.state = S::Backoff;
            m.socket_generation += 1;
            effects.push(F::Close);
            m.cancel_all(&mut effects);
            m.attempt = m.attempt.saturating_add(1);
            m.arm(Timer::Backoff, backoff_ms(m.attempt), &mut effects);
        }
        (S::Joined | S::Handshaking { .. } | S::Open, E::Timer(Timer::Ping)) => {
            effects.push(F::Ping);
            m.arm(Timer::Ping, 25_000, &mut effects);
            m.arm(Timer::Pong, 10_000, &mut effects);
        } // C15
        (S::Joined | S::Handshaking { .. } | S::Open, E::Pong) => {
            m.cancel(Timer::Pong, &mut effects)
        }
        (_, E::Stop) => {
            m.state = S::Idle(None);
            m.socket_generation += 1;
            effects.push(F::Close);
            m.cancel_all(&mut effects);
        } // C16
        _ => {} // Explicit default: unchanged, no effects (except C0).
    }
    (m, effects)
}
