//! Platform-neutral core for the Yorozu Windows client.
//!
//! The wire, pairing and state machines land here from W2 on.

mod snapshot;

pub use snapshot::{ConvSummary, Item, Notice, OpenConv, PairingView, Snapshot};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
