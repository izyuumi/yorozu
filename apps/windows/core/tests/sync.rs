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
fn page(c: &str, items: Vec<Item>, more: bool) -> Envelope {
    Envelope::History(History {
        conv_id: c.into(),
        before: None,
        items: Some(items),
        more,
    })
}
fn list(ids: &[&str]) -> Envelope {
    Envelope::ConvList(ConvList {
        conversations: Some(ids.iter().map(|c| conv(c)).collect()),
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
        }),
        &o,
        4,
    );
    assert!(m.list.iter().any(|c| c.conv_id == "capped"));
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
    live(&mut m, page("c", vec![item("old", Some(10))], true), &o, 3);
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
        page("c", vec![item("older", Some(1))], false),
        &o,
        5,
    );
    assert!(!m.open.as_ref().unwrap().older_more);
    assert_eq!(m.open.as_ref().unwrap().items[0].id, "older");
    m.step(Event::SessionLost, &o, 6);
    m.step(Event::SessionOpened, &o, 7);
    live(&mut m, list(&["c"]), &o, 8);
    live(&mut m, page("c", vec![], false), &o, 9);
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
    assert!(live(&mut m, page("c", vec![], false), &o, 1).is_empty());
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
        page("d", vec![item("late", Some(1))], false),
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
        live(&mut m, page("c", vec![], false), &o, 3).last(),
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
    m.step(Event::Tick, &o, 30_004);
    assert!(m.open.as_ref().unwrap().typing_until.is_none());
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
