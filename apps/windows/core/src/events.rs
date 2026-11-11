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
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "data", rename_all = "snake_case")]
pub enum Envelope {
    PeerInfo(PeerInfo),
    Error(ErrorInfo),
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
        if !matches!(kind, "peer_info" | "error") {
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
                serde_json::from_value(object["data"].clone()).ok()?,
            ))
        } else {
            for key in ["convId", "messageId", "attachmentId"] {
                if data.get(key).is_some_and(|v| !v.is_string()) {
                    return None;
                }
            }
            Some(Self::Error(
                serde_json::from_value(object["data"].clone()).ok()?,
            ))
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
            json!({"kind":"peer_info","data":{"protocolMin":3,"protocolMax":3,"app":"0.1.0","name":"語".repeat(64),"capabilities":["unversioned-wire"]}})
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
