use yorozu_core::{
    events::{ChatError, Message, MessageRef},
    outbox::{relay_fits, Effect, Event, Machine, Mark, TOO_LONG},
};
fn message(id: &str, text: &str) -> Message {
    Message {
        conv_id: "c".into(),
        message_id: id.into(),
        text: text.into(),
    }
}
#[test]
fn marks_loss_retry_and_failed_rows_never_resend() {
    let mut m = Machine::default();
    assert!(m.step(Event::Send(message("a", "hi"))).is_empty());
    assert_eq!(m.rows[0].mark, Mark::Queued);
    assert_eq!(
        m.step(Event::SessionOpened),
        vec![Effect::Send(message("a", "hi"))]
    );
    m.step(Event::Frame {
        message_id: "a".into(),
        sig: "sig".into(),
    });
    m.step(Event::Accepted("other".into()));
    assert_eq!(m.rows[0].mark, Mark::Queued);
    m.step(Event::Accepted("sig".into()));
    assert_eq!(m.rows[0].mark, Mark::Sent);
    m.step(Event::SessionLost);
    assert_eq!(m.rows[0].mark, Mark::Queued);
    assert_eq!(m.step(Event::SessionOpened).len(), 1);
    m.step(Event::Delivered(MessageRef {
        conv_id: "c".into(),
        message_id: "a".into(),
    }));
    assert_eq!(m.rows[0].mark, Mark::Delivered);
    m.step(Event::Read(MessageRef {
        conv_id: "c".into(),
        message_id: "a".into(),
    }));
    assert_eq!(m.rows[0].mark, Mark::Read);
    m.step(Event::Send(message("b", "fail")));
    m.step(Event::Error(ChatError {
        code: "run_failed".into(),
        message: "oops".into(),
        conv_id: Some("c".into()),
        message_id: Some("b".into()),
    }));
    assert!(m.rows[1].run_failed);
    m.step(Event::Error(ChatError {
        code: "bad_request".into(),
        message: "reason".into(),
        conv_id: Some("c".into()),
        message_id: Some("b".into()),
    }));
    assert_eq!(m.rows[1].mark, Mark::Failed("reason".into()));
    m.step(Event::SessionLost);
    assert!(m.step(Event::SessionOpened).is_empty());
    assert_eq!(
        m.step(Event::Retry {
            conv_id: "c".into(),
            message_id: "b".into(),
            new_id: "d".into()
        }),
        vec![Effect::Send(message("d", "fail"))]
    );
    // Retry replaces the failed row: no row keeps the old id, so a second Retry emits nothing.
    assert_eq!(m.rows.len(), 2);
    assert_eq!(m.rows[1].message, message("d", "fail"));
    assert_eq!(m.rows[1].mark, Mark::Queued);
    assert!(!m.rows[1].run_failed);
    let again = m.step(Event::Retry {
        conv_id: "c".into(),
        message_id: "b".into(),
        new_id: "e".into(),
    });
    assert!(again.is_empty());
    assert_eq!(m.rows.len(), 2);
    m.step(Event::SessionLost);
    assert_eq!(
        m.step(Event::SessionOpened),
        vec![Effect::Send(message("d", "fail"))]
    );
}
#[test]
fn utf16_cap_empty_and_relay_byte_backstop() {
    let mut m = Machine::default();
    m.step(Event::Send(message("empty", " \n")));
    assert!(m.rows.is_empty());
    m.step(Event::Send(message("ok", &"語".repeat(60_000))));
    assert_eq!(m.rows.len(), 1);
    assert_eq!(
        m.step(Event::Send(message("bad", &"語".repeat(60_001)))),
        vec![Effect::Refused(TOO_LONG.into())]
    );
    assert_eq!(
        m.step(Event::Send(message("emoji", &"😀".repeat(30_001)))),
        vec![Effect::Refused(TOO_LONG.into())]
    );
    assert!(relay_fits(&"x".repeat(1_048_576)));
    assert!(!relay_fits(&"x".repeat(1_048_577)));
    // The driver steps RefusedFrame for a frame over the limit: the row fails and is never resent.
    m.step(Event::SessionOpened);
    m.step(Event::RefusedFrame("ok".into()));
    assert!(matches!(m.rows[0].mark, Mark::Failed(_)));
    m.step(Event::SessionLost);
    assert!(m.step(Event::SessionOpened).is_empty());
}
