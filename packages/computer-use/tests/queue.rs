//! Contract tests use an inert backend; they do not prove native desktop effects.
use std::{
    sync::{Arc, Mutex, mpsc},
    time::Duration,
};
use tokio::sync::oneshot;
use yorozu_computer_use::{contract::*, executor::*};

fn ids() -> TaskIds {
    TaskIds {
        task_id: "computer-1".into(),
        parent_id: "secretary".into(),
        origin_id: "user-1".into(),
        attempt_id: "attempt-1".into(),
    }
}
fn transform() -> DisplayTransform {
    DisplayTransform {
        display_id: 1,
        display_frame: Rect {
            x: -1920.,
            y: 0.,
            width: 1920.,
            height: 1080.,
        },
        window_id: 2,
        window_frame: Rect {
            x: -1800.,
            y: 100.,
            width: 600.,
            height: 400.,
        },
        pixel_width: 1200,
        pixel_height: 800,
    }
}
fn grant(budget: usize, allowed: &[ActionKind]) -> Grant {
    Grant::new(
        ids(),
        Target {
            process_id: 3,
            window_id: 2,
            display_id: 1,
        },
        allowed.iter().copied(),
        Duration::from_secs(120),
        budget,
    )
    .unwrap()
}
fn batch(id: &str, actions: Vec<Action>) -> DesktopBatch {
    DesktopBatch {
        ids: ids(),
        batch_id: id.into(),
        deadline_ms: 30000,
        actions,
    }
}
fn text(id: &str, value: &str) -> Action {
    Action::Text {
        observation_id: id.into(),
        text: value.into(),
    }
}
const ALL: &[ActionKind] = &[
    ActionKind::Screenshot,
    ActionKind::Text,
    ActionKind::Click,
    ActionKind::Focus,
    ActionKind::Wait,
];
struct InertDesktop {
    log: Arc<Mutex<Vec<String>>>,
    fail: bool,
    deny: bool,
    gate: Option<(oneshot::Sender<()>, mpsc::Receiver<()>)>,
    preflight_gate: Option<(oneshot::Sender<()>, mpsc::Receiver<()>)>,
}
impl Desktop for InertDesktop {
    fn capture(&mut self, _: &Target) -> Result<CapturedFrame, String> {
        self.log.lock().unwrap().push("capture".into());
        Ok(CapturedFrame {
            transform: transform(),
            png: b"\x89PNG\r\n\x1a\nINERT".to_vec(),
        })
    }
    fn preflight(
        &mut self,
        _: &Target,
        _: Option<&DisplayTransform>,
        _: bool,
    ) -> Result<(), String> {
        if let Some((entered, release)) = self.preflight_gate.take() {
            let _ = entered.send(());
            release.recv_timeout(Duration::from_secs(15)).unwrap();
        }
        if self.deny {
            Err("fixture preflight denied".into())
        } else {
            Ok(())
        }
    }
    fn perform(
        &mut self,
        _: &Target,
        action: &Action,
        _: Option<(i32, i32)>,
    ) -> Result<(), String> {
        self.log.lock().unwrap().push(match action {
            Action::Text { text, .. } => text.clone(),
            _ => "focus".into(),
        });
        if let Some((entered, release)) = self.gate.take() {
            let _ = entered.send(());
            release.recv_timeout(Duration::from_secs(2)).unwrap();
        }
        if self.fail {
            Err("fixture lost acknowledgement".into())
        } else {
            Ok(())
        }
    }
}
fn queue(fail: bool, deny: bool) -> (DesktopQueue, Arc<Mutex<Vec<String>>>) {
    let log = Arc::new(Mutex::new(vec![]));
    let other = log.clone();
    let q = DesktopQueue::start(move || {
        Ok(Box::new(InertDesktop {
            log: other,
            fail,
            deny,
            gate: None,
            preflight_gate: None,
        }))
    })
    .unwrap();
    (q, log)
}
async fn observe(q: &DesktopQueue, g: &Grant, id: &str) -> String {
    let result = q
        .submit(
            batch(id, vec![Action::Screenshot {}]),
            g.clone(),
            StopToken::default(),
        )
        .await
        .unwrap();
    assert_eq!(result.results[0].status, ActionStatus::Completed);
    result.results[0]
        .observation
        .as_ref()
        .unwrap()
        .observation_id
        .clone()
}

#[test]
fn wire_rejects_code_and_unknown_fields() {
    for value in [
        r#"{"action":"execute","code":"anything"}"#,
        r#"{"action":"screenshot","shell":"anything"}"#,
        r#"{"action":"key","observation_id":"o","key":"command"}"#,
    ] {
        assert!(
            serde_json::from_str::<Action>(value).is_err(),
            "accepted unexpected wire value: {value}"
        );
    }
    assert!(
        decode_batch(&vec![b' '; 65537])
            .unwrap_err()
            .contains("64 KiB")
    );
}
#[test]
fn pixel_transform_handles_negative_origins_and_scaled_observations() {
    assert_eq!(
        transform()
            .desktop_point(&PixelPoint { x: 100, y: 200 })
            .unwrap(),
        (-1750, 200)
    );
    assert!(
        transform()
            .desktop_point(&PixelPoint { x: 1200, y: 0 })
            .is_err()
    );
    let mut t = transform();
    t.window_frame.x = -2000.;
    assert!(t.validate().is_err());
    t = transform();
    t.window_frame.x = -1800.5;
    assert!(t.desktop_point(&PixelPoint { x: 0, y: 0 }).is_err());
    t = transform();
    t.display_frame.width = f64::NAN;
    assert!(t.validate().is_err());
}
#[tokio::test]
async fn english_and_japanese_reach_adapter_once_with_fresh_observations() {
    let (q, log) = queue(false, false);
    let g = grant(8, ALL);
    for (index, value) in ["Hello Yorozu", "こんにちは、よろず"]
        .into_iter()
        .enumerate()
    {
        let id = observe(&q, &g, &format!("observe-{index}")).await;
        let result = q
            .submit(
                batch(&format!("text-{index}"), vec![text(&id, value)]),
                g.clone(),
                StopToken::default(),
            )
            .await
            .unwrap();
        assert_eq!(result.results[0].status, ActionStatus::Completed);
        let stale = q
            .submit(
                batch(&format!("stale-{index}"), vec![text(&id, "duplicate")]),
                g.clone(),
                StopToken::default(),
            )
            .await
            .unwrap();
        assert_eq!(stale.results[0].status, ActionStatus::Rejected);
    }
    assert_eq!(
        *log.lock().unwrap(),
        ["capture", "Hello Yorozu", "capture", "こんにちは、よろず"]
    );
}
#[tokio::test]
async fn authorization_and_bounds_reject_before_any_dispatch() {
    let (q, log) = queue(false, false);
    let mut wrong = batch("wrong-task", vec![Action::Screenshot {}]);
    wrong.ids.attempt_id = "other".into();
    let oversized = batch("large-text", vec![text("o", &"a".repeat(4097))]);
    let controls = batch("controls", vec![text("o", "a\tb")]);
    for (b, g) in [
        (wrong, grant(8, ALL)),
        (oversized, grant(8, ALL)),
        (controls, grant(8, ALL)),
        (
            batch("not-authorized", vec![Action::Focus {}]),
            grant(8, &[ActionKind::Screenshot]),
        ),
    ] {
        assert!(
            q.submit(b, g, StopToken::default())
                .await
                .unwrap()
                .rejection
                .is_some()
        );
    }
    assert!(
        q.submit(
            DesktopBatch {
                deadline_ms: 30001,
                ..batch("deadline", vec![Action::Screenshot {}])
            },
            grant(8, ALL),
            StopToken::default()
        )
        .await
        .is_err()
    );
    assert!(log.lock().unwrap().is_empty());
}
#[tokio::test]
async fn replay_and_total_grant_budget_are_session_wide() {
    let (q, log) = queue(false, false);
    let g = grant(2, ALL);
    observe(&q, &g, "one").await;
    let replay = q
        .submit(
            batch("one", vec![Action::Screenshot {}]),
            g.clone(),
            StopToken::default(),
        )
        .await
        .unwrap();
    assert!(replay.rejection.unwrap().contains("already admitted"));
    observe(&q, &g, "two").await;
    let exhausted = q
        .submit(
            batch("three", vec![Action::Screenshot {}]),
            g,
            StopToken::default(),
        )
        .await
        .unwrap();
    assert!(exhausted.rejection.unwrap().contains("budget"));
    assert_eq!(*log.lock().unwrap(), ["capture", "capture"]);
}
#[tokio::test]
async fn foreign_observations_and_out_of_bounds_points_never_dispatch() {
    let (q, log) = queue(false, false);
    let g = grant(10, ALL);
    let id = observe(&q, &g, "observe").await;
    let other_ids = TaskIds {
        attempt_id: "other".into(),
        ..ids()
    };
    let other_grant = Grant::new(
        other_ids.clone(),
        Target {
            process_id: 3,
            window_id: 2,
            display_id: 1,
        },
        ALL.iter().copied(),
        Duration::from_secs(30),
        10,
    )
    .unwrap();
    let foreign = DesktopBatch {
        ids: other_ids,
        ..batch("foreign", vec![text(&id, "foreign")])
    };
    assert_eq!(
        q.submit(foreign, other_grant, StopToken::default())
            .await
            .unwrap()
            .results[0]
            .status,
        ActionStatus::Rejected
    );
    let outside = Action::Click {
        observation_id: id,
        point: PixelPoint { x: 1200, y: 0 },
        button: Button::Left,
    };
    let result = q
        .submit(
            batch("outside", vec![outside, Action::Focus {}]),
            g,
            StopToken::default(),
        )
        .await
        .unwrap();
    assert_eq!(
        result.results.iter().map(|r| r.status).collect::<Vec<_>>(),
        [ActionStatus::Rejected, ActionStatus::Skipped]
    );
    assert_eq!(*log.lock().unwrap(), ["capture"]);
}
#[tokio::test]
async fn preflight_failure_stops_batch_without_unknown_effect() {
    let (q, log) = queue(false, true);
    let g = grant(10, ALL);
    let id = observe(&q, &g, "observe").await;
    let result = q
        .submit(
            batch("input", vec![text(&id, "blocked"), Action::Screenshot {}]),
            g,
            StopToken::default(),
        )
        .await
        .unwrap();
    assert_eq!(
        result.results.iter().map(|r| r.status).collect::<Vec<_>>(),
        [ActionStatus::Rejected, ActionStatus::Skipped]
    );
    assert!(!result.input_halted);
    assert_eq!(*log.lock().unwrap(), ["capture"]);
}
#[tokio::test]
async fn uncertain_effect_halts_all_future_input_but_allows_observation() {
    let (q, log) = queue(true, false);
    let g = grant(10, ALL);
    let id = observe(&q, &g, "observe").await;
    let result = q
        .submit(
            batch("input", vec![text(&id, "uncertain"), Action::Screenshot {}]),
            g.clone(),
            StopToken::default(),
        )
        .await
        .unwrap();
    assert_eq!(
        result.results.iter().map(|r| r.status).collect::<Vec<_>>(),
        [ActionStatus::UnknownEffect, ActionStatus::Skipped]
    );
    assert!(result.input_halted);
    let id = observe(&q, &g, "reconcile").await;
    let next = q
        .submit(
            batch("next", vec![text(&id, "replay")]),
            g,
            StopToken::default(),
        )
        .await
        .unwrap();
    assert_eq!(next.results[0].status, ActionStatus::Rejected);
    assert_eq!(*log.lock().unwrap(), ["capture", "uncertain", "capture"]);
}
#[tokio::test]
async fn serialization_queue_deadline_and_inflight_stop_do_not_abandon_native_call() {
    let log = Arc::new(Mutex::new(vec![]));
    let other = log.clone();
    let (entered_tx, entered_rx) = oneshot::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let q = DesktopQueue::start(move || {
        Ok(Box::new(InertDesktop {
            log: other,
            fail: false,
            deny: false,
            gate: Some((entered_tx, release_rx)),
            preflight_gate: None,
        }))
    })
    .unwrap();
    let g = grant(10, ALL);
    let stop = StopToken::default();
    let (q1, g1, s1) = (q.clone(), g.clone(), stop.clone());
    let first = tokio::spawn(async move {
        q1.submit(
            batch("first", vec![Action::Focus {}, Action::Screenshot {}]),
            g1,
            s1,
        )
        .await
        .unwrap()
    });
    entered_rx.await.unwrap();
    let (q2, g2) = (q.clone(), g.clone());
    let second = tokio::spawn(async move {
        q2.submit(
            DesktopBatch {
                deadline_ms: 1,
                ..batch("expired-in-queue", vec![Action::Screenshot {}])
            },
            g2,
            StopToken::default(),
        )
        .await
        .unwrap()
    });
    tokio::task::yield_now().await;
    // The first native call is deliberately blocked; no other call may start.
    assert_eq!(*log.lock().unwrap(), ["focus"]);
    tokio::time::sleep(Duration::from_millis(10)).await;
    stop.stop();
    release_tx.send(()).unwrap();
    let first = first.await.unwrap();
    let second = second.await.unwrap();
    assert_eq!(first.results[0].status, ActionStatus::UnknownEffect);
    assert_eq!(first.results[1].status, ActionStatus::Skipped);
    assert!(second.rejection.unwrap().contains("deadline"));
    assert_eq!(*log.lock().unwrap(), ["focus"]);
    let id = observe(&q, &g, "after-call-returned").await;
    assert!(!id.is_empty());
}
#[tokio::test]
async fn stopped_worker_and_expired_grant_cannot_start() {
    let (q, log) = queue(false, false);
    let stop = StopToken::default();
    stop.stop();
    assert!(
        q.submit(
            batch("stopped", vec![Action::Screenshot {}]),
            grant(10, ALL),
            stop
        )
        .await
        .unwrap()
        .rejection
        .unwrap()
        .contains("stopped")
    );
    let g = Grant::new(
        ids(),
        Target {
            process_id: 3,
            window_id: 2,
            display_id: 1,
        },
        ALL.iter().copied(),
        Duration::from_nanos(1),
        10,
    )
    .unwrap();
    assert!(
        q.submit(
            batch("expired", vec![Action::Screenshot {}]),
            g,
            StopToken::default()
        )
        .await
        .unwrap()
        .rejection
        .unwrap()
        .contains("deadline")
    );
    assert!(log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn worker_context_is_bounded_and_secretary_outcome_contains_only_evidence_ids() {
    use yorozu_computer_use::worker::WorkerContext;
    let (q, _) = queue(false, false);
    let g = grant(32, ALL);
    let mut worker = WorkerContext::new(WorkerGoal {
        ids: ids(),
        goal: "Controlled text fixture".into(),
        context: "Use only the dedicated document".into(),
        authorization: "Observe and type approved text".into(),
    })
    .unwrap();
    for i in 0..18 {
        let result = q
            .submit(
                batch(&format!("observe-{i}"), vec![Action::Screenshot {}]),
                g.clone(),
                StopToken::default(),
            )
            .await
            .unwrap();
        worker.record(result).unwrap();
    }
    assert_eq!(worker.history().len(), 16);
    assert_eq!(
        worker
            .history()
            .iter()
            .flat_map(|b| &b.results)
            .filter_map(|r| r.observation.as_ref())
            .filter(|o| !o.image.is_empty())
            .count(),
        2
    );
    let outcome = worker
        .outcome(WorkerStatus::Stuck, "Await native fixture access".into())
        .unwrap();
    assert_eq!(outcome.evidence_ids.len(), 16);
    let json = serde_json::to_string(&outcome).unwrap();
    assert!(!json.contains("INERT") && !json.contains("image") && !json.contains("transform"));
    assert!(
        worker
            .steer(
                &TaskIds {
                    attempt_id: "foreign".into(),
                    ..ids()
                },
                "expand scope".into()
            )
            .is_err()
    );
    worker
        .steer(&ids(), "Same bounded goal, updated context".into())
        .unwrap();
    assert_eq!(worker.goal().context, "Same bounded goal, updated context");
}

#[tokio::test]
async fn observation_expiring_during_native_preflight_never_dispatches() {
    let log = Arc::new(Mutex::new(vec![]));
    let other = log.clone();
    let (entered_tx, entered_rx) = oneshot::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let q = DesktopQueue::start(move || {
        Ok(Box::new(InertDesktop {
            log: other,
            fail: false,
            deny: false,
            gate: None,
            preflight_gate: Some((entered_tx, release_rx)),
        }))
    })
    .unwrap();
    let g = grant(3, ALL);
    let id = observe(&q, &g, "observe").await;
    let (other_q, other_g) = (q.clone(), g.clone());
    let call = tokio::spawn(async move {
        other_q
            .submit(
                batch("expiry-race", vec![text(&id, "must not type")]),
                other_g,
                StopToken::default(),
            )
            .await
            .unwrap()
    });
    entered_rx.await.unwrap();
    tokio::time::sleep(Duration::from_millis(10020)).await;
    release_tx.send(()).unwrap();
    let result = call.await.unwrap();
    assert_eq!(result.results[0].status, ActionStatus::Rejected);
    assert!(result.results[0].detail.contains("stale"));
    assert_eq!(*log.lock().unwrap(), ["capture"]);
}
