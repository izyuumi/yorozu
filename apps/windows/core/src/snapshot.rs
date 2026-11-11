//! What the web view renders (spec section 3). The core owns the state; the UI only draws it.

use serde::Serialize;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub pairing: PairingView,
    pub status: Option<String>,
    pub notice: Option<Notice>,
    pub list: Vec<ConvSummary>,
    pub open: Option<OpenConv>,
    /// Not in the spec's Snapshot: the footer shows the version and the build sha.
    pub version: String,
    /// The first 7 characters of the commit CI built, or `dev` for a local build.
    pub build: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum PairingView {
    Unpaired,
}

/// The last notice, kept here so one sent before the web view listens isn't lost.
/// `seq` tells a new notice from the one before it.
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
    pub marks: Vec<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub text: String,
}

impl Snapshot {
    /// The state before any pairing: nothing paired, nothing listed, nothing open.
    pub fn initial(version: &str, build: &str) -> Self {
        Self {
            pairing: PairingView::Unpaired,
            status: None,
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
            marks: Vec::new(),
        });
        let got = serde_json::to_string(&snapshot).unwrap();
        assert!(got.contains(r#""notice":{"seq":1,"text":"n"}"#), "{got}");
        assert!(
            got.contains(r#""list":[{"convId":"c","title":"t"}]"#),
            "{got}"
        );
        let open = r#""open":{"convId":"c","items":[],"olderMore":true,"marks":[]}"#;
        assert!(got.contains(open), "{got}");
    }
}
