use serde_json::json;
use yorozu_core::events::Envelope;
#[test]
fn all_chat_kinds_and_future_fields() {
    let c = "00000000-0000-4000-8000-000000000001";
    for (kind, data) in [
        ("message", json!({"convId":c,"messageId":c,"text":"hi"})),
        (
            "reply",
            json!({"convId":c,"messageId":c,"text":"hi","ts":1}),
        ),
        ("delivered", json!({"convId":c,"messageId":c})),
        ("run_started", json!({"convId":c,"messageId":c})),
        ("typing", json!({"convId":c,"active":true})),
        (
            "tool",
            json!({"convId":c,"messageId":c,"callId":"x","name":"read","status":"future"}),
        ),
        (
            "conv_list",
            json!({"conversations":[{"convId":c,"updatedAt":1,"rev":1}]}),
        ),
        (
            "history",
            json!({"convId":c,"items":[{"kind":"reset","id":c,"seq":1,"ts":1}],"more":false,"rev":1}),
        ),
        ("conv_update", json!({"convId":c,"archived":true})),
        (
            "read_cursor",
            json!({"convId":c,"messageId":c,"ts":1,"unread":false}),
        ),
        (
            "error",
            json!({"code":"bad_request","message":"reason","convId":c,"messageId":c}),
        ),
    ] {
        let mut data = data;
        data["future"] = json!(9007199254740992u64);
        let bytes = serde_json::to_vec(&json!({"kind":kind,"data":data})).unwrap();
        let event = Envelope::decode(&bytes).unwrap();
        assert_ne!(event, Envelope::Unknown, "{kind}");
        assert_eq!(serde_json::to_value(event).unwrap()["kind"], kind);
    }
    assert_eq!(
        Envelope::decode(br#"{"kind":"future","data":null}"#),
        Some(Envelope::Unknown)
    );
    let error=Envelope::decode(&serde_json::to_vec(&json!({"kind":"error","data":{"code":"bad_request","message":"reason","convId":c,"messageId":c}})).unwrap()).unwrap();
    assert!(matches!(error,Envelope::MessageError(e) if e.message_id.as_deref()==Some(c)));
    assert!(Envelope::decode(br#"{"kind":"reply","data":{"convId":2}}"#).is_none());
}
#[test]
fn history_filters_future_items_and_tool_statuses_keeps_attachments_and_shared_ids() {
    let c = "00000000-0000-4000-8000-000000000001";
    let event=Envelope::decode(&serde_json::to_vec(&json!({"kind":"history","data":{"convId":c,"more":false,"items":[
        {"kind":"future","id":c,"seq":1,"ts":1},
        {"kind":"agent","id":c,"seq":1,"ts":1,"text":"text","attachments":[{"id":c,"name":"report.txt","mime":"text/plain","size":4}]},
        {"kind":"tools","id":c,"seq":1,"ts":1,"tools":[{"callId":"ok","name":"read","status":"done"},{"callId":"future","name":"read","status":"future"}]},
        {"kind":"reset","id":"invalid","seq":1,"ts":1}
    ]}})).unwrap()).unwrap();
    let Envelope::History(h) = event else {
        panic!("history expected")
    };
    let items = h.items.unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(
        items[0].display_text(),
        "text\n\n(Attachment: report.txt; update Yorozu to open it.)"
    );
    assert_eq!(items[1].tools.len(), 1);
    assert_eq!(items[1].tools[0].call_id, "ok");
}
