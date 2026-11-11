use crate::{
    connection::{Machine, State, Terminal},
    pairing::S9,
};
pub fn text(m: &Machine) -> Option<String> {
    match m.state {
        State::Dialing | State::AwaitNonce | State::Joining | State::Backoff => Some("Connecting…".into()),
        State::Joined => Some("Your host is offline.".into()),
        State::Handshaking { .. } if m.inits >= 3 => Some("Your host isn't answering. Check that its Yorozu plugin is up to date and that this PC's clock is right.".into()),
        State::Handshaking { .. } => Some("Connecting to your host…".into()),
        State::Idle(Some(Terminal::UpdateRequired)) => Some(S9.into()),
        _ => None,
    }
}
