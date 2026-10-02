//! A bounded Tokio mailbox feeding one synchronous desktop owner. Native calls are
//! never abandoned on timeout: the next action waits for the call to return.
use crate::contract::*;
use std::{
    collections::HashSet,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot};

const MAX_BATCH: usize = 32;
const MAX_REPLAY_IDS: usize = 4096;
const OBSERVATION_TTL: Duration = Duration::from_secs(10);
const MAX_IMAGE: usize = 12 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct Target {
    pub process_id: i32,
    pub window_id: u32,
    pub display_id: u32,
}

/// Only the trusted host creates this. Never deserialize grants from model output.
#[derive(Clone)]
pub struct Grant(Arc<GrantData>);
struct GrantData {
    ids: TaskIds,
    target: Target,
    allowed: HashSet<ActionKind>,
    deadline: Instant,
    remaining: AtomicUsize,
}
impl Grant {
    pub fn new(
        ids: TaskIds,
        target: Target,
        allowed: impl IntoIterator<Item = ActionKind>,
        lifetime: Duration,
        action_budget: usize,
    ) -> Result<Self, String> {
        validate_ids(&ids)?;
        if target.process_id <= 0
            || target.window_id == 0
            || target.display_id == 0
            || lifetime.is_zero()
            || lifetime > Duration::from_secs(120)
            || action_budget == 0
            || action_budget > 128
        {
            return Err("invalid grant bounds".into());
        }
        Ok(Self(Arc::new(GrantData {
            ids,
            target,
            allowed: allowed.into_iter().collect(),
            deadline: Instant::now() + lifetime,
            remaining: AtomicUsize::new(action_budget),
        })))
    }
}

#[derive(Clone, Default)]
pub struct StopToken(Arc<AtomicBool>);
impl StopToken {
    pub fn stop(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_stopped(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

pub struct CapturedFrame {
    pub transform: DisplayTransform,
    pub png: Vec<u8>,
}

/// Backend preflight must fail BEFORE dispatch on scope, foreground or geometry
/// changes. Errors from `perform` are conservatively unknown-effect.
pub trait Desktop: Send + 'static {
    fn capture(&mut self, target: &Target) -> Result<CapturedFrame, String>;
    fn preflight(
        &mut self,
        target: &Target,
        expected: Option<&DisplayTransform>,
        focus: bool,
    ) -> Result<(), String>;
    fn perform(
        &mut self,
        target: &Target,
        action: &Action,
        point: Option<(i32, i32)>,
    ) -> Result<(), String>;
}

struct Request {
    batch: DesktopBatch,
    grant: Grant,
    stop: StopToken,
    deadline: Instant,
    reply: oneshot::Sender<BatchResult>,
}
#[derive(Clone)]
pub struct DesktopQueue {
    sender: mpsc::Sender<Request>,
}
impl DesktopQueue {
    /// Factory runs on the dedicated thread, keeping platform state on its owner.
    pub fn start(
        factory: impl FnOnce() -> Result<Box<dyn Desktop>, String> + Send + 'static,
    ) -> Result<Self, String> {
        let (sender, mut receiver) = mpsc::channel::<Request>(8);
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("yorozu-desktop".into())
            .spawn(move || {
                let mut desktop = match factory() {
                    Ok(d) => {
                        let _ = ready_tx.send(Ok(()));
                        d
                    }
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                        return;
                    }
                };
                let mut executor = Executor::default();
                while let Some(request) = receiver.blocking_recv() {
                    let result = executor.execute(&mut *desktop, &request);
                    let _ = request.reply.send(result);
                }
            })
            .map_err(|e| e.to_string())?;
        ready_rx.recv().map_err(|e| e.to_string())??;
        Ok(Self { sender })
    }
    pub async fn submit(
        &self,
        batch: DesktopBatch,
        grant: Grant,
        stop: StopToken,
    ) -> Result<BatchResult, String> {
        if batch.deadline_ms == 0 || batch.deadline_ms > 30_000 || batch.actions.len() > MAX_BATCH {
            return Err("batch exceeds action/deadline bounds".into());
        }
        let deadline = Instant::now() + Duration::from_millis(u64::from(batch.deadline_ms));
        let (reply, receive) = oneshot::channel();
        self.sender
            .try_send(Request {
                batch,
                grant,
                stop,
                deadline,
                reply,
            })
            .map_err(|e| match e {
                mpsc::error::TrySendError::Full(_) => "desktop queue full".to_string(),
                mpsc::error::TrySendError::Closed(_) => "desktop queue closed".to_string(),
            })?;
        receive
            .await
            .map_err(|_| "desktop owner stopped; do not replay actions".into())
    }
}

struct FreshObservation {
    ids: TaskIds,
    id: String,
    transform: DisplayTransform,
    at: Instant,
}
#[derive(Default)]
struct Executor {
    seen: HashSet<(TaskIds, String)>,
    observation: Option<FreshObservation>,
    input_halted: bool,
}
impl Executor {
    fn execute(&mut self, desktop: &mut dyn Desktop, request: &Request) -> BatchResult {
        let batch = &request.batch;
        let mut result = BatchResult {
            ids: batch.ids.clone(),
            batch_id: batch.batch_id.clone(),
            results: vec![],
            input_halted: self.input_halted,
            rejection: None,
        };
        if let Err(e) = self.admit(request) {
            result.rejection = Some(e);
            return result;
        }
        let mut failed = false;
        for (index, action) in batch.actions.iter().enumerate() {
            let (status, detail, observation) = if failed {
                (
                    ActionStatus::Skipped,
                    "earlier action stopped batch".into(),
                    None,
                )
            } else {
                self.act(desktop, request, action)
            };
            failed = status != ActionStatus::Completed;
            result.results.push(ActionResult {
                index,
                status,
                detail,
                observation,
            });
        }
        result.input_halted = self.input_halted;
        result
    }
    fn admit(&mut self, r: &Request) -> Result<(), String> {
        validate_ids(&r.batch.ids)?;
        valid_id(&r.batch.batch_id)?;
        if r.batch.ids != r.grant.0.ids {
            return Err("grant identity mismatch".into());
        }
        if r.batch.actions.is_empty() {
            return Err("empty batch".into());
        }
        self.check_live(r)?;
        let key = (r.batch.ids.clone(), r.batch.batch_id.clone());
        if self.seen.contains(&key) {
            return Err("batch already admitted; never replay".into());
        }
        if self.seen.len() >= MAX_REPLAY_IDS {
            return Err("session replay ledger full".into());
        }
        if r.batch
            .actions
            .iter()
            .filter(|a| matches!(a, Action::Screenshot {}))
            .count()
            > 2
        {
            return Err("at most two screenshots per batch".into());
        }
        for a in &r.batch.actions {
            if !r.grant.0.allowed.contains(&a.kind()) {
                return Err("action outside authorization".into());
            }
            if let Some(id) = a.observation_id() {
                valid_id(id)?;
            }
            match a {
                Action::Text { text, .. }
                    if text.is_empty()
                        || text.len() > 4096
                        || text.chars().any(char::is_control) =>
                {
                    return Err("text exceeds bounds".into());
                }
                Action::Scroll {
                    vertical,
                    horizontal,
                    ..
                } if vertical.unsigned_abs() > 20 || horizontal.unsigned_abs() > 20 => {
                    return Err("scroll exceeds bounds".into());
                }
                Action::Wait { milliseconds } if *milliseconds > 2000 => {
                    return Err("wait exceeds bounds".into());
                }
                _ => {}
            }
        }
        r.grant
            .0
            .remaining
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                n.checked_sub(r.batch.actions.len())
            })
            .map_err(|_| "grant action budget exhausted")?;
        self.seen.insert(key);
        Ok(())
    }
    fn check_live(&self, r: &Request) -> Result<(), String> {
        if r.stop.is_stopped() || r.reply.is_closed() {
            return Err("worker stopped or caller detached".into());
        }
        if Instant::now() >= r.deadline || Instant::now() >= r.grant.0.deadline {
            return Err("deadline expired".into());
        }
        Ok(())
    }
    fn act(
        &mut self,
        d: &mut dyn Desktop,
        r: &Request,
        a: &Action,
    ) -> (ActionStatus, String, Option<Observation>) {
        let reject = |e| (ActionStatus::Rejected, e, None);
        if let Err(e) = self.check_live(r) {
            return reject(e);
        }
        if self.input_halted && a.has_effect() {
            return reject("desktop input halted after unknown effect".into());
        }
        if let Action::Wait { milliseconds } = a {
            let until = Instant::now() + Duration::from_millis(u64::from(*milliseconds));
            while Instant::now() < until {
                if let Err(e) = self.check_live(r) {
                    return reject(e);
                }
                std::thread::sleep(
                    Duration::from_millis(5).min(until.saturating_duration_since(Instant::now())),
                );
            }
            return (ActionStatus::Completed, "wait complete".into(), None);
        }
        if matches!(a, Action::Screenshot {}) {
            self.observation = None;
            let at = Instant::now();
            let frame = match catch_unwind(AssertUnwindSafe(|| d.capture(&r.grant.0.target))) {
                Ok(Ok(f)) => f,
                Ok(Err(e)) => return reject(e),
                Err(_) => return reject("capture backend panicked".into()),
            };
            if let Err(e) = self.check_live(r) {
                return reject(e);
            }
            if let Err(e) = frame.transform.validate() {
                return reject(e);
            }
            if frame.transform.window_id != r.grant.0.target.window_id
                || frame.transform.display_id != r.grant.0.target.display_id
                || frame.png.len() > MAX_IMAGE
                || !frame.png.starts_with(b"\x89PNG\r\n\x1a\n")
            {
                return reject("capture outside scope or invalid image".into());
            }
            let id = uuid::Uuid::new_v4().to_string();
            self.observation = Some(FreshObservation {
                ids: r.batch.ids.clone(),
                id: id.clone(),
                transform: frame.transform.clone(),
                at,
            });
            return (
                ActionStatus::Completed,
                "captured scoped window".into(),
                Some(Observation {
                    observation_id: id,
                    transform: frame.transform,
                    mime_type: "image/png".into(),
                    image: frame.png,
                }),
            );
        }
        let expected = if let Some(id) = a.observation_id() {
            match &self.observation {
                Some(o)
                    if o.id == id
                        && o.ids == r.batch.ids
                        && o.transform.window_id == r.grant.0.target.window_id
                        && o.transform.display_id == r.grant.0.target.display_id
                        && o.at.elapsed() < OBSERVATION_TTL =>
                {
                    Some(&o.transform)
                }
                _ => return reject("stale, consumed or foreign observation".into()),
            }
        } else {
            None
        };
        let point = match a.point() {
            Some(p) => match expected
                .expect("pointer action requires observation")
                .desktop_point(p)
            {
                Ok(p) => Some(p),
                Err(e) => return reject(e),
            },
            None => None,
        };
        match catch_unwind(AssertUnwindSafe(|| {
            d.preflight(&r.grant.0.target, expected, matches!(a, Action::Focus {}))
        })) {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                self.observation = None;
                return reject(e);
            }
            Err(_) => {
                self.observation = None;
                return reject("preflight backend panicked".into());
            }
        }
        if let Err(e) = self.check_live(r) {
            return reject(e);
        }
        // A native preflight can take time; freshness must still hold at dispatch.
        if a.observation_id().is_some()
            && self
                .observation
                .as_ref()
                .is_none_or(|o| o.at.elapsed() >= OBSERVATION_TTL)
        {
            self.observation = None;
            return reject("stale observation after native preflight".into());
        }
        // Any desktop change consumes the observation; the model must observe again.
        self.observation = None;
        let dispatch = catch_unwind(AssertUnwindSafe(|| d.perform(&r.grant.0.target, a, point)));
        let error = match dispatch {
            Ok(Ok(())) => self.check_live(r).err(),
            Ok(Err(e)) => Some(e),
            Err(_) => Some("input backend panicked".into()),
        };
        if let Some(e) = error {
            self.input_halted = true;
            (
                ActionStatus::UnknownEffect,
                format!("{e}; observe and reconcile, never replay"),
                None,
            )
        } else {
            (
                ActionStatus::Completed,
                "OS dispatch acknowledged; verify outcome with a new screenshot".into(),
                None,
            )
        }
    }
}
pub(crate) fn valid_id(s: &str) -> Result<(), String> {
    if s.is_empty()
        || s.len() > 128
        || !s
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
    {
        return Err("invalid identifier".into());
    }
    Ok(())
}
pub(crate) fn validate_ids(ids: &TaskIds) -> Result<(), String> {
    for s in [
        &ids.task_id,
        &ids.parent_id,
        &ids.origin_id,
        &ids.attempt_id,
    ] {
        valid_id(s)?;
    }
    Ok(())
}
