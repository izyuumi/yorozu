use yorozu_core::{
    events::ReadCursor,
    reads::{Event, Machine},
};
fn cursor(ts: i64) -> ReadCursor {
    ReadCursor {
        conv_id: "c".into(),
        message_id: "a".into(),
        ts,
        unread: false,
    }
}
#[test]
fn open_focused_reply_and_unanswered_resend() {
    let mut m = Machine::default();
    assert!(m.step(Event::Reply(cursor(1))).is_empty());
    assert!(m.step(Event::Opened(cursor(2))).is_empty());
    assert_eq!(m.step(Event::SessionOpened), vec![cursor(2)]);
    m.step(Event::Answer(cursor(1)));
    m.step(Event::SessionLost);
    assert_eq!(m.step(Event::SessionOpened), vec![cursor(2)]);
    m.step(Event::Answer(cursor(2)));
    m.step(Event::SessionLost);
    assert!(m.step(Event::SessionOpened).is_empty());
    m.step(Event::Focus(true));
    assert_eq!(m.step(Event::Reply(cursor(3))), vec![cursor(3)]);
    m.step(Event::Focus(false));
    assert!(m.step(Event::Reply(cursor(4))).is_empty());
    m.step(Event::SessionLost);
    assert_eq!(m.step(Event::SessionOpened), vec![cursor(3)]);
}
