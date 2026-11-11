use yorozu_core::{
    connection::{
        self as c, Effect as F, Event, EventKind as E, Machine, Payload, State as S, Terminal as T,
        Timer,
    },
    events::{ChatError, Envelope, ErrorInfo, PeerInfo},
    frame::b64,
    link::Link,
    pairing::{self as p, Effect as PF, Event as PE, Removed, State as PS},
    store::{Loaded, Pairing, Standing},
};
fn step(m: Machine, e: E, now: u64) -> (Machine, Vec<F>) {
    c::step(m, Event::command(e, now))
}
fn machine(state: S) -> Machine {
    let mut m = Machine::new(Standing::Known);
    m.state = state;
    m
}
fn frame(envelope: Envelope) -> E {
    E::RelayFrame {
        flow_bytes: None,
        payload: Payload::Box(envelope),
    }
}
fn peer() -> Envelope {
    Envelope::PeerInfo(PeerInfo::client("PC"))
}
fn link() -> Link {
    Link::parse(&format!(
        "yorozu://pair?relay=wss://relay.test&key={}&room={}&token=AQ&secret=Ag",
        b64([1; 32]),
        b64([2; 32])
    ))
    .unwrap()
}
#[test]
fn pairing_rows_p1_through_p18() {
    let l = link();
    let confirm = PS::Confirming(l.clone());
    assert_eq!(
        p::step(
            PS::Unpaired,
            PE::LinkSubmitted(format!(
                "yorozu://pair?relay=wss://relay.test&key={}&room={}&token=AQ&secret=Ag",
                b64([1; 32]),
                b64([2; 32])
            ))
        ),
        (confirm.clone(), vec![])
    ); // P1
    assert_eq!(
        p::step(PS::Unpaired, PE::LinkSubmitted("bad".into())),
        (PS::Unpaired, vec![PF::Notice(p::S2)])
    );
    assert_eq!(
        p::step(confirm.clone(), PE::Confirm),
        (PS::Pairing, vec![PF::Create(l.clone())])
    ); // P2
    assert_eq!(p::step(confirm, PE::Cancel), (PS::Unpaired, vec![])); // P3
    assert_eq!(
        p::step(PS::Pairing, PE::SessionOpened(42)),
        (PS::Paired, vec![PF::PersistPaired(42)])
    ); // P4
    for (reason, text) in [
        (T::PairingFailed, p::S4),
        (T::Revoked, p::S5),
        (T::UpdateRequired, p::S6),
    ] {
        assert_eq!(
            p::step(PS::Pairing, PE::Terminal(reason)),
            (PS::Unpaired, vec![PF::Stop, PF::Wipe, PF::Notice(text)])
        );
    } // P5-7
    assert_eq!(
        p::step(PS::Pairing, PE::Cancel),
        (PS::Unpaired, vec![PF::Stop, PF::Wipe, PF::Notice(p::S7)])
    ); // P8
    for reason in [T::Revoked, T::PairingFailed] {
        assert_eq!(
            p::step(PS::Paired, PE::Terminal(reason)),
            (PS::Removed(Removed::Revoked), vec![PF::Stop, PF::Wipe])
        );
    } // P9
    assert_eq!(
        p::step(PS::Paired, PE::Terminal(T::UpdateRequired)),
        (PS::Paired, vec![])
    ); // P10
    assert_eq!(
        p::step(PS::Paired, PE::Forget),
        (PS::Unpaired, vec![PF::Stop, PF::Wipe, PF::Notice(p::S10)])
    ); // P11
    for reason in [Removed::Revoked, Removed::Unreadable] {
        assert_eq!(
            p::step(PS::Removed(reason), PE::PairAgain),
            (PS::Unpaired, vec![PF::Wipe])
        );
    } // P12
    for state in [PS::Paired, PS::Pairing, PS::Removed(Removed::Revoked)] {
        assert_eq!(
            p::step(state.clone(), PE::LinkSubmitted("bad".into())),
            (state, vec![PF::Notice(p::S11)])
        );
    } // P13
    assert_eq!(
        p::step(PS::Pairing, PE::Joined),
        (PS::Pairing, vec![PF::PersistKnown])
    ); // P14
    assert_eq!(
        p::step(PS::Unpaired, PE::Launch(Loaded::Missing)),
        (PS::Unpaired, vec![])
    ); // P15
    assert_eq!(
        p::step(PS::Unpaired, PE::Launch(Loaded::Unreadable)),
        (PS::Removed(Removed::Unreadable), vec![])
    ); // P16
    let mut record = Pairing::new(&l, [3; 32], [4; 32]);
    for standing in [Standing::CodeOnly, Standing::Known] {
        record.standing = standing;
        assert_eq!(
            p::step(PS::Unpaired, PE::Launch(Loaded::Pairing(record.clone()))),
            (PS::Pairing, vec![PF::Start])
        );
    } // P17
    record.secret = None;
    assert_eq!(
        p::step(PS::Unpaired, PE::Launch(Loaded::Pairing(record))),
        (PS::Paired, vec![PF::Start])
    ); // P18
    assert_eq!(
        p::step(PS::Pairing, PE::SaveFailed { initial: true }),
        (PS::Unpaired, vec![PF::Notice(p::S13)])
    );
    assert_eq!(
        p::step(PS::Paired, PE::SaveFailed { initial: false }),
        (PS::Paired, vec![PF::Notice(p::S13)])
    );
    assert_eq!(p::step(PS::Unpaired, PE::Confirm), (PS::Unpaired, vec![]));
}
#[test]
fn connection_state_event_grid_every_row_and_default() {
    // Columns: start stop open nonce joined-off joined-on owner-on owner-off response
    // peer-good peer-bad update-error update-error-with-messageId other-box ignored accepted unknown-token revoked
    // transient-close error backoff-timer connect-timer handshake-timer ping-timer pong-timer pong.
    let states = [
        S::Idle(None),
        S::Idle(Some(T::Revoked)),
        S::Idle(Some(T::PairingFailed)),
        S::Idle(Some(T::UpdateRequired)),
        S::Backoff,
        S::Dialing,
        S::AwaitNonce,
        S::Joining,
        S::Joined,
        S::Handshaking { keys: false },
        S::Handshaking { keys: true },
        S::Open,
    ];
    let bad_peer = Envelope::PeerInfo(PeerInfo {
        protocol_min: 4,
        protocol_max: 4,
        ..PeerInfo::client("host")
    });
    let events = [
        E::Start,
        E::Stop,
        E::SocketOpen,
        E::Nonce("n".into()),
        E::Joined {
            owner_online: false,
            flow_control: true,
        },
        E::Joined {
            owner_online: true,
            flow_control: false,
        },
        E::Owner(true),
        E::Owner(false),
        E::RelayFrame {
            flow_bytes: None,
            payload: Payload::Response,
        },
        frame(peer()),
        frame(bad_peer),
        frame(Envelope::Error(ErrorInfo {
            code: "update_required".into(),
            message: "upgrade".into(),
        })),
        frame(Envelope::MessageError(ChatError {
            code: "update_required".into(),
            message: "upgrade".into(),
            conv_id: None,
            message_id: Some("m".into()),
        })),
        frame(Envelope::Unknown),
        E::RelayFrame {
            flow_bytes: None,
            payload: Payload::Ignored,
        },
        E::Accepted("sig".into()),
        E::Close {
            code: 4001,
            reason: "unknown token".into(),
        },
        E::Close {
            code: 4001,
            reason: "revoked".into(),
        },
        E::Close {
            code: 1013,
            reason: "slow receiver".into(),
        },
        E::Error,
        E::Timer(Timer::Backoff),
        E::Timer(Timer::Connect),
        E::Timer(Timer::Handshake),
        E::Timer(Timer::Ping),
        E::Timer(Timer::Pong),
        E::Pong,
    ];
    // 0 = explicit default. Each nonzero cell names the spec row, not implementation output.
    let rows: [[_; 26]; 12] = [
        [
            1, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ],
        [
            1, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ],
        [
            1, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ],
        [
            1, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ],
        [
            1, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0,
        ],
        [
            0, 16, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13, 13, 14, 14, 0, 14, 0, 0, 14, 0,
        ],
        [
            0, 16, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13, 13, 14, 14, 0, 14, 0, 0, 14, 0,
        ],
        [
            0, 16, 0, 0, 4, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13, 13, 14, 14, 0, 14, 0, 0, 14, 0,
        ],
        [
            0, 16, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 12, 13, 13, 14, 14, 0, 14, 0, 15, 14, 15,
        ],
        [
            0, 16, 0, 0, 0, 0, 0, 10, 6, 0, 0, 0, 0, 0, 0, 12, 13, 13, 14, 14, 0, 14, 9, 15, 14, 15,
        ],
        [
            0, 16, 0, 0, 0, 0, 0, 10, 0, 7, 8, 8, 8, 0, 0, 12, 13, 13, 14, 14, 0, 14, 9, 15, 14, 15,
        ],
        [
            0, 16, 0, 0, 0, 0, 0, 10, 0, 11, 8, 8, 8, 11, 0, 12, 13, 13, 14, 14, 0, 14, 0, 15, 14,
            15,
        ],
    ];
    for (i, state) in states.iter().enumerate() {
        for (j, event) in events.iter().enumerate() {
            let before = machine(state.clone());
            let (after, effects) = step(before.clone(), event.clone(), 100);
            let row = rows[i][j];
            let label = format!("state={state:?} event={event:?} row=C{row}");
            match row {
                0 => {
                    assert_eq!(after, before, "{label}");
                    assert!(effects.is_empty(), "{label}");
                }
                1 => {
                    assert_eq!(after.state, S::Dialing, "{label}");
                    assert!(effects.contains(&F::Dial));
                    assert!(effects
                        .iter()
                        .any(|f| matches!(f, F::Arm(Timer::Connect, _, 20_000))));
                }
                2 => {
                    assert_eq!(after.state, S::AwaitNonce);
                    assert!(effects.is_empty());
                }
                3 => {
                    assert_eq!(after.state, S::Joining);
                    assert_eq!(
                        effects,
                        vec![F::Join {
                            nonce: "n".into(),
                            token: false
                        }]
                    );
                }
                4 => {
                    assert_eq!(after.state, S::Joined);
                    assert!(after.flow.enabled);
                    assert_eq!(after.flow.last_ack, 0);
                    assert!(effects
                        .iter()
                        .any(|f| matches!(f, F::Cancel(Timer::Connect))));
                }
                5 | 9 => {
                    assert_eq!(after.state, S::Handshaking { keys: false });
                    assert_eq!(after.inits, 1);
                    assert!(effects.contains(&F::Init));
                    assert!(effects
                        .iter()
                        .any(|f| matches!(f, F::Arm(Timer::Handshake, _, 15_000))));
                }
                6 => {
                    assert_eq!(after.state, S::Handshaking { keys: true });
                    assert_eq!(effects, vec![F::PeerInfo]);
                }
                7 => {
                    assert_eq!(after.state, S::Open);
                    assert_eq!(after.opened_at, Some(100));
                    assert_eq!(after.inits, 0);
                    assert!(effects.contains(&F::SessionOpened));
                }
                8 => {
                    assert_eq!(after.state, S::Idle(Some(T::UpdateRequired)));
                    assert!(effects.contains(&F::Close));
                    assert!(effects.contains(&F::Terminal(T::UpdateRequired)));
                }
                10 => {
                    assert_eq!(after.state, S::Joined);
                    assert_eq!(effects.contains(&F::SessionLost), *state == S::Open);
                }
                11 => {
                    assert_eq!(after.state, S::Open);
                    assert!(matches!(&effects[..], [F::Chat(_)]));
                }
                12 => {
                    assert_eq!(after.state, *state);
                    assert_eq!(effects, vec![F::Accepted("sig".into())]);
                }
                13 => {
                    assert!(matches!(after.state, S::Idle(Some(_))));
                    assert!(effects.contains(&F::Terminal(if j == 16 {
                        T::PairingFailed
                    } else {
                        T::Revoked
                    })));
                }
                14 => {
                    assert_eq!(after.state, S::Backoff);
                    assert_eq!(after.attempt, 1);
                    assert_eq!(effects.contains(&F::SessionLost), *state == S::Open);
                    assert!(effects
                        .iter()
                        .any(|f| matches!(f, F::Arm(Timer::Backoff, _, 1000))));
                }
                15 => {
                    assert_eq!(after.state, *state);
                    if j == 25 {
                        assert_eq!(effects, vec![F::Cancel(Timer::Pong)]);
                    } else {
                        assert!(effects.contains(&F::Ping));
                        assert!(effects
                            .iter()
                            .any(|f| matches!(f, F::Arm(Timer::Pong, _, 10_000))));
                    }
                }
                16 => {
                    assert_eq!(after.state, S::Idle(None));
                    assert!(effects.contains(&F::Close));
                    assert_eq!(
                        effects.iter().filter(|f| matches!(f, F::Cancel(_))).count(),
                        5
                    );
                }
                _ => unreachable!(),
            }
        }
    }
}
#[test]
fn c0_counts_undecodable_frames_in_every_socket_state_and_ignores_stale_socket() {
    for state in [
        S::Idle(None),
        S::Backoff,
        S::Dialing,
        S::AwaitNonce,
        S::Joining,
        S::Joined,
        S::Handshaking { keys: false },
        S::Handshaking { keys: true },
        S::Open,
    ] {
        let mut m = machine(state.clone());
        m.flow.enabled = true;
        m.socket_generation = 7;
        let event = E::RelayFrame {
            flow_bytes: Some(262144),
            payload: Payload::Ignored,
        };
        let (after, effects) = step(m.clone(), event.clone(), 0);
        assert_eq!(after.flow.last_ack, if state.socket() { 262144 } else { 0 });
        assert_eq!(effects.len(), usize::from(state.socket()));
        assert_eq!(
            c::step(
                m.clone(),
                Event {
                    kind: event,
                    generation: Some(6),
                    now_ms: 0
                }
            ),
            (m, vec![])
        );
    }
}
#[test]
fn c13a_recovers_failed_persistence_once_and_c4_changes_standing() {
    let mut m = machine(S::Joining);
    m.standing = Standing::CodeOnly;
    m.attempt = 4;
    let (m, effects) = step(
        m,
        E::Close {
            code: 4001,
            reason: "unknown token".into(),
        },
        0,
    );
    assert_eq!(m.state, S::Dialing);
    assert!(m.retried_as_known);
    assert_eq!(m.attempt, 4);
    assert!(effects.contains(&F::Dial));
    let (m, _) = step(m, E::SocketOpen, 0);
    let (m, effects) = step(m, E::Nonce("n".into()), 0);
    assert_eq!(
        effects,
        vec![F::Join {
            nonce: "n".into(),
            token: false
        }]
    );
    let (m, effects) = step(
        m,
        E::Joined {
            owner_online: false,
            flow_control: false,
        },
        0,
    );
    assert_eq!(m.standing, Standing::Known);
    assert!(effects.contains(&F::PersistKnown));
    let mut failed = m;
    failed.state = S::Joining;
    failed.standing = Standing::CodeOnly;
    let (failed, effects) = step(
        failed,
        E::Close {
            code: 4001,
            reason: "unknown token".into(),
        },
        0,
    );
    assert_eq!(failed.state, S::Idle(Some(T::PairingFailed)));
    assert!(effects.contains(&F::Terminal(T::PairingFailed)));
}
#[test]
fn backoff_caps_and_resets_only_after_ten_seconds_open_and_timers_are_stale() {
    let mut m = machine(S::Dialing);
    for expected in [1000, 2000, 4000, 8000, 16000, 30000, 30000] {
        let (next, effects) = step(m, E::Error, 0);
        m = next;
        assert!(effects
            .iter()
            .any(|f| matches!(f,F::Arm(Timer::Backoff,_,ms) if *ms==expected)));
        let old_generation = m.timer_generations[Timer::Backoff.index()];
        let (next, _) = step(m, E::Start, 0);
        m = next;
        let (next, effects) = c::step(
            m.clone(),
            Event {
                kind: E::Timer(Timer::Backoff),
                generation: Some(old_generation),
                now_ms: 0,
            },
        );
        assert_eq!(next, m);
        assert!(effects.is_empty());
        // 7.4: attempt never resets at joined, only after 10 s Open.
        m.state = S::Joining;
        let attempt = m.attempt;
        let (next, _) = step(
            m,
            E::Joined {
                owner_online: true,
                flow_control: false,
            },
            0,
        );
        m = next;
        assert_eq!(m.attempt, attempt);
    }
    m.state = S::Open;
    m.opened_at = Some(1000);
    let (mut m, _) = step(m, E::Error, 10999);
    assert_eq!(m.attempt, 8);
    m.state = S::Open;
    m.opened_at = Some(1000);
    let (m, effects) = step(m, E::Error, 11000);
    assert_eq!(m.attempt, 1);
    assert!(effects
        .iter()
        .any(|f| matches!(f, F::Arm(Timer::Backoff, _, 1000))));
    // A timer from an earlier backoff is stale in a later one: only its generation stops C1.
    let old_generation = m.timer_generations[Timer::Backoff.index()];
    let (m, _) = step(m, E::Start, 0);
    let (m, _) = step(m, E::Error, 0);
    assert_eq!(m.state, S::Backoff);
    assert_eq!(
        c::step(
            m.clone(),
            Event {
                kind: E::Timer(Timer::Backoff),
                generation: Some(old_generation),
                now_ms: 0
            }
        ),
        (m, vec![])
    );
}

#[test]
fn status_hints_and_owner_offline_ends_long_open_backoff_streak() {
    use yorozu_core::status;
    for state in [S::Dialing, S::AwaitNonce, S::Joining, S::Backoff] {
        assert_eq!(
            status::text(&machine(state)).as_deref(),
            Some("Connecting…")
        );
    }
    assert_eq!(
        status::text(&machine(S::Joined)).as_deref(),
        Some("Your host is offline.")
    );
    let mut m = machine(S::Handshaking { keys: false });
    m.inits = 2;
    assert_eq!(
        status::text(&m).as_deref(),
        Some("Connecting to your host…")
    );
    m.inits = 3;
    assert_eq!(status::text(&m).as_deref(),Some("Your host isn't answering. Check that its Yorozu plugin is up to date and that this PC's clock is right."));
    assert_eq!(
        status::text(&machine(S::Idle(Some(T::UpdateRequired)))).as_deref(),
        Some(p::S9)
    );
    assert_eq!(status::text(&machine(S::Open)), None);
    // 7.2: the last close shows only on the "Connecting…" row.
    for state in [
        S::Idle(None),
        S::Joined,
        S::Handshaking { keys: false },
        S::Open,
    ] {
        let mut m = machine(state);
        m.last_close = Some((4011, "host offline".into()));
        assert_eq!(status::last_close(&m), None);
    }
    let mut m = machine(S::Backoff);
    assert_eq!(status::last_close(&m), None);
    m.last_close = Some((4011, "host offline".into()));
    assert_eq!(status::last_close(&m).as_deref(), Some("4011 host offline"));
    m.last_close = Some((1005, String::new()));
    assert_eq!(status::last_close(&m).as_deref(), Some("1005"));
    let mut m = machine(S::Open);
    m.attempt = 6;
    m.opened_at = Some(100);
    let (m, _) = step(m, E::Owner(false), 10100);
    assert_eq!(m.attempt, 0);
    assert_eq!(m.opened_at, None);
    let (m, effects) = step(m, E::Error, 11000);
    assert_eq!(m.attempt, 1);
    assert!(effects
        .iter()
        .any(|f| matches!(f, F::Arm(Timer::Backoff, _, 1000))));
}

#[test]
fn token_join_flow_reset_and_handshake_retry_generations() {
    let mut m = machine(S::AwaitNonce);
    m.standing = Standing::CodeOnly;
    let (mut m, effects) = step(m, E::Nonce("nonce".into()), 0);
    assert_eq!(
        effects,
        vec![F::Join {
            nonce: "nonce".into(),
            token: true
        }]
    );
    m.flow.last_ack = 999;
    m.flow.frames_since_ack = 9;
    let (mut m, _) = step(
        m,
        E::Joined {
            owner_online: true,
            flow_control: true,
        },
        0,
    );
    assert_eq!(m.flow.last_ack, 0);
    assert_eq!(m.flow.frames_since_ack, 0);
    for expected in [2, 3] {
        let stale = m.timer_generations[Timer::Handshake.index()];
        let (next, effects) = step(m, E::Timer(Timer::Handshake), 0);
        m = next;
        assert_eq!(m.inits, expected);
        assert!(effects.contains(&F::Init));
        // The timer armed before the C9 re-init is stale while still Handshaking.
        assert_eq!(m.state, S::Handshaking { keys: false });
        assert_eq!(
            c::step(
                m.clone(),
                Event {
                    kind: E::Timer(Timer::Handshake),
                    generation: Some(stale),
                    now_ms: 0
                }
            ),
            (m.clone(), vec![])
        );
    }
    let (m, _) = step(
        m,
        E::RelayFrame {
            flow_bytes: None,
            payload: Payload::Response,
        },
        0,
    );
    let old = m.timer_generations[Timer::Handshake.index()];
    let (m, _) = step(m, frame(peer()), 100);
    assert_eq!(m.inits, 0);
    assert_eq!(m.opened_at, Some(100));
    assert_eq!(
        c::step(
            m.clone(),
            Event {
                kind: E::Timer(Timer::Handshake),
                generation: Some(old),
                now_ms: 100
            }
        ),
        (m, vec![])
    );
}
