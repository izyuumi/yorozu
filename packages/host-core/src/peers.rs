//! Authenticated peer capability negotiation, independent of display version strings.
use serde_json::{Value, json};
const CAPABILITIES: &[&str] = &[
    "peer-info",
    "host-name",
    "channel-sequence",
    "admission-status-v1",
    "admission-expiry-v1",
    "exact-stop-v1",
    "turn-state-v1",
    "steer-v1",
    "model-select-v1",
    "thread-rewind-v1",
    "offline-approval-v1",
    "thread-search-v1",
    "attachment-chunks-v1",
    "reply-context-v1",
    "update-drain-v1",
    "open-agents-v1",
];
const REQUIRED: &[&str] = &["channel-sequence", "exact-stop-v1", "offline-approval-v1"];
fn text(value: &Value, max: usize) -> Option<&str> {
    value.as_str().filter(|s| {
        !s.is_empty() && s.len() <= max && !s.chars().any(|c| c <= '\u{1f}' || c == '\u{7f}')
    })
}
fn capabilities(value: &Value) -> Option<Vec<&str>> {
    let items = value.as_array().filter(|items| items.len() <= 32)?;
    let mut result = Vec::new();
    for item in items {
        let capability = text(item, 48)?;
        if !capability.as_bytes()[0].is_ascii_lowercase()
            || !capability
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            || result.contains(&capability)
        {
            return None;
        }
        result.push(capability);
    }
    Some(result)
}
fn version(value: &Value) -> Option<u16> {
    value
        .as_f64()
        .filter(|n| n.fract() == 0.0 && (1.0..=65_535.0).contains(n))
        .map(|n| n as u16)
}
pub fn host_info(app_version: &Value, computer_name: &Value) -> Value {
    let mut result = json!({"appVersion":text(app_version,64).unwrap_or("unknown"),"protocolMin":1,"protocolMax":1,"capabilities":CAPABILITIES,"requiredCapabilities":REQUIRED});
    if let Some(name) = text(computer_name, 256) {
        result["computerName"] = json!(name);
    }
    result
}
fn parse(value: &Value) -> Option<Value> {
    let object = value.as_object()?;
    let app_version = text(&value["appVersion"], 64)?;
    let min = version(&value["protocolMin"])?;
    let max = version(&value["protocolMax"])?;
    let supported = capabilities(&value["capabilities"])?;
    let required = capabilities(&value["requiredCapabilities"])?;
    if min > max || required.iter().any(|item| !supported.contains(item)) {
        return None;
    }
    let mut result = json!({"appVersion":app_version,"protocolMin":min,"protocolMax":max,"capabilities":supported,"requiredCapabilities":required});
    if object.contains_key("computerName") {
        result["computerName"] = json!(text(&value["computerName"], 256)?);
    }
    Some(result)
}
fn incompatible(reason: &str) -> Value {
    json!({"state":"update-required","reason":reason})
}
fn negotiate(peer: &Value) -> Value {
    let min = peer["protocolMin"].as_u64().unwrap();
    let max = peer["protocolMax"].as_u64().unwrap();
    if max.min(1) < min.max(1) {
        return incompatible(
            "Update Yorozu on this device and its host Mac: protocol versions do not overlap.",
        );
    }
    let peer_caps = capabilities(&peer["capabilities"]).unwrap();
    let required = capabilities(&peer["requiredCapabilities"]).unwrap();
    if REQUIRED.iter().any(|item| !peer_caps.contains(item))
        || required.iter().any(|item| !CAPABILITIES.contains(item))
    {
        return incompatible(
            "Update Yorozu on this device and its host Mac: a required security or protocol capability is unavailable.",
        );
    }
    json!({"state":"compatible","version":1,"capabilities":CAPABILITIES.iter().filter(|item| peer_caps.contains(item)).collect::<Vec<_>>()})
}
pub fn request(request: &Value) -> Value {
    match request["op"].as_str() {
        Some("peer_host_info") => {
            json!({"info":host_info(&request["appVersion"],&request["computerName"])})
        }
        Some("peer_claim") => {
            let event = &request["event"];
            let data = &event["data"];
            let valid = event["kind"] == "thread_list"
                && event["id"]
                    .as_str()
                    .is_some_and(|id| !id.is_empty() && id.encode_utf16().count() <= 128)
                && data.is_object()
                && data.get("peerInfoSupported").is_none_or(Value::is_boolean)
                && data.get("peerInfoError").is_none()
                && data.get("peerInfoReplyTo").is_none();
            let peer = valid.then(|| parse(&data["peerInfo"])).flatten();
            json!({"compatibility":peer.as_ref().map(negotiate).unwrap_or_else(|| incompatible("Invalid peer information."))})
        }
        _ => json!({"error":"invalid-peer-request"}),
    }
}
