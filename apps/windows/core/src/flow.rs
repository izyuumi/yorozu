use serde::Serialize;
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Flow {
    pub enabled: bool,
    pub last_ack: u64,
    pub frames_since_ack: u32,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FlowAck {
    #[serde(rename = "type")]
    kind: &'static str,
    pub bytes: String,
}
pub fn on_relay_frame(flow: &mut Flow, flow_bytes: Option<u64>) -> Option<FlowAck> {
    let bytes = flow_bytes?;
    if !flow.enabled || bytes <= flow.last_ack || bytes > crate::frame::MAX_COUNTER {
        return None;
    }
    flow.frames_since_ack += 1;
    if bytes - flow.last_ack < 262_144 && flow.frames_since_ack < 16 {
        return None;
    }
    flow.last_ack = bytes;
    flow.frames_since_ack = 0;
    Some(FlowAck {
        kind: "flowAck",
        bytes: bytes.to_string(),
    })
}
