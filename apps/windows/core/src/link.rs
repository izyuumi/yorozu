use crate::frame::unb64;
use url::Url;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Link {
    pub relay: String,
    pub room: String,
    pub host_key: [u8; 32],
    pub token: String,
    pub secret: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkError {
    Invalid,
    Unusable,
}
impl Link {
    pub fn parse(text: &str) -> Result<Self, LinkError> {
        use LinkError::*;
        let url = Url::parse(text.trim()).map_err(|_| Invalid)?;
        let query = match (url.scheme(), url.host_str(), url.path()) {
            ("yorozu", Some("pair"), "" | "/")
                if url.port().is_none() && url.fragment().is_none() =>
            {
                url.query().ok_or(Invalid)?
            }
            ("https", Some("yorozu.yumi.to"), "/pair")
                if url.port().is_none() && url.query().is_none() =>
            {
                url.fragment().ok_or(Invalid)?
            }
            _ => return Err(Invalid),
        };
        if !url.username().is_empty() || url.password().is_some() {
            return Err(Invalid);
        }
        // Reject malformed percent escapes rather than silently treating them as literal input.
        let bytes = query.as_bytes();
        for (i, b) in bytes.iter().enumerate() {
            if *b == b'%'
                && (i + 2 >= bytes.len()
                    || !bytes[i + 1].is_ascii_hexdigit()
                    || !bytes[i + 2].is_ascii_hexdigit())
            {
                return Err(Invalid);
            }
        }
        let pairs: Vec<_> = url::form_urlencoded::parse(query.as_bytes()).collect();
        for key in ["v", "relay", "key", "token", "room", "secret"] {
            if pairs.iter().filter(|(k, _)| k == key).count() > 1 {
                return Err(Invalid);
            }
        }
        let get = |key: &str| {
            let mut values = pairs.iter().filter(|(k, _)| k == key);
            let value = values.next().map(|(_, v)| v.to_string());
            if values.next().is_some() {
                None
            } else {
                value
            }
        };
        let relay = get("relay").ok_or(Invalid)?;
        let relay_url = Url::parse(&relay).map_err(|_| Invalid)?;
        let key = get("key")
            .and_then(|s| unb64(&s))
            .and_then(|b| b.try_into().ok())
            .ok_or(Invalid)?;
        let token = get("token")
            .filter(|s| !s.is_empty() && unb64(s).is_some())
            .ok_or(Invalid)?;
        let room = get("room")
            .filter(|s| {
                s.len() == 43
                    && s.bytes()
                        .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
            })
            .ok_or(Invalid)?;
        if get("v").is_some_and(|v| v != "3") {
            return Err(Unusable);
        }
        let secret = get("secret").ok_or(Unusable)?;
        if secret.is_empty() || unb64(&secret).is_none() {
            return Err(Invalid);
        }
        let allowed = relay_url.scheme() == "wss"
            || (relay_url.scheme() == "ws"
                && matches!(
                    relay_url.host_str(),
                    Some("localhost" | "127.0.0.1" | "[::1]")
                ));
        if !allowed
            || relay_url.host_str().is_none()
            || !relay_url.username().is_empty()
            || relay_url.password().is_some()
            || relay_url.fragment().is_some()
        {
            return Err(Unusable);
        }
        Ok(Self {
            relay,
            room,
            host_key: key,
            token,
            secret,
        })
    }
    pub fn fingerprint(&self) -> String {
        self.host_key[..8]
            .chunks(2)
            .map(|c| format!("{:02X}{:02X}", c[0], c[1]))
            .collect::<Vec<_>>()
            .join(" ")
    }
    pub fn relay_host(&self) -> String {
        Url::parse(&self.relay)
            .unwrap()
            .host_str()
            .unwrap()
            .to_owned()
    }
}
