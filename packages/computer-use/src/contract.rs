//! Provider-neutral wire types. Images belong only in the dedicated worker context.
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskIds {
    pub task_id: String,
    pub parent_id: String,
    pub origin_id: String,
    pub attempt_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerGoal {
    pub ids: TaskIds,
    pub goal: String,
    pub context: String,
    /// Human-readable scope; the trusted host must separately issue a Grant.
    pub authorization: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case", deny_unknown_fields)]
pub enum WorkerControl {
    Steer { ids: TaskIds, context: String },
    Queue { goal: WorkerGoal },
    Stop { ids: TaskIds },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerStatus {
    Done,
    Stuck,
    Stopped,
}

/// Return to the secretary. No screenshot bytes or full action transcript.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerOutcome {
    pub ids: TaskIds,
    pub status: WorkerStatus,
    pub summary: String,
    pub evidence_ids: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    Screenshot,
    Move,
    Click,
    Scroll,
    Text,
    Key,
    Focus,
    Wait,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Button {
    Left,
    Right,
    Middle,
}

/// Balanced key taps only. No held-key state or arbitrary platform keycodes.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Key {
    Return,
    Tab,
    Escape,
    Backspace,
    Left,
    Right,
    Up,
    Down,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PixelPoint {
    pub x: u32,
    pub y: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum Action {
    Screenshot {},
    Move {
        observation_id: String,
        point: PixelPoint,
    },
    Click {
        observation_id: String,
        point: PixelPoint,
        button: Button,
    },
    Scroll {
        observation_id: String,
        point: PixelPoint,
        vertical: i32,
        horizontal: i32,
    },
    Text {
        observation_id: String,
        text: String,
    },
    Key {
        observation_id: String,
        key: Key,
    },
    Focus {},
    Wait {
        milliseconds: u32,
    },
}
impl Action {
    pub fn kind(&self) -> ActionKind {
        match self {
            Self::Screenshot {} => ActionKind::Screenshot,
            Self::Move { .. } => ActionKind::Move,
            Self::Click { .. } => ActionKind::Click,
            Self::Scroll { .. } => ActionKind::Scroll,
            Self::Text { .. } => ActionKind::Text,
            Self::Key { .. } => ActionKind::Key,
            Self::Focus {} => ActionKind::Focus,
            Self::Wait { .. } => ActionKind::Wait,
        }
    }
    pub fn has_effect(&self) -> bool {
        !matches!(self, Self::Screenshot {} | Self::Wait { .. })
    }
    pub fn observation_id(&self) -> Option<&str> {
        match self {
            Self::Move { observation_id, .. }
            | Self::Click { observation_id, .. }
            | Self::Scroll { observation_id, .. }
            | Self::Text { observation_id, .. }
            | Self::Key { observation_id, .. } => Some(observation_id),
            _ => None,
        }
    }
    pub fn point(&self) -> Option<&PixelPoint> {
        match self {
            Self::Move { point, .. } | Self::Click { point, .. } | Self::Scroll { point, .. } => {
                Some(point)
            }
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopBatch {
    pub ids: TaskIds,
    pub batch_id: String,
    pub deadline_ms: u32,
    pub actions: Vec<Action>,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Top-left image pixels -> global macOS logical points (negative origins allowed).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DisplayTransform {
    pub display_id: u32,
    pub display_frame: Rect,
    pub window_id: u32,
    pub window_frame: Rect,
    pub pixel_width: u32,
    pub pixel_height: u32,
}
impl DisplayTransform {
    pub fn validate(&self) -> Result<(), String> {
        for r in [self.display_frame, self.window_frame] {
            if ![r.x, r.y, r.width, r.height].iter().all(|v| v.is_finite())
                || r.width <= 0.0
                || r.height <= 0.0
            {
                return Err("invalid geometry".into());
            }
        }
        let (d, w) = (self.display_frame, self.window_frame);
        if self.display_id == 0
            || self.window_id == 0
            || self.pixel_width == 0
            || self.pixel_height == 0
            || self.pixel_width > 1600
            || self.pixel_height > 1600
            || w.x < d.x
            || w.y < d.y
            || w.x + w.width > d.x + d.width
            || w.y + w.height > d.y + d.height
        {
            return Err("unsupported display/window geometry".into());
        }
        Ok(())
    }
    pub fn desktop_point(&self, p: &PixelPoint) -> Result<(i32, i32), String> {
        self.validate()?;
        if p.x >= self.pixel_width || p.y >= self.pixel_height {
            return Err("point outside observation".into());
        }
        let w = self.window_frame;
        let x = (w.x + f64::from(p.x) * w.width / f64::from(self.pixel_width)).floor();
        let y = (w.y + f64::from(p.y) * w.height / f64::from(self.pixel_height)).floor();
        if x < i32::MIN as f64 || x > i32::MAX as f64 || y < i32::MIN as f64 || y > i32::MAX as f64
        {
            return Err("point outside desktop coordinate range".into());
        }
        if x < w.x || y < w.y || x >= w.x + w.width || y >= w.y + w.height {
            return Err("rounded point outside window".into());
        }
        Ok((x as i32, y as i32))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Observation {
    pub observation_id: String,
    pub transform: DisplayTransform,
    pub mime_type: String,
    /// In-memory worker payload; provider adapters encode it for their own image API.
    pub image: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionStatus {
    Completed,
    Rejected,
    UnknownEffect,
    Skipped,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActionResult {
    pub index: usize,
    pub status: ActionStatus,
    pub detail: String,
    pub observation: Option<Observation>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BatchResult {
    pub ids: TaskIds,
    pub batch_id: String,
    pub results: Vec<ActionResult>,
    pub input_halted: bool,
    pub rejection: Option<String>,
}

/// Use at the custom-function boundary before allocating model-supplied batches.
/// Grants always come from the trusted host, never from this JSON.
pub fn decode_batch(json: &[u8]) -> Result<DesktopBatch, String> {
    if json.len() > 65536 {
        return Err("desktop batch JSON exceeds 64 KiB".into());
    }
    serde_json::from_slice(json).map_err(|e| e.to_string())
}
