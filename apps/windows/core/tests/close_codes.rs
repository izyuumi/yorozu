use yorozu_core::{
    connection::{close_outcome, Terminal},
    store::Standing,
};
#[test]
fn close_table() {
    use Standing::*;
    use Terminal::*;
    for standing in [CodeOnly, Known] {
        for (code, reason, expected) in [
            (4001, "revoked", Some(Revoked)),
            (
                4001,
                "unknown device",
                Some(if standing == Known {
                    Revoked
                } else {
                    PairingFailed
                }),
            ),
            (4001, "unknown token", Some(PairingFailed)),
            (4001, "expired token", Some(PairingFailed)),
            (4011, "host offline", None),
            (4010, "", None),
            (1008, "", None),
            (1009, "", None),
            (1013, "slow receiver", None),
            (4003, "", None),
            (4029, "", None),
            (4001, "wrong room", None),
        ] {
            assert_eq!(close_outcome(code, reason, standing), expected);
        }
    }
}
