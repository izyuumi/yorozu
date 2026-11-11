//! Pure memory-only outbox. Frame signatures belong to one session.
use crate::events::{ChatError, Message, MessageRef};
use serde::Serialize;
pub const TOO_LONG: &str = "This message is too long. The limit is 60,000 characters.";
pub fn relay_fits(message: &str) -> bool {
    message.len() <= 1_048_576
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", content = "reason", rename_all = "snake_case")]
pub enum Mark {
    Queued,
    Sent,
    Delivered,
    Read,
    Failed(String),
}
impl Mark {
    pub fn pending(&self) -> bool {
        matches!(self, Self::Queued | Self::Sent)
    }
    pub fn name(&self) -> &str {
        match self {
            Self::Queued => "queued",
            Self::Sent => "sent",
            Self::Delivered => "delivered",
            Self::Read => "read",
            Self::Failed(_) => "failed",
        }
    }
}
#[derive(Clone, Debug)]
pub struct Row {
    pub message: Message,
    pub mark: Mark,
    pub sig: Option<String>,
    pub run_failed: bool,
}
#[derive(Default)]
pub struct Machine {
    pub rows: Vec<Row>,
    open: bool,
}
pub enum Event {
    Send(Message),
    SessionOpened,
    SessionLost,
    Frame {
        message_id: String,
        sig: String,
    },
    Accepted(String),
    Delivered(MessageRef),
    Read(MessageRef),
    Error(ChatError),
    Retry {
        conv_id: String,
        message_id: String,
        new_id: String,
    },
    RefusedFrame(String),
}
#[derive(Debug, PartialEq, Eq)]
pub enum Effect {
    Send(Message),
    Refused(String),
}
impl Machine {
    pub fn pending(&self, conv_id: &str, id: Option<&str>) -> bool {
        self.rows.iter().any(|r| {
            r.message.conv_id == conv_id
                && id.is_none_or(|id| r.message.message_id == id)
                && r.mark.pending()
        })
    }
    pub fn step(&mut self, event: Event) -> Vec<Effect> {
        match event {
            Event::Send(message) => {
                if message.text.trim().is_empty() {
                    return vec![];
                }
                if message.text.encode_utf16().count() > 60_000 {
                    return vec![Effect::Refused(TOO_LONG.into())];
                }
                self.rows.push(Row {
                    message: message.clone(),
                    mark: Mark::Queued,
                    sig: None,
                    run_failed: false,
                });
                if self.open {
                    vec![Effect::Send(message)]
                } else {
                    vec![]
                }
            }
            Event::Retry {
                conv_id,
                message_id,
                new_id,
            } => {
                // The failed row moves to the new id: a second Retry on the old id finds nothing.
                let Some(row) = self.rows.iter_mut().find(|r| {
                    r.message.conv_id == conv_id
                        && r.message.message_id == message_id
                        && matches!(r.mark, Mark::Failed(_))
                }) else {
                    return vec![];
                };
                row.message.message_id = new_id;
                row.mark = Mark::Queued;
                row.sig = None;
                row.run_failed = false;
                if self.open {
                    vec![Effect::Send(row.message.clone())]
                } else {
                    vec![]
                }
            }
            Event::SessionOpened => {
                self.open = true;
                self.rows
                    .iter()
                    .filter(|r| r.mark.pending())
                    .map(|r| Effect::Send(r.message.clone()))
                    .collect()
            }
            Event::SessionLost => {
                self.open = false;
                for row in &mut self.rows {
                    row.sig = None;
                    if row.mark == Mark::Sent {
                        row.mark = Mark::Queued;
                    }
                }
                vec![]
            }
            other => {
                for row in &mut self.rows {
                    match &other {
                        Event::Frame { message_id, sig }
                            if row.message.message_id == *message_id =>
                        {
                            row.sig = Some(sig.clone())
                        }
                        Event::Accepted(sig)
                            if self.open
                                && row.sig.as_ref() == Some(sig)
                                && row.mark == Mark::Queued =>
                        {
                            row.mark = Mark::Sent
                        }
                        Event::Delivered(r)
                            if row.message.conv_id == r.conv_id
                                && row.message.message_id == r.message_id
                                && row.mark.pending() =>
                        {
                            row.mark = Mark::Delivered
                        }
                        Event::Read(r)
                            if row.message.conv_id == r.conv_id
                                && row.message.message_id == r.message_id
                                && !matches!(row.mark, Mark::Failed(_)) =>
                        {
                            row.mark = Mark::Read
                        }
                        Event::Error(e)
                            if e.message_id.as_ref() == Some(&row.message.message_id)
                                && e.conv_id.as_ref().is_none_or(|c| c == &row.message.conv_id) =>
                        {
                            if e.code == "bad_request" {
                                row.mark = Mark::Failed(e.message.clone());
                            }
                            if e.code == "run_failed" {
                                row.run_failed = true;
                            }
                        }
                        Event::RefusedFrame(id) if row.message.message_id == *id => {
                            row.mark = Mark::Failed("Relay message exceeds 1,048,576 bytes.".into())
                        }
                        _ => {}
                    }
                }
                vec![]
            }
        }
    }
}
