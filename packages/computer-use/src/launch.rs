//! One trusted app request over inherited pipes; never accept this from model output.
use crate::{contract::*, executor::*, model::*, responses::ResponsesModel, worker::WorkerContext};
use serde::Deserialize;
use std::time::Duration;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LaunchRequest {
    pub version: u8,
    pub goal: WorkerGoal,
    pub process_id: i32,
    pub window_id: u32,
    pub display_id: u32,
    pub allowed: Vec<ActionKind>,
    pub action_budget: usize,
    pub duration_ms: u64,
    pub model: String,
    /// Sent on a private inherited pipe, never argv, environment, logs or disk.
    pub api_key: String,
}
impl LaunchRequest {
    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > 65536 {
            return Err("launch request exceeds 64 KiB".into());
        }
        let request: Self = serde_json::from_slice(bytes).map_err(|_| "invalid launch request")?;
        if request.version != 1 {
            return Err("unsupported launch protocol".into());
        }
        Ok(request)
    }
    pub async fn run(self, native: bool) -> Result<WorkerOutcome, String> {
        let mut context = WorkerContext::new(self.goal)?;
        let stuck = |summary: &str| context.outcome(WorkerStatus::Stuck, summary.into());
        if !native {
            return stuck("Native execution disabled; launch transport only");
        }
        let duration = Duration::from_millis(self.duration_ms);
        let grant = match Grant::new(
            context.goal().ids.clone(),
            Target {
                process_id: self.process_id,
                window_id: self.window_id,
                display_id: self.display_id,
            },
            self.allowed,
            duration,
            self.action_budget,
        ) {
            Ok(grant) => grant,
            Err(_) => return stuck("Invalid host grant; no execution"),
        };
        let limits = match WorkerLimits::new(16, duration, duration.min(Duration::from_secs(30))) {
            Ok(limits) => limits,
            Err(_) => return stuck("Invalid worker limits; no execution"),
        };
        let mut provider = match ResponsesModel::new(
            "https://api.openai.com/v1/responses",
            self.api_key,
            self.model,
        ) {
            Ok(provider) => provider,
            Err(_) => return stuck("Missing or invalid user-supplied provider configuration"),
        };
        #[cfg(target_os = "macos")]
        let queue = DesktopQueue::start(|| Ok(Box::new(crate::macos::MacDesktop::new()?)));
        #[cfg(not(target_os = "macos"))]
        let queue: Result<DesktopQueue, String> = Err("macOS required".into());
        let queue = match queue {
            Ok(queue) => queue,
            Err(_) => {
                return stuck(
                    "Native helper unavailable; verify existing permissions and launch identity",
                );
            }
        };
        run_worker(
            &mut provider,
            &queue,
            grant,
            &mut context,
            StopToken::default(),
            limits,
        )
        .await
    }
}
