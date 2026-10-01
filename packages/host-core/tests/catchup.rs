use serde_json::{Value, json};
use yorozu_host_core::catchup::Catchup;
fn event(id: &str) -> Value {
    json!({"id":id,"threadId":"thread","kind":"message","data":{"role":"agent","text":id}})
}
fn replace(queue: &mut Catchup, pubkey: &str, generation: &str) -> Value {
    queue.request(&json!({"op":"catchup_replace","pub":pubkey,"generation":generation,"connection":"connection","events":[event(generation)]}))
}
#[test]
fn job_and_encoded_byte_limits_are_explicit_without_releasing_old_claim_currency() {
    let mut queue = Catchup::default();
    for n in 0..32 {
        assert_eq!(
            replace(&mut queue, &format!("pub-{n}"), "old")["stored"],
            true
        );
    }
    assert!(
        replace(&mut queue, "overflow", "new")
            .get("error")
            .is_some()
    );
    assert_eq!(replace(&mut queue, "pub-0", "replacement")["stored"], true);
    assert!(queue.request(&json!({"op":"catchup_replace","pub":"pub-0","generation":"oversized","connection":"connection","events":[event(&"x".repeat(32 * 1024 * 1024))]})).get("error").is_some());
    let eligible: Vec<_> = (0..32)
        .map(
            |n| json!({"pub":format!("pub-{n}"),"generation":if n==0 {"replacement"} else {"old"}}),
        )
        .collect();
    let first=queue.request(&json!({"op":"catchup_next","connection":"connection","eligible":eligible,"writable":true,"bufferedBytes":0}));
    assert_eq!(first["pub"], "pub-1");
    assert!(queue.request(&json!({"op":"catchup_finish","claim":first["claim"],"pub":first["pub"],"generation":"replacement","sent":true})).get("error").is_some());
    assert_eq!(queue.request(&json!({"op":"catchup_finish","claim":first["claim"],"pub":first["pub"],"generation":first["generation"],"sent":false}))["stored"], true);
    assert_eq!(
        queue.request(&json!({"op":"catchup_clear"}))["stored"],
        true
    );
    assert_eq!(queue.request(&json!({"op":"catchup_next","connection":"connection","eligible":[],"writable":true,"bufferedBytes":0}))["remaining"], false);
}
