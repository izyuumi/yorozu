pub const S1: &str = "Pair with this host? It keeps up to 16 devices; if it has 16, the one paired longest ago is removed.";
pub const S2: &str = "This isn't a Yorozu pairing link.";
pub const S3: &str = "This link can't pair a new device.";
pub const S4: &str = "This pairing link has expired or was already used. Make a new one with `openclaw yorozu pair`.";
pub const S5: &str =
    "The host refused this pairing link. Make a new one with `openclaw yorozu pair`.";
pub const S6: &str =
    "Your host's Yorozu plugin doesn't speak this app's protocol. Update it, then pair again.";
pub const S7: &str = "Pairing cancelled. If the host already accepted this PC, it stays listed until you remove it from another device.";
pub const S8: &str = "This PC was removed from your host.";
pub const S9: &str =
    "Update required: your host's Yorozu plugin doesn't speak this app's protocol.";
pub const S10: &str = "This PC is still listed on your host. Remove it in Settings › Devices on another device, or with `openclaw yorozu devices remove`.";
pub const S11: &str = "Forget this pairing first.";
pub const S12: &str =
    "This PC's pairing can't be read (for example after a Windows password reset).";
pub const S13: &str = "Couldn't save this pairing on this PC.";
use crate::{
    connection::Terminal,
    link::{Link, LinkError},
    store::Loaded,
};
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Removed {
    Revoked,
    Unreadable,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    Unpaired,
    Confirming(Link),
    Pairing,
    Paired,
    Removed(Removed),
}
impl State {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Unpaired => "Unpaired",
            Self::Confirming(_) => "Confirming",
            Self::Pairing => "Pairing",
            Self::Paired => "Paired",
            Self::Removed(_) => "Removed",
        }
    }
}
#[derive(Clone, Debug)]
pub enum Event {
    LinkSubmitted(String),
    Confirm,
    Cancel,
    SessionOpened(u64),
    Terminal(Terminal),
    Forget,
    PairAgain,
    Joined,
    Launch(Loaded),
    SaveFailed { initial: bool },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    Create(Link),
    Start,
    Stop,
    Wipe,
    PersistKnown,
    PersistPaired(u64),
    Notice(&'static str),
}
pub fn step(state: State, event: Event) -> (State, Vec<Effect>) {
    use Effect as F;
    use Event as E;
    use State as S;
    match (state, event) {
        (S::Unpaired, E::LinkSubmitted(text)) => match Link::parse(&text) {
            Ok(link) => (S::Confirming(link), vec![]),
            Err(LinkError::Invalid) => (S::Unpaired, vec![F::Notice(S2)]),
            Err(LinkError::Unusable) => (S::Unpaired, vec![F::Notice(S3)]),
        },
        (S::Confirming(link), E::Confirm) => (S::Pairing, vec![F::Create(link)]),
        (S::Confirming(_), E::Cancel) => (S::Unpaired, vec![]),
        (S::Pairing, E::SessionOpened(now)) => (S::Paired, vec![F::PersistPaired(now)]),
        (S::Pairing, E::Terminal(reason)) => (
            S::Unpaired,
            vec![
                F::Stop,
                F::Wipe,
                F::Notice(match reason {
                    Terminal::PairingFailed => S4,
                    Terminal::Revoked => S5,
                    Terminal::UpdateRequired => S6,
                }),
            ],
        ),
        (S::Pairing, E::Cancel) => (S::Unpaired, vec![F::Stop, F::Wipe, F::Notice(S7)]),
        (S::Paired, E::Terminal(Terminal::Revoked | Terminal::PairingFailed)) => {
            (S::Removed(Removed::Revoked), vec![F::Stop, F::Wipe])
        }
        (S::Paired, E::Terminal(Terminal::UpdateRequired)) => (S::Paired, vec![]),
        (S::Paired, E::Forget) => (S::Unpaired, vec![F::Stop, F::Wipe, F::Notice(S10)]),
        (S::Removed(_), E::PairAgain) => (S::Unpaired, vec![F::Wipe]),
        (s @ (S::Paired | S::Pairing | S::Removed(_)), E::LinkSubmitted(_)) => {
            (s, vec![F::Notice(S11)])
        }
        (s @ (S::Pairing | S::Paired), E::Joined) => (s, vec![F::PersistKnown]),
        (_, E::Launch(Loaded::Missing)) => (S::Unpaired, vec![]),
        (_, E::Launch(Loaded::Unreadable)) => (S::Removed(Removed::Unreadable), vec![]),
        (_, E::Launch(Loaded::Pairing(record))) => (
            if record.secret.is_some() {
                S::Pairing
            } else {
                S::Paired
            },
            vec![F::Start],
        ),
        (_, E::SaveFailed { initial: true }) => (S::Unpaired, vec![F::Notice(S13)]),
        (s, E::SaveFailed { initial: false }) => (s, vec![F::Notice(S13)]),
        (s, _) => (s, vec![]),
    }
}
