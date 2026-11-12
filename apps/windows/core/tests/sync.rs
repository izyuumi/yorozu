use yorozu_core::{
    events::{ChatError, ConvList, Envelope, History, Message, Reply},
    model::{Conversation, Item},
    outbox,
    sync::{Effect, Event, Machine},
};
fn conv(id: &str) -> Conversation {
    Conversation {
        conv_id: id.into(),
        updated_at: 1,
        title: None,
        archived: false,
        deleted: false,
    }
}
fn item(id: &str, seq: Option<i64>) -> Item {
    let mut i = Item::live("agent", id, "text", 1);
    i.seq = seq;
    i
}
fn page(c: &str, before: Option<i64>, items: Vec<Item>, more: bool) -> Envelope {
    Envelope::History(History {
        conv_id: c.into(),
        before,
        items: Some(items),
        more,
    })
}
fn list(ids: &[&str]) -> Envelope {
    Envelope::ConvList(ConvList {
        conversations: Some(ids.iter().map(|c| conv(c)).collect()),
        raw: ids.len(),
    })
}
fn live(m: &mut Machine, e: Envelope, o: &outbox::Machine, now: u64) -> Vec<Effect> {
    m.step(Event::Live(e), o, now)
}
#[test]
fn list_drop_rule_and_three_exceptions() {
    let mut m = Machine::default();
    let mut o = outbox::Machine::default();
    m.list = vec![conv("drop"), conv("open"), conv("pending")];
    o.step(outbox::Event::Send(Message {
        conv_id: "pending".into(),
        message_id: "p".into(),
        text: "p".into(),
    }));
    m.step(Event::Open(Some("open".into())), &o, 0);
    m.step(Event::SessionOpened, &o, 0);
    live(&mut m, list(&[]), &o, 1);
    assert_eq!(
        m.list
            .iter()
            .map(|c| c.conv_id.as_str())
            .collect::<Vec<_>>(),
        vec!["open", "pending"]
    );
    m.step(Event::SessionLost, &o, 2);
    m.list.push(conv("capped"));
    m.step(Event::SessionOpened, &o, 3);
    let rows = (0..2000).map(|n| conv(&n.to_string())).collect();
    live(
        &mut m,
        Envelope::ConvList(ConvList {
            conversations: Some(rows),
            raw: 2000,
        }),
        &o,
        4,
    );
    assert!(m.list.iter().any(|c| c.conv_id == "capped"));
    // The cap counts the rows the answer carried, before a malformed one is dropped.
    m.step(Event::SessionLost, &o, 5);
    m.list = vec![conv("raw")];
    m.step(Event::SessionOpened, &o, 6);
    let mut rows = vec![serde_json::json!({"convId":"malformed"})];
    for n in 0..1999 {
        let id = format!("00000000-0000-0000-0000-{n:012}");
        rows.push(serde_json::json!({"convId":id,"updatedAt":1}));
    }
    let answer = serde_json::json!({"kind":"conv_list","data":{"conversations":rows}});
    let bytes = serde_json::to_vec(&answer).unwrap();
    live(&mut m, Envelope::decode(&bytes).unwrap(), &o, 7);
    assert_eq!(m.list.len(), 2000);
    assert!(m.list.iter().any(|c| c.conv_id == "raw"));
}
#[test]
fn newest_replaces_except_pending_and_late_seqless_then_older_pages_merge() {
    let mut m = Machine::default();
    let mut o = outbox::Machine::default();
    m.step(Event::Open(Some("c".into())), &o, 0);
    m.step(Event::SessionOpened, &o, 0);
    live(&mut m, list(&["c"]), &o, 1);
    o.step(outbox::Event::Send(Message {
        conv_id: "c".into(),
        message_id: "p".into(),
        text: "pending".into(),
    }));
    m.step(
        Event::Outgoing(Message {
            conv_id: "c".into(),
            message_id: "p".into(),
            text: "pending".into(),
        }),
        &o,
        2,
    );
    live(
        &mut m,
        Envelope::Reply(Reply {
            conv_id: "c".into(),
            message_id: "late".into(),
            text: "late".into(),
            ts: 2,
        }),
        &o,
        2,
    );
    live(
        &mut m,
        page("c", None, vec![item("old", Some(10))], true),
        &o,
        3,
    );
    assert_eq!(m.open.as_ref().unwrap().items.len(), 3);
    assert_eq!(
        m.open
            .as_ref()
            .unwrap()
            .items
            .iter()
            .map(|i| i.id.as_str())
            .collect::<Vec<_>>(),
        vec!["old", "p", "late"]
    );
    let effects = m.step(Event::Older("c".into()), &o, 4);
    assert!(matches!(
        effects.first(),
        Some(Effect::Send(Envelope::History(History {
            before: Some(10),
            ..
        })))
    ));
    live(
        &mut m,
        page("c", Some(10), vec![item("older", Some(1))], false),
        &o,
        5,
    );
    assert!(!m.open.as_ref().unwrap().older_more);
    assert_eq!(m.open.as_ref().unwrap().items[0].id, "older");
    m.step(Event::SessionLost, &o, 6);
    m.step(Event::SessionOpened, &o, 7);
    live(&mut m, list(&["c"]), &o, 8);
    live(&mut m, page("c", None, vec![], false), &o, 9);
    assert_eq!(
        m.open
            .as_ref()
            .unwrap()
            .items
            .iter()
            .map(|i| i.id.as_str())
            .collect::<Vec<_>>(),
        vec!["p"]
    );
}
#[test]
fn conv_update_full_state_unarchives_and_closes_with_notice() {
    let mut m = Machine::default();
    let o = outbox::Machine::default();
    let mut c = conv("c");
    c.title = Some("Title".into());
    live(&mut m, Envelope::ConvUpdate(c), &o, 0);
    live(&mut m, Envelope::ConvUpdate(conv("c")), &o, 1);
    assert!(m.list[0].title.is_none());
    m.step(Event::Open(Some("c".into())), &o, 2);
    let mut c = conv("c");
    c.archived = true;
    assert!(live(&mut m, Envelope::ConvUpdate(c), &o, 3)
        .iter()
        .any(|e| matches!(e, Effect::Notice(_))));
    assert!(m.open.is_none());
    assert!(m.list.is_empty());
    live(&mut m, Envelope::ConvUpdate(conv("c")), &o, 4);
    assert_eq!(m.list.len(), 1);
    let mut deleted = conv("c");
    deleted.deleted = true;
    live(&mut m, Envelope::ConvUpdate(deleted), &o, 5);
    assert!(m.list.is_empty());
}
#[test]
fn queue_releases_on_answer_unscoped_error_timeout_and_loss() {
    let mut m = Machine::default();
    let o = outbox::Machine::default();
    m.step(Event::SessionOpened, &o, 0);
    m.step(Event::Open(Some("c".into())), &o, 0);
    assert!(live(&mut m, page("c", None, vec![], false), &o, 1).is_empty());
    assert!(live(
        &mut m,
        Envelope::MessageError(ChatError {
            code: "bad_request".into(),
            message: "bad".into(),
            conv_id: None,
            message_id: Some("p".into())
        }),
        &o,
        1
    )
    .is_empty());
    // A tick changes something only once the flight's 30 s are up.
    assert!(!m.due(29_999));
    assert!(m.due(30_000));
    assert!(m.step(Event::Tick, &o, 29_999).is_empty());
    assert!(matches!(
        m.step(Event::Tick, &o, 30_000).first(),
        Some(Effect::Send(Envelope::History(_)))
    ));
    m.step(Event::Open(Some("d".into())), &o, 30_001);
    let e = Envelope::decode(br#"{"kind":"error","data":{"code":"internal","message":"oops"}}"#)
        .unwrap();
    assert!(matches!(
        live(&mut m, e, &o, 30_002).first(),
        Some(Effect::Send(Envelope::History(_)))
    ));
    m.step(Event::SessionLost, &o, 30_003);
    assert!(live(
        &mut m,
        page("d", None, vec![item("late", Some(1))], false),
        &o,
        30_004
    )
    .is_empty());
    assert!(m.open.as_ref().unwrap().items.is_empty());
}
#[test]
fn open_keeps_pending_rows_and_live_run_fetches_after_current_page() {
    use yorozu_core::events::{MessageRef, Tool, Typing};
    use yorozu_core::model::ToolCall;
    let mut m = Machine::default();
    let mut o = outbox::Machine::default();
    o.step(outbox::Event::Send(Message {
        conv_id: "c".into(),
        message_id: "pending".into(),
        text: "First line\nsecond".into(),
    }));
    m.step(Event::Open(Some("c".into())), &o, 0);
    assert_eq!(m.open.as_ref().unwrap().items.len(), 1);
    m.step(Event::SessionOpened, &o, 0);
    live(&mut m, list(&["c"]), &o, 1);
    assert_eq!(m.title(&m.list[0]), "First line");
    live(
        &mut m,
        Envelope::RunStarted(MessageRef {
            conv_id: "c".into(),
            message_id: "remote".into(),
        }),
        &o,
        2,
    );
    assert!(matches!(
        live(&mut m, page("c", None, vec![], false), &o, 3).last(),
        Some(Effect::Send(Envelope::History(_)))
    ));
    live(
        &mut m,
        Envelope::Typing(Typing {
            conv_id: "c".into(),
            active: true,
        }),
        &o,
        4,
    );
    assert!(m.open.as_ref().unwrap().typing_until.is_some());
    // The refetch's flight expires first; after that only the typing deadline is left.
    m.step(Event::Tick, &o, 30_003);
    assert!(!m.due(30_003));
    assert!(m.due(30_004));
    m.step(Event::Tick, &o, 30_004);
    assert!(m.open.as_ref().unwrap().typing_until.is_none());
    assert!(!m.due(u64::MAX));
    for status in ["running", "done", "future"] {
        live(
            &mut m,
            Envelope::Tool(Tool {
                conv_id: "c".into(),
                message_id: "pending".into(),
                call: ToolCall {
                    call_id: "call".into(),
                    name: "read".into(),
                    status: status.into(),
                },
            }),
            &o,
            30_005,
        );
    }
    let open = m.open.as_ref().unwrap();
    assert_eq!(
        open.items.iter().find(|i| i.kind == "tools").unwrap().tools[0].status,
        "done"
    );
    assert_eq!(open.items.iter().filter(|i| i.id == "pending").count(), 2);
    m.step(Event::Open(None), &o, 30_006);
    m.step(Event::Open(Some("c".into())), &o, 30_007);
    assert_eq!(m.open.as_ref().unwrap().items.len(), 1);
}
fn span(from: i64, to: i64) -> Vec<Item> {
    (from..=to)
        .map(|n| item(&format!("i{n}"), Some(n)))
        .collect()
}
fn history_sends(effects: &[Effect]) -> Vec<Option<i64>> {
    effects
        .iter()
        .filter_map(|e| match e {
            Effect::Send(Envelope::History(h)) => Some(h.before),
            _ => None,
        })
        .collect()
}
fn opened(effects: &[Effect]) -> Option<bool> {
    effects.iter().find_map(|e| match e {
        Effect::Page { opened, .. } => Some(*opened),
        _ => None,
    })
}
fn run_started(m: &mut Machine, o: &outbox::Machine, now: u64) -> Vec<Effect> {
    live(
        m,
        Envelope::RunStarted(yorozu_core::events::MessageRef {
            conv_id: "c".into(),
            message_id: "remote".into(),
        }),
        o,
        now,
    )
}
#[test]
fn only_the_first_newest_page_after_open_is_marked_opened() {
    let mut m = Machine::default();
    let o = outbox::Machine::default();
    // Opened offline: the session-start fetch is this conversation's first newest page.
    m.step(Event::Open(Some("c".into())), &o, 0);
    m.step(Event::SessionOpened, &o, 0);
    live(&mut m, list(&["c"]), &o, 1);
    let first = live(&mut m, page("c", None, span(1, 2), true), &o, 2);
    assert_eq!(opened(&first), Some(true));
    // An older page is never the opening page.
    assert_eq!(
        history_sends(&m.step(Event::Older("c".into()), &o, 3)),
        [Some(1)]
    );
    let older = live(&mut m, page("c", Some(1), vec![], false), &o, 3);
    assert_eq!(opened(&older), Some(false));
    // The refetch after another device's run_started.
    assert_eq!(history_sends(&run_started(&mut m, &o, 4)), [None]);
    let refetch = live(&mut m, page("c", None, span(1, 3), false), &o, 5);
    assert_eq!(opened(&refetch), Some(false));
    // The session-start refetch.
    m.step(Event::SessionLost, &o, 6);
    m.step(Event::SessionOpened, &o, 7);
    live(&mut m, list(&["c"]), &o, 8);
    let restart = live(&mut m, page("c", None, span(1, 3), false), &o, 9);
    assert_eq!(opened(&restart), Some(false));
    // Opening it again.
    m.step(Event::Open(None), &o, 10);
    m.step(Event::Open(Some("c".into())), &o, 11);
    let reopened = live(&mut m, page("c", None, span(1, 3), false), &o, 12);
    assert_eq!(opened(&reopened), Some(true));
}
#[test]
fn newest_page_drops_a_queued_older_request_and_answers_match_before() {
    let mut m = Machine::default();
    let o = outbox::Machine::default();
    m.step(Event::Open(Some("c".into())), &o, 0);
    m.step(Event::SessionOpened, &o, 0);
    live(&mut m, list(&["c"]), &o, 1);
    live(&mut m, page("c", None, span(121, 180), true), &o, 2);
    assert_eq!(
        history_sends(&m.step(Event::Older("c".into()), &o, 3)),
        [Some(121)]
    );
    // An answer to a different `before` (a late one, after the 30 s release) is not applied.
    let stray = live(&mut m, page("c", Some(999), span(5, 5), false), &o, 4);
    assert!(stray.is_empty());
    let stray = live(&mut m, page("c", None, span(5, 5), false), &o, 4);
    assert!(stray.is_empty());
    assert_eq!(m.open.as_ref().unwrap().items.len(), 60);
    live(&mut m, page("c", Some(121), span(61, 120), true), &o, 5);
    assert_eq!(m.open.as_ref().unwrap().items.len(), 120);
    // A newest fetch is in flight when the user asks for older items: `before: 61` is queued.
    assert_eq!(history_sends(&run_started(&mut m, &o, 6)), [None]);
    assert!(m.step(Event::Older("c".into()), &o, 7).is_empty());
    // The newest page replaces the held items with 121-180, so `before: 61` would leave a hole.
    let effects = live(&mut m, page("c", None, span(121, 180), true), &o, 8);
    assert!(history_sends(&effects).is_empty());
    let open = m.open.as_ref().unwrap();
    assert_eq!(open.items.len(), 60);
    assert!(open.older_more);
    assert_eq!(
        history_sends(&m.step(Event::Older("c".into()), &o, 9)),
        [Some(121)]
    );
}
#[test]
fn history_request_wire_shape_and_retried_item_removal() {
    let mut m = Machine::default();
    let o = outbox::Machine::default();
    m.step(Event::SessionOpened, &o, 0);
    live(&mut m, list(&[]), &o, 1);
    let effects = m.step(Event::Open(Some("c".into())), &o, 2);
    let Some(Effect::Send(request)) = effects.first() else {
        panic!("no history request");
    };
    assert_eq!(
        serde_json::to_value(request).unwrap(),
        serde_json::json!({"kind":"history","data":{"convId":"c"}})
    );
    for id in ["old", "kept"] {
        m.step(
            Event::Outgoing(Message {
                conv_id: "c".into(),
                message_id: id.into(),
                text: "text".into(),
            }),
            &o,
            3,
        );
    }
    m.step(Event::Retried("old".into()), &o, 4);
    let open = m.open.as_ref().unwrap();
    let ids: Vec<_> = open.items.iter().map(|i| i.id.as_str()).collect();
    assert_eq!(ids, ["kept"]);
}
