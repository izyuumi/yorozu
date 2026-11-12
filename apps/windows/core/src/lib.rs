//! Platform-neutral core for the Yorozu Windows client.
//!
//! Relay wire, pairing and connection machines; the driver keeps keys out of the UI.

mod snapshot;

pub use snapshot::{ConvSummary, Item, Notice, OpenConv, PairingView, Snapshot};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub mod connection;
pub mod driver;
pub mod events;
pub mod flow;
pub mod frame;
pub mod link;
pub mod pairing;
pub mod platform;
pub mod status;
pub mod store;
pub mod wire;

pub mod model;
pub mod outbox;
pub mod reads;
pub mod sync;
