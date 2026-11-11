use yorozu_core::{
    frame::{Frame, MAX_COUNTER},
    wire::Session,
};
#[test]
fn codec_boundaries() {
    for (kind, min, max) in [(0x11, 129, 65568), (0x12, 57, 65544), (0x13, 33, 1_000_000)] {
        let mut bytes = vec![0; min];
        bytes[0] = kind;
        assert!(Frame::from_bytes(&bytes).is_some());
        assert!(Frame::from_bytes(&bytes[..min - 1]).is_none());
        bytes.resize(max, 0);
        assert!(Frame::from_bytes(&bytes).is_some());
        if kind != 0x13 {
            bytes.push(0);
            assert!(Frame::from_bytes(&bytes).is_none());
        }
    }
    assert!(Frame::from_bytes(&[3; 129]).is_none());
    assert!(Frame::decode("AQ==").is_none());
    let frame = Frame::Box {
        sid: [0; 8],
        counter: MAX_COUNTER + 1,
        ciphertext: vec![0; 16],
    };
    assert!(Frame::decode(&frame.encode()).is_none());
}
#[test]
fn replay_sid_tag_and_large_box() {
    let mut sender = Session::new([1; 8], [2; 32], [3; 32]);
    let mut receiver = Session::new([1; 8], [3; 32], [2; 32]);
    let frame = sender.seal(&vec![42; 760_037]).unwrap();
    let mut bad = frame.clone();
    if let Frame::Box { ciphertext, .. } = &mut bad {
        ciphertext[0] ^= 1;
    }
    assert!(receiver.open(&bad).is_none());
    assert_eq!(receiver.last_received, None);
    let mut wrong = frame.clone();
    if let Frame::Box { sid, .. } = &mut wrong {
        *sid = [4; 8];
    }
    assert!(receiver.open(&wrong).is_none());
    assert_eq!(receiver.open(&frame).unwrap(), vec![42; 760_037]);
    assert!(receiver.open(&frame).is_none());
    sender.send_counter = MAX_COUNTER;
    assert!(sender.seal(b"last").is_some());
    assert!(sender.seal(b"exhausted").is_none());
}
