//! Platform-neutral core for the Yorozu Windows client.
//!
//! The wire, pairing and state machines land here in W1 and later.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    use super::VERSION;

    #[test]
    fn version_is_the_workspace_version() {
        assert_eq!(VERSION, "0.1.0");
    }
}
