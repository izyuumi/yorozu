use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerInfo {
    pub protocol_min: i64,
    pub protocol_max: i64,
    pub app: String,
    pub name: Option<String>,
    pub capabilities: Vec<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorInfo {
    pub code: String,
    pub message: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "data", rename_all = "snake_case")]
pub enum Envelope {
    PeerInfo(PeerInfo),
    Error(ErrorInfo),
    #[serde(rename = "error")]
    MessageError(ChatError),
    Message(Message),
    Reply(Reply),
    Delivered(MessageRef),
    RunStarted(MessageRef),
    Typing(Typing),
    Tool(Tool),
    ConvList(ConvList),
    History(History),
    ConvUpdate(crate::model::Conversation),
    ReadCursor(ReadCursor),
    #[serde(other)]
    Unknown,
}
impl PeerInfo {
    pub fn client(name: &str) -> Self {
        Self {
            protocol_min: 3,
            protocol_max: 3,
            app: crate::VERSION.into(),
            name: Some(if name.is_empty() {
                "Windows PC".into()
            } else {
                name.chars().take(64).collect()
            }),
            capabilities: vec!["unversioned-wire".into()],
        }
    }
    pub fn compatible(&self) -> bool {
        self.protocol_min >= -(crate::frame::MAX_COUNTER as i64)
            && self.protocol_max <= crate::frame::MAX_COUNTER as i64
            && self.protocol_min <= 3
            && self.protocol_max >= 3
    }
}

impl Envelope {
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let value: serde_json::Value = serde_json::from_slice(bytes).ok()?;
        let object = value.as_object()?;
        let kind = object.get("kind")?.as_str()?;
        if !matches!(
            kind,
            "peer_info"
                | "error"
                | "message"
                | "reply"
                | "delivered"
                | "run_started"
                | "typing"
                | "tool"
                | "conv_list"
                | "history"
                | "conv_update"
                | "read_cursor"
        ) {
            return Some(Self::Unknown);
        }
        let data = object.get("data")?.as_object()?;
        if kind == "peer_info" {
            for key in ["protocolMin", "protocolMax"] {
                let n = data.get(key)?.as_i64()?;
                if n.unsigned_abs() > crate::frame::MAX_COUNTER {
                    return None;
                }
            }
            if data.get("name").is_some_and(|v| !v.is_string())
                || data
                    .get("mediaMaxBytes")
                    .is_some_and(|v| v.as_u64().is_none_or(|n| n > crate::frame::MAX_COUNTER))
            {
                return None;
            }
            Some(Self::PeerInfo(
                serde_json::from_value(object.get("data")?.clone()).ok()?,
            ))
        } else if kind == "error" {
            for key in ["convId", "messageId", "attachmentId"] {
                if data.get(key).is_some_and(|v| !v.is_string()) {
                    return None;
                }
            }
            if data.contains_key("messageId") {
                Some(Self::MessageError(
                    serde_json::from_value(object.get("data")?.clone()).ok()?,
                ))
            } else {
                Some(Self::Error(
                    serde_json::from_value(object.get("data")?.clone()).ok()?,
                ))
            }
        } else {
            for key in ["convId", "messageId"] {
                if let Some(v) = data.get(key) {
                    if !v.as_str().is_some_and(crate::model::valid_id) {
                        return None;
                    }
                }
            }
            if ["ts", "before", "after"]
                .iter()
                .filter_map(|key| data.get(*key))
                .any(|v| {
                    v.as_i64()
                        .is_none_or(|n| n.unsigned_abs() > crate::frame::MAX_COUNTER)
                })
            {
                return None;
            }
            let d = object.get("data")?.clone();
            match kind {
                "message" => serde_json::from_value(d).ok().map(Self::Message),
                "reply" => serde_json::from_value(d).ok().map(Self::Reply),
                "delivered" => serde_json::from_value(d).ok().map(Self::Delivered),
                "run_started" => serde_json::from_value(d).ok().map(Self::RunStarted),
                "typing" => serde_json::from_value(d).ok().map(Self::Typing),
                "tool" => serde_json::from_value(d).ok().map(Self::Tool),
                "conv_list" => {
                    let raw = d
                        .get("conversations")
                        .and_then(|v| v.as_array())
                        .map_or(0, Vec::len);
                    let list: ConvList = serde_json::from_value(d).ok()?;
                    Some(Self::ConvList(ConvList { raw, ..list }))
                }
                "history" => serde_json::from_value(d).ok().map(Self::History),
                "conv_update" => serde_json::from_value(d).ok().map(Self::ConvUpdate),
                "read_cursor" => serde_json::from_value(d).ok().map(Self::ReadCursor),
                _ => None,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn envelope_matches_plugin_shape_and_validation() {
        let peer = Envelope::PeerInfo(PeerInfo::client(&"語".repeat(65)));
        let value = serde_json::to_value(&peer).unwrap();
        assert_eq!(
            value,
            json!({"kind":"peer_info","data":{"protocolMin":3,"protocolMax":3,"app":crate::VERSION,"name":"語".repeat(64),"capabilities":["unversioned-wire"]}})
        );
        assert_eq!(
            Envelope::decode(&serde_json::to_vec(&value).unwrap()),
            Some(peer)
        );
        for (key, bad) in [
            ("protocolMin", json!(9007199254740992u64)),
            ("protocolMax", json!(3.5)),
            ("name", json!(null)),
            ("capabilities", json!([1])),
            ("mediaMaxBytes", json!(-1)),
        ] {
            let mut bad_peer = value.clone();
            bad_peer["data"][key] = bad;
            assert_eq!(
                Envelope::decode(&serde_json::to_vec(&bad_peer).unwrap()),
                None
            );
        }
        assert_eq!(
            Envelope::decode(br#"{"kind":"peer_info","data":[3,3,"host",null,[]]}"#),
            None
        );
        assert_eq!(
            Envelope::decode(br#"{"kind":"future","data":{"anything":true}}"#),
            Some(Envelope::Unknown)
        );
        assert_eq!(Envelope::decode(br#"{"kind":"error","data":{"code":"update_required","message":"update","extra":1}}"#),Some(Envelope::Error(ErrorInfo {code:"update_required".into(),message:"update".into()})));
        assert_eq!(PeerInfo::client("").name.as_deref(), Some("Windows PC"));
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageRef {
    pub conv_id: String,
    pub message_id: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub conv_id: String,
    pub message_id: String,
    pub text: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub conv_id: String,
    pub message_id: String,
    pub text: String,
    pub ts: i64,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Typing {
    pub conv_id: String,
    pub active: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tool {
    pub conv_id: String,
    pub message_id: String,
    #[serde(flatten)]
    pub call: crate::model::ToolCall,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConvList {
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "conversations"
    )]
    pub conversations: Option<Vec<crate::model::Conversation>>,
    /// Rows the answer carried before invalid ones were dropped; the 2,000-row cap counts these.
    #[serde(skip)]
    pub raw: usize,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct History {
    pub conv_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub before: Option<i64>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "history_items"
    )]
    pub items: Option<Vec<crate::model::Item>>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub more: bool,
}
fn conversations<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<Vec<crate::model::Conversation>>, D::Error> {
    let values = Vec::<serde_json::Value>::deserialize(d)?;
    Ok(Some(
        values
            .into_iter()
            .filter_map(|v| {
                let at = v.get("updatedAt")?.as_i64()?;
                let c: crate::model::Conversation = serde_json::from_value(v).ok()?;
                (crate::model::valid_id(&c.conv_id)
                    && at.unsigned_abs() <= crate::frame::MAX_COUNTER)
                    .then_some(c)
            })
            .collect(),
    ))
}
fn history_items<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<Vec<crate::model::Item>>, D::Error> {
    let values = Vec::<serde_json::Value>::deserialize(d)?;
    Ok(Some(
        values
            .into_iter()
            .filter_map(|v| {
                let mut item: crate::model::Item = serde_json::from_value(v).ok()?;
                if !matches!(item.kind.as_str(), "user" | "agent" | "tools" | "reset")
                    || !crate::model::valid_id(&item.id)
                    || item
                        .seq
                        .is_none_or(|n| n.unsigned_abs() > crate::frame::MAX_COUNTER)
                    || item.ts.unsigned_abs() > crate::frame::MAX_COUNTER
                {
                    return None;
                }
                item.tools.retain(crate::model::ToolCall::known);
                Some(item)
            })
            .collect(),
    ))
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadCursor {
    pub conv_id: String,
    pub message_id: String,
    pub ts: i64,
    pub unread: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatError {
    #[serde(rename = "convId", skip_serializing_if = "Option::is_none")]
    pub conv_id: Option<String>,
    #[serde(rename = "messageId", skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    pub code: String,
    pub message: String,
}
