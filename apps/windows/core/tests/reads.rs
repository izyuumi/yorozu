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
    // Sent on open: the session is open and the window is not focused.
    assert_eq!(m.step(Event::Opened(cursor(3))), vec![cursor(3)]);
    assert!(m.step(Event::Opened(cursor(3))).is_empty());
    m.step(Event::Answer(cursor(3)));
    m.step(Event::Focus(true));
    assert_eq!(m.step(Event::Reply(cursor(4))), vec![cursor(4)]);
    m.step(Event::Focus(false));
    assert!(m.step(Event::Reply(cursor(5))).is_empty());
    m.step(Event::SessionLost);
    assert_eq!(m.step(Event::SessionOpened), vec![cursor(4)]);
}
#[test]
fn reset_forgets_cursors_and_session_but_keeps_focus() {
    let mut m = Machine::default();
    m.step(Event::Focus(true));
    m.step(Event::SessionOpened);
    let before = ReadCursor {
        conv_id: "x".into(),
        ..cursor(1)
    };
    assert_eq!(m.step(Event::Reply(before.clone())), vec![before]);
    m.reset();
    assert!(m.step(Event::Opened(cursor(2))).is_empty());
    assert_eq!(m.step(Event::SessionOpened), vec![cursor(2)]);
    assert_eq!(m.step(Event::Reply(cursor(3))), vec![cursor(3)]);
}
