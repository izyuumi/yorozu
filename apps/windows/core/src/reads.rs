//! Pure pending read cursors; acknowledgements are cumulative by conversation.
use crate::events::ReadCursor;
#[derive(Default)]
pub struct Machine {
    pending: Vec<ReadCursor>,
    open: bool,
    focused: bool,
}
pub enum Event {
    Opened(ReadCursor),
    Reply(ReadCursor),
    Answer(ReadCursor),
    SessionOpened,
    SessionLost,
    Focus(bool),
}
impl Machine {
    /// Forgets the pairing's cursors and session; the window's focus outlives a pairing.
    pub fn reset(&mut self) {
        *self = Self {
            focused: self.focused,
            ..Self::default()
        };
    }
    pub fn step(&mut self, event: Event) -> Vec<ReadCursor> {
        match event {
            Event::SessionOpened => {
                self.open = true;
                self.pending.clone()
            }
            Event::SessionLost => {
                self.open = false;
                vec![]
            }
            Event::Focus(focused) => {
                self.focused = focused;
                vec![]
            }
            Event::Answer(cursor) => {
                self.pending
                    .retain(|c| c.conv_id != cursor.conv_id || c.ts > cursor.ts);
                vec![]
            }
            Event::Reply(_) if !self.focused => vec![],
            Event::Opened(cursor) | Event::Reply(cursor) => {
                if self
                    .pending
                    .iter()
                    .any(|c| c.conv_id == cursor.conv_id && c.ts >= cursor.ts)
                {
                    return vec![];
                }
                self.pending.retain(|c| c.conv_id != cursor.conv_id);
                self.pending.push(cursor.clone());
                if self.open {
                    vec![cursor]
                } else {
                    vec![]
                }
            }
        }
    }
}
