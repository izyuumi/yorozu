use serde::Serialize;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub pairing: PairingView,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_code: Option<DeviceCodeView>,
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_close: Option<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub update_required: bool,
    pub notice: Option<Notice>,
    pub list: Vec<ConvSummary>,
    pub open: Option<OpenConv>,
    pub version: String,
    pub build: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct DeviceCodeView {
    pub link: String,
    pub expires_at: u64,
}

#[derive(Serialize, Clone, Debug)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum PairingView {
    Unpaired,
    Confirming {
        fingerprint: String,
        #[serde(rename = "relayHost")]
        relay_host: String,
    },
    Pairing,
    Paired,
    Removed {
        reason: String,
    },
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Notice {
    pub seq: u64,
    pub text: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ConvSummary {
    pub conv_id: String,
    pub title: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct OpenConv {
    pub conv_id: String,
    pub items: Vec<Item>,
    pub older_more: bool,
    pub title: String,
    pub typing: bool,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub text: String,
    pub kind: String,
    pub tools: Vec<crate::model::ToolCall>,
    pub mark: Option<crate::outbox::Mark>,
    pub run_failed: bool,
}

impl Snapshot {
    pub fn initial(version: &str, build: &str) -> Self {
        Self {
            pairing: PairingView::Unpaired,
            device_code: None,
            status: None,
            last_close: None,
            update_required: false,
            notice: None,
            list: Vec::new(),
            open: None,
            version: version.to_owned(),
            build: build.to_owned(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_snapshot_json() {
        let got = serde_json::to_string(&Snapshot::initial("0.1.0", "abc1234")).unwrap();
        let want = concat!(
            r#"{"pairing":{"state":"unpaired"},"status":null,"notice":null,"#,
            r#""list":[],"open":null,"version":"0.1.0","build":"abc1234"}"#,
        );
        assert_eq!(got, want);
    }

    #[test]
    fn nested_keys_are_camel_case() {
        let mut snapshot = Snapshot::initial("0.1.0", "dev");
        snapshot.notice = Some(Notice {
            seq: 1,
            text: "n".to_owned(),
        });
        snapshot.list.push(ConvSummary {
            conv_id: "c".to_owned(),
            title: "t".to_owned(),
        });
        snapshot.open = Some(OpenConv {
            conv_id: "c".to_owned(),
            items: Vec::new(),
            older_more: true,
            title: "t".into(),
            typing: false,
        });
        let got = serde_json::to_string(&snapshot).unwrap();
        assert!(got.contains(r#""notice":{"seq":1,"text":"n"}"#), "{got}");
        assert!(
            got.contains(r#""list":[{"convId":"c","title":"t"}]"#),
            "{got}"
        );
        let open =
            r#""open":{"convId":"c","items":[],"olderMore":true,"title":"t","typing":false}"#;
        assert!(got.contains(open), "{got}");
    }
}
