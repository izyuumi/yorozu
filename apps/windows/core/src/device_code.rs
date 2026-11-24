use crate::{
    frame::{b64, unb64},
    link::Link,
    platform::Platform,
    DeviceCodeView,
};
use chacha20poly1305::{aead::Aead, ChaCha20Poly1305, KeyInit};
use futures_util::{SinkExt, StreamExt};
use hkdf::Hkdf;
use sha2::Sha256;
use std::time::Duration;
use tokio::time::{timeout, timeout_at, Instant};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{protocol::WebSocketConfig, Message},
};
use url::Url;
use x25519_dalek::{PublicKey, StaticSecret};

const DEFAULT_RELAY: &str = "wss://relay.yumi.to";
const PAGE: &str = "https://yorozu.yumi.to/add";
const MAX_LETTER: usize = 4096;
pub const TTL: Duration = Duration::from_secs(600);

pub struct Code {
    pub view: DeviceCodeView,
    mailbox: Url,
    key: StaticSecret,
}
pub enum Outcome {
    Invite(String),
    Invalid,
    Expired,
}
impl Code {
    pub fn new(platform: &dyn Platform) -> Self {
        let mut private = [0; 32];
        platform.random_bytes(&mut private);
        let key = StaticSecret::from(private);
        let mut id = [0; 16];
        platform.random_bytes(&mut id);
        let id = b64(id);
        let name: String = platform.computer_name().chars().take(64).collect();
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("v", "1")
            .append_pair("relay", DEFAULT_RELAY)
            .append_pair("box", &id)
            .append_pair("key", &b64(PublicKey::from(&key).as_bytes()))
            .append_pair("name", name.trim())
            .finish()
            .replace('+', "%20");
        let mailbox =
            Url::parse(&format!("{DEFAULT_RELAY}/mailbox/{id}")).expect("static relay URL");
        Self {
            view: DeviceCodeView {
                link: format!("{PAGE}#{query}"),
                expires_at: platform.now_ms().saturating_add(TTL.as_millis() as u64),
            },
            mailbox,
            key,
        }
    }
    pub async fn receive(self, end: Instant) -> Outcome {
        let _ = rustls::crypto::ring::default_provider().install_default();
        timeout_at(end, async {
            loop {
                let config = WebSocketConfig::default()
                    .max_message_size(Some(MAX_LETTER))
                    .max_frame_size(Some(MAX_LETTER));
                if let Ok(Ok((mut socket, _))) = timeout(
                    Duration::from_secs(8),
                    connect_async_with_config(self.mailbox.as_str(), Some(config), false),
                )
                .await
                {
                    loop {
                        match socket.next().await {
                            Some(Ok(Message::Text(letter))) => {
                                return match open(letter.as_str(), &self.key) {
                                    Some(link) => Outcome::Invite(link),
                                    None => Outcome::Invalid,
                                };
                            }
                            Some(Ok(Message::Ping(bytes))) => {
                                if socket.send(Message::Pong(bytes)).await.is_err() {
                                    break;
                                }
                            }
                            Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                            _ => {}
                        }
                    }
                }
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
        })
        .await
        .unwrap_or(Outcome::Expired)
    }
}
fn open(letter: &str, private: &StaticSecret) -> Option<String> {
    if letter.len() > MAX_LETTER {
        return None;
    }
    let bytes = unb64(letter)?;
    if bytes.len() <= 32 + 12 + 16 {
        return None;
    }
    let sender = PublicKey::from(<[u8; 32]>::try_from(&bytes[..32]).ok()?);
    let shared = private.diffie_hellman(&sender);
    if !shared.was_contributory() {
        return None;
    }
    let recipient = PublicKey::from(private);
    let mut salt = [0; 64];
    salt[..32].copy_from_slice(sender.as_bytes());
    salt[32..].copy_from_slice(recipient.as_bytes());
    let mut key = [0; 32];
    Hkdf::<Sha256>::new(Some(&salt), shared.as_bytes())
        .expand(b"yorozu-device-code", &mut key)
        .ok()?;
    let plain = ChaCha20Poly1305::new((&key).into())
        .decrypt(
            (&<[u8; 12]>::try_from(&bytes[32..44]).ok()?).into(),
            &bytes[44..],
        )
        .ok()?;
    let link = String::from_utf8(plain).ok()?;
    Link::parse_native(&link).ok()?;
    Some(link)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::SystemPlatform;
    use tokio::net::TcpListener;
    use tokio_tungstenite::accept_async;

    const MAC_V3: &str = "xGpZ7iZlFR-LGHQpymPsBtq52tN1CzjXD3eA57UfXklCQkJCQkJCQkJCQkJ1Sd9nf8ZEcWTz4aZlL3nKaiAczv1FuaxXu2KSWzeef_paBTQ2Y4nvIjz6pnKGmRjhayF2nBwnWInMwfhnq1Dnp7vQ6DX4Hlys1DvTzAz1dT86HUvFGHQKc6Ns_iicb624nqres3VpQyo8n3lhlb3ksOtXJDWwSTfxQAGAPy1-7hsvLy71vYpcG7aw_q0IjzPdFxYrx0Be23nlL8LXGpt14kYZjd4_LYVsCltjIkNIk3dfTpI2CYiVxoxfhRuAvqF17o3euRAHJUNtVZj8EIs";
    const MAC_V4: &str = "xGpZ7iZlFR-LGHQpymPsBtq52tN1CzjXD3eA57UfXklCQkJCQkJCQkJCQkJ1Sd9nf8ZEcWTz4aZlL3nKaiAczv1FuaxXu2KSWzeZf_paBTQ2Y4nvIjz6pnKGmRjhayF2nBwnWInMwfhnq1Dnp7vQ6DX4Hlys1DvTzAz1dT86HUvFGHQKc6Ns_iicb624nqres3VpQyo8n3lhlb3ksOtXJDWwSTfxQAGAPy1-7hsvLy71vYpcG7aw_q0IjzPdFxYrx0Be23nlL8LXGpt14kYZjd4_LYVsCltjIkNIk3dfTpI2CYiVxoxfhRuAvknzaT2GCdzlE0IhJoMqOrI";
    const MAC_NO_VERSION: &str = "xGpZ7iZlFR-LGHQpymPsBtq52tN1CzjXD3eA57UfXklCQkJCQkJCQkJCQkJ1Sd9nf8ZEcWTz4aZlL3nKaiAczv1FuaxXu2KSX2_BOPECHiY8e83ddCuPwmXyrVi_TCo9lQU_G5zYxbt-qUOoorzCrzL0A0eG8AOvzAz1dT86HUvFGHQKc6Ns_iicb624nqres3VpQyo8n3lhlb3ksOtXQwCeY3TrEiukEFEZ3TUBZGHYkKUjG7aw_q0IjzPdFxYrx0Be23nlL8LXGpt14kYZjd4_LYVsCltjIkNI90Z4b8YgGNam4rkjK6-JzCY3UM1uuZtO8go8lA";

    #[test]
    fn device_link_matches_mac_mailbox_v1() {
        let code = Code::new(&SystemPlatform { dir: ".".into() });
        let link = Url::parse(&code.view.link).unwrap();
        assert_eq!(
            link.origin().ascii_serialization(),
            "https://yorozu.yumi.to"
        );
        assert_eq!(link.path(), "/add");
        assert!(link.query().is_none());
        let pairs: std::collections::BTreeMap<_, _> =
            url::form_urlencoded::parse(link.fragment().unwrap().as_bytes()).collect();
        assert_eq!(pairs["v"], "1");
        assert_eq!(pairs["relay"], DEFAULT_RELAY);
        assert_eq!(unb64(&pairs["box"]).unwrap().len(), 16);
        assert_eq!(
            unb64(&pairs["key"]).unwrap(),
            PublicKey::from(&code.key).as_bytes()
        );
        assert_eq!(code.mailbox.path(), format!("/mailbox/{}", pairs["box"]));
    }

    #[test]
    fn opens_mac_ciphertext_and_rejects_wrong_recipient_version_and_tampering() {
        let recipient = StaticSecret::from([0x53; 32]);
        let link = open(MAC_V3, &recipient).unwrap();
        assert!(link.starts_with("https://yorozu.yumi.to/pair#v=3&"));
        let parsed = Link::parse(&link).unwrap();
        assert_eq!(parsed.relay_host(), "relay.example.invalid");
        assert_eq!(parsed.fingerprint(), "0000 0000 0000 0000");
        assert!(open(MAC_V4, &recipient).is_none());
        assert!(open(MAC_NO_VERSION, &recipient).is_none());
        assert!(open(MAC_V3, &StaticSecret::from([0x52; 32])).is_none());
        let mut bytes = unb64(MAC_V3).unwrap();
        bytes[47] ^= 1;
        assert!(open(&b64(bytes), &recipient).is_none());
        assert!(open(&"A".repeat(MAX_LETTER + 1), &recipient).is_none());
    }

    #[tokio::test]
    async fn receives_mac_ciphertext_over_mailbox_socket() {
        let mut code = Code::new(&SystemPlatform { dir: ".".into() });
        code.key = StaticSecret::from([0x53; 32]);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        code.mailbox = Url::parse(&format!(
            "ws://{}/mailbox/test",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut socket = accept_async(socket).await.unwrap();
            socket.send(Message::Text(MAC_V3.into())).await.unwrap();
        });
        let outcome = code.receive(Instant::now() + Duration::from_secs(2)).await;
        assert!(
            matches!(outcome, Outcome::Invite(link) if link == open(MAC_V3, &StaticSecret::from([0x53; 32])).unwrap())
        );
        server.await.unwrap();
    }
}
