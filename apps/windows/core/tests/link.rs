use yorozu_core::{
    frame::b64,
    link::{Link, LinkError},
};
fn link() -> String {
    format!(
        "yorozu://pair?v=3&relay=wss://relay.test&key={}&room={}&token=AQ&secret=Ag",
        b64([1; 32]),
        b64([2; 32])
    )
}
#[test]
fn supported_forms_fingerprint_and_loopback() {
    let text = link();
    let parsed = Link::parse(&format!(" \n{text}\t")).unwrap();
    assert_eq!(parsed.fingerprint(), "0101 0101 0101 0101");
    assert_eq!(parsed.relay_host(), "relay.test");
    let mut key = [0; 32];
    key[..8].copy_from_slice(&[0xee, 0xd8, 0x92, 0xa4, 0xb3, 0x3e, 0x5e, 0xc2]);
    assert_eq!(
        Link::parse(&text.replace(&b64([1; 32]), &b64(key)))
            .unwrap()
            .fingerprint(),
        "EED8 92A4 B33E 5EC2"
    );
    assert_eq!(
        Link::parse(&text.replace("yorozu://pair?", "https://yorozu.yumi.to/pair#")).unwrap(),
        parsed
    );
    assert!(Link::parse(&text.replace("v=3&", "")).is_ok());
    for host in ["localhost", "127.0.0.1", "[::1]"] {
        assert!(
            Link::parse(&text.replace("wss://relay.test", &format!("ws://{host}:1234"))).is_ok()
        );
    }
    assert!(Link::parse(&(text + "&port=no&lan=no&ts=no")).is_ok());
}
#[test]
fn every_invalid_or_unusable_branch() {
    let good = link();
    for bad in [
        "junk".into(),
        "yorozu://pair".into(),
        "https://yorozu.yumi.to/pair".into(),
        format!("{good}#extra"),
        format!("{good}&v=3"),
        good.replace(&b64([1; 32]), &b64([1; 31])),
        good.replace(&b64([2; 32]), &"!".repeat(43)),
        good.replace("token=AQ", "token="),
        good.replace("secret=Ag", "secret="),
        good.replace("wss://relay.test", "wss://"),
        good.replace("yorozu:", "ftp:"),
        good.replace("//pair?", "//other?"),
        good.replace("//pair?", "//pair/path?"),
        good.replace("wss://relay.test", "%GG"),
        good.replace("key=", "no="),
        good.replace("token=AQ", "token=A!"),
        good.replace("key=", "key=+"),
        good.replace("room=", "room=x"),
        good.replace("secret=Ag", "secret=bad="),
        good.replace("&relay=", "&no="),
        good.replace("&room=", "&no="),
        good.replace("&token=", "&no="),
        good.replace("wss://relay.test", "no-url"),
        good.replace("yorozu://pair?", "https://evil.test/pair#"),
        good.replace("yorozu://pair?", "https://yorozu.yumi.to/other#"),
    ] {
        assert_eq!(Link::parse(&bad), Err(LinkError::Invalid), "{bad}");
    }
    for bad in [
        good.replace("v=3", "v=4"),
        good.replace("v=3", "v="),
        good.replace("wss://relay.test", "ws://127.0.0.2"),
        good.replace("wss://relay.test", "wss://relay.test%23fragment"),
        good.replace("&secret=Ag", ""),
        good.replace("wss://relay.test", "ws://remote.test"),
        good.replace("wss://relay.test", "https://relay.test"),
        good.replace("wss://relay.test", "wss://user:pass@relay.test"),
    ] {
        assert_eq!(Link::parse(&bad), Err(LinkError::Unusable), "{bad}");
    }
}
