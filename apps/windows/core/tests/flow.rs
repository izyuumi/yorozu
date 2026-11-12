use yorozu_core::flow::{on_relay_frame, Flow};
#[test]
fn forty_foreign_frames_stay_below_worker_buffer_cap() {
    let mut flow = Flow {
        enabled: true,
        ..Default::default()
    };
    for n in 1..=40 {
        let sent = n * 100 * 1024;
        on_relay_frame(&mut flow, Some(sent));
        assert!(sent - flow.last_ack < 2 * 1024 * 1024);
    }
}
#[test]
fn thresholds_decimal_and_disabled() {
    let mut flow = Flow::default();
    assert!(on_relay_frame(&mut flow, Some(262144)).is_none());
    flow.enabled = true;
    let ack = on_relay_frame(&mut flow, Some(262144)).unwrap();
    assert_eq!(
        serde_json::to_string(&ack).unwrap(),
        r#"{"type":"flowAck","bytes":"262144"}"#
    );
    // ^(0|[1-9][0-9]*)$: canonical decimal, checked without a regex dependency.
    assert!(
        ack.bytes == "0"
            || (!ack.bytes.starts_with('0') && ack.bytes.bytes().all(|c| c.is_ascii_digit()))
    );
    assert!(on_relay_frame(&mut flow, None).is_none());
    assert!(on_relay_frame(&mut flow, Some(1)).is_none());
    for n in 1..16 {
        assert!(on_relay_frame(&mut flow, Some(262144 + n)).is_none());
    }
    assert_eq!(
        on_relay_frame(&mut flow, Some(262160)).unwrap().bytes,
        "262160"
    );
}
