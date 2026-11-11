use yorozu_core::{
    frame::Frame,
    wire::{static_public, ClientHandshake},
};
#[test]
fn published_swift_plugin_vector() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../packages/YorozuWire/Tests/YorozuWireTests/Fixtures/unversioned-wire.json");
    let fixture: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    let mut client = ClientHandshake::with_ephemeral_for_testing(
        &[3; 32],
        &[2; 32],
        &static_public(&[1; 32]),
        "wire-test-room",
        1_700_000_000_000,
        &[4; 32],
    )
    .unwrap();
    let hex = |b: &[u8]| b.iter().map(|x| format!("{x:02x}")).collect::<String>();
    assert_eq!(
        hex(&client.frame.bytes()),
        fixture["initHex"].as_str().unwrap()
    );
    let response = fixture["responseHex"].as_str().unwrap();
    let bytes: Vec<u8> = (0..response.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&response[i..i + 2], 16).unwrap())
        .collect();
    let response = Frame::from_bytes(&bytes).unwrap();
    let mut wrong_sid = response.clone();
    if let Frame::Response { sid, .. } = &mut wrong_sid {
        sid[0] ^= 1;
    }
    assert!(client.finish(&wrong_sid).is_none());
    let mut damaged = response.clone();
    if let Frame::Response { message, .. } = &mut damaged {
        let last = message.len() - 1;
        message[last] ^= 1;
    }
    assert!(client.finish(&damaged).is_none());
    let mut session = client.finish(&response).unwrap();
    // Golden boxes produced by the plugin NoiseIK/Session using the same vector inputs.
    assert_eq!(
        session.seal(b"client box").unwrap().encode(),
        "E6wBsiCehjVPAAAAAAAAAABz_AXoJMddrjqiewKKsMu__fN55zoRz1escg"
    );
    assert_eq!(
        session
            .open(
                &Frame::decode("E6wBsiCehjVPAAAAAAAAAAAkVlU9i3-lIvYRZSCadIgOO8pGomRcQQs").unwrap()
            )
            .unwrap(),
        b"host box"
    );
}
