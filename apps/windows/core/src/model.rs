//! Memory-only chat rows shared by sync and the snapshot.
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub conv_id: String,
    #[serde(default)]
    pub updated_at: i64,
    pub title: Option<String>,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub deleted: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCall {
    pub call_id: String,
    pub name: String,
    pub status: String,
}
impl ToolCall {
    pub fn known(&self) -> bool {
        matches!(self.status.as_str(), "running" | "done" | "failed")
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    pub name: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub kind: String,
    pub id: String,
    pub seq: Option<i64>,
    pub ts: i64,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub tools: Vec<ToolCall>,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
    #[serde(skip)]
    pub arrival: u64,
    #[serde(skip)]
    pub run_failed: bool,
}
impl Item {
    pub fn live(kind: &str, id: &str, text: &str, ts: i64) -> Self {
        Self {
            kind: kind.into(),
            id: id.into(),
            seq: None,
            ts,
            text: text.into(),
            tools: vec![],
            attachments: vec![],
            arrival: 0,
            run_failed: false,
        }
    }
    pub fn same_key(&self, other: &Self) -> bool {
        self.kind == other.kind && self.id == other.id
    }
    pub fn display_text(&self) -> String {
        let mut text = self.text.clone();
        for a in &self.attachments {
            if !text.is_empty() {
                text.push_str("\n\n");
            }
            text.push_str(&format!(
                "(Attachment: {}; update Yorozu to open it.)",
                a.name
            ));
        }
        text
    }
}
pub fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
            }
        })
}
