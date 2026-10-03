//! Synthetic provider integration only. No native adapter or provider network calls.
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    time::Duration,
};
use yorozu_computer_use::worker::WorkerContext;
use yorozu_computer_use::{contract::*, executor::*, model::*};

fn ids() -> TaskIds {
    TaskIds {
        task_id: "worker".into(),
        parent_id: "secretary".into(),
        origin_id: "user-goal".into(),
        attempt_id: "attempt".into(),
    }
}
fn goal() -> WorkerGoal {
    WorkerGoal {
        ids: ids(),
        goal: "Type approved English/Japanese fixture text".into(),
        context: "Synthetic window only".into(),
        authorization: "Screenshot/text/wait in inert fixture".into(),
    }
}
fn context() -> WorkerContext {
    WorkerContext::new(goal()).unwrap()
}
fn limits(turns: u8) -> WorkerLimits {
    WorkerLimits::new(turns, Duration::from_secs(2), Duration::from_secs(1)).unwrap()
}
fn grant() -> Grant {
    Grant::new(
        ids(),
        Target {
            process_id: 1,
            window_id: 2,
            display_id: 3,
        },
        [ActionKind::Screenshot, ActionKind::Text, ActionKind::Wait],
        Duration::from_secs(30),
        32,
    )
    .unwrap()
}
struct InertDesktop {
    log: Arc<Mutex<Vec<String>>>,
    lose_ack: bool,
}
impl Desktop for InertDesktop {
    fn capture(&mut self, _: &Target) -> Result<CapturedFrame, String> {
        self.log.lock().unwrap().push("capture".into());
        Ok(CapturedFrame {
            transform: DisplayTransform {
                display_id: 3,
                display_frame: Rect {
                    x: 0.,
                    y: 0.,
                    width: 1000.,
                    height: 800.,
                },
                window_id: 2,
                window_frame: Rect {
                    x: 100.,
                    y: 100.,
                    width: 400.,
                    height: 300.,
                },
                pixel_width: 400,
                pixel_height: 300,
            },
            png: b"\x89PNG\r\n\x1a\nSYNTHETIC_IMAGE".to_vec(),
        })
    }
    fn preflight(
        &mut self,
        _: &Target,
        _: Option<&DisplayTransform>,
        _: bool,
    ) -> Result<(), String> {
        Ok(())
    }
    fn perform(
        &mut self,
        _: &Target,
        action: &Action,
        _: Option<(i32, i32)>,
    ) -> Result<(), String> {
        if let Action::Text { text, .. } = action {
            self.log.lock().unwrap().push(text.clone());
        }
        if self.lose_ack {
            Err("synthetic acknowledgement loss".into())
        } else {
            Ok(())
        }
    }
}
fn queue(lose_ack: bool) -> (DesktopQueue, Arc<Mutex<Vec<String>>>) {
    let log = Arc::new(Mutex::new(vec![]));
    let other = log.clone();
    (
        DesktopQueue::start(move || {
            Ok(Box::new(InertDesktop {
                log: other,
                lose_ack,
            }))
        })
        .unwrap(),
        log,
    )
}
fn call(id: &str, arguments: serde_json::Value) -> ModelReply {
    ModelReply::FunctionCall(FunctionCall {
        call_id: id.into(),
        name: FUNCTION_NAME.into(),
        arguments_json: serde_json::to_vec(&arguments).unwrap(),
    })
}
fn capture(id: &str) -> ModelReply {
    call(
        id,
        serde_json::json!({"deadline_ms":1000,"actions":[{"action":"screenshot"}]}),
    )
}
struct Script {
    replies: VecDeque<ModelReply>,
    calls: usize,
}
impl OrdinaryModel for Script {
    fn next<'a>(&'a mut self, _: ModelRequest<'a>) -> ModelFuture<'a> {
        self.calls += 1;
        let reply = self
            .replies
            .pop_front()
            .ok_or("unexpected provider request".into());
        Box::pin(async move { reply })
    }
}

/// Builds text arguments from the actual queue-produced observation and verifies
/// provider-facing receipts, image blocks and generated custom-function contract.
struct FixtureModel {
    calls: usize,
    verify_after: bool,
    finish: bool,
}
impl OrdinaryModel for FixtureModel {
    fn next<'a>(&'a mut self, request: ModelRequest<'a>) -> ModelFuture<'a> {
        self.calls += 1;
        let turn = self.calls;
        Box::pin(async move {
            assert_eq!(request.goal.ids, ids());
            assert_eq!(request.function.name, FUNCTION_NAME);
            assert!(request.function.parameters["properties"]["actions"].is_object());
            assert!(
                request.function.parameters["properties"]
                    .get("ids")
                    .is_none()
            );
            if turn == 1 {
                assert_eq!(request.images().count(), 0);
                return Ok(capture("call-observe"));
            }
            let receipts = request.receipts();
            assert_eq!(receipts[0].call_id, "call-observe");
            let encoded = serde_json::to_string(&receipts).unwrap();
            assert!(
                !encoded.contains("SYNTHETIC_IMAGE")
                    && !encoded.contains("\"image\":")
                    && !encoded.contains("png")
            );
            let image = request.images().last().unwrap();
            assert_eq!(image.mime_type, "image/png");
            assert_eq!(image.png, b"\x89PNG\r\n\x1a\nSYNTHETIC_IMAGE");
            if turn == 2 {
                let mut actions = vec![
                    serde_json::json!({"action":"text","observation_id":image.observation_id,"text":"Hello — こんにちは"}),
                ];
                if self.verify_after {
                    actions.push(serde_json::json!({"action":"screenshot"}));
                }
                return Ok(call(
                    "call-text",
                    serde_json::json!({"deadline_ms":1000,"actions":actions}),
                ));
            }
            assert_eq!(receipts[1].call_id, "call-text");
            Ok(ModelReply::Finish {
                completed: self.finish,
                summary: "Fixture model claim based on images".into(),
            })
        })
    }
}

#[tokio::test]
async fn synthetic_model_loop_delivers_images_and_receipts_and_returns_compact_claim() {
    let (q, log) = queue(false);
    let mut provider = FixtureModel {
        calls: 0,
        verify_after: true,
        finish: true,
    };
    let mut private_context = context();
    let outcome = run_worker(
        &mut provider,
        &q,
        grant(),
        &mut private_context,
        StopToken::default(),
        limits(4),
    )
    .await
    .unwrap();
    assert_eq!(outcome.status, WorkerStatus::Done);
    assert_eq!(private_context.history().len(), 2);
    assert!(
        private_context
            .history()
            .back()
            .unwrap()
            .results
            .iter()
            .any(|r| r.observation.as_ref().is_some_and(|o| !o.image.is_empty()))
    );
    assert_eq!(provider.calls, 3);
    assert_eq!(outcome.ids, ids());
    assert_eq!(outcome.evidence_ids.len(), 2);
    assert_eq!(outcome.last_batch.as_ref().unwrap().batch_id, "call-text");
    assert_eq!(
        outcome.last_batch.as_ref().unwrap().statuses,
        [ActionStatus::Completed, ActionStatus::Completed]
    );
    assert_eq!(
        *log.lock().unwrap(),
        ["capture", "Hello — こんにちは", "capture"]
    );
    let json = serde_json::to_string(&outcome).unwrap();
    assert!(!json.contains("SYNTHETIC_IMAGE") && !json.contains("transform"));
}
#[tokio::test]
async fn completion_without_post_input_observation_is_stuck() {
    let (q, log) = queue(false);
    let mut provider = FixtureModel {
        calls: 0,
        verify_after: false,
        finish: true,
    };
    let outcome = run_worker(
        &mut provider,
        &q,
        grant(),
        &mut context(),
        StopToken::default(),
        limits(4),
    )
    .await
    .unwrap();
    assert_eq!(outcome.status, WorkerStatus::Stuck);
    assert!(outcome.summary.contains("fresh observation"));
    assert_eq!(*log.lock().unwrap(), ["capture", "Hello — こんにちは"]);
}
#[tokio::test]
async fn unknown_effect_returns_receipt_without_another_model_request() {
    let (q, log) = queue(true);
    let mut provider = FixtureModel {
        calls: 0,
        verify_after: true,
        finish: true,
    };
    let outcome = run_worker(
        &mut provider,
        &q,
        grant(),
        &mut context(),
        StopToken::default(),
        limits(4),
    )
    .await
    .unwrap();
    assert_eq!(outcome.status, WorkerStatus::Stuck);
    assert_eq!(provider.calls, 2);
    let receipt = outcome.last_batch.unwrap();
    assert!(receipt.input_halted);
    assert_eq!(
        receipt.statuses,
        [ActionStatus::UnknownEffect, ActionStatus::Skipped]
    );
    assert_eq!(*log.lock().unwrap(), ["capture", "Hello — こんにちは"]);
}
#[tokio::test]
async fn malformed_unsupported_and_scope_injection_calls_never_dispatch() {
    let bad = [
        ModelReply::FunctionCall(FunctionCall {
            call_id: "call".into(),
            name: "computer_use".into(),
            arguments_json: b"{}".to_vec(),
        }),
        ModelReply::FunctionCall(FunctionCall {
            call_id: "call".into(),
            name: FUNCTION_NAME.into(),
            arguments_json: b"broken".to_vec(),
        }),
        call(
            "call",
            serde_json::json!({"deadline_ms":1000,"actions":[{"action":"execute","code":"anything"}]}),
        ),
        call(
            "call",
            serde_json::json!({"deadline_ms":1000,"ids":{"task_id":"other"},"actions":[{"action":"screenshot"}]}),
        ),
        ModelReply::FunctionCall(FunctionCall {
            call_id: "call".into(),
            name: FUNCTION_NAME.into(),
            arguments_json: vec![b' '; 65537],
        }),
    ];
    for reply in bad {
        let (q, log) = queue(false);
        let mut provider = Script {
            replies: VecDeque::from([reply]),
            calls: 0,
        };
        assert_eq!(
            run_worker(
                &mut provider,
                &q,
                grant(),
                &mut context(),
                StopToken::default(),
                limits(2)
            )
            .await
            .unwrap()
            .status,
            WorkerStatus::Stuck
        );
        assert_eq!(provider.calls, 1);
        assert!(log.lock().unwrap().is_empty());
    }
}
#[tokio::test]
async fn repeated_call_ids_and_turn_budget_cannot_replay_or_loop() {
    let (q, log) = queue(false);
    let mut provider = Script {
        replies: VecDeque::from([capture("same"), capture("same")]),
        calls: 0,
    };
    let outcome = run_worker(
        &mut provider,
        &q,
        grant(),
        &mut context(),
        StopToken::default(),
        limits(3),
    )
    .await
    .unwrap();
    assert!(outcome.summary.contains("Repeated"));
    assert_eq!(*log.lock().unwrap(), ["capture"]);
    let (q, log) = queue(false);
    let mut provider = Script {
        replies: VecDeque::from([capture("one"), capture("two")]),
        calls: 0,
    };
    let outcome = run_worker(
        &mut provider,
        &q,
        grant(),
        &mut context(),
        StopToken::default(),
        limits(1),
    )
    .await
    .unwrap();
    assert!(outcome.summary.contains("budget"));
    assert_eq!(provider.calls, 1);
    assert_eq!(*log.lock().unwrap(), ["capture"]);
}
struct PendingProvider {
    entered: Option<tokio::sync::oneshot::Sender<()>>,
    fail: bool,
}
impl OrdinaryModel for PendingProvider {
    fn next<'a>(&'a mut self, _: ModelRequest<'a>) -> ModelFuture<'a> {
        Box::pin(async move {
            if let Some(entered) = self.entered.take() {
                let _ = entered.send(());
            }
            if self.fail {
                Err("secret credential error must not leak".into())
            } else {
                std::future::pending().await
            }
        })
    }
}
#[tokio::test]
async fn pending_provider_deadlines_and_transport_errors_are_stuck_without_retry() {
    for fail in [false, true] {
        let (q, log) = queue(false);
        let mut provider = PendingProvider {
            entered: None,
            fail,
        };
        let bounds =
            WorkerLimits::new(2, Duration::from_millis(50), Duration::from_millis(10)).unwrap();
        let outcome = run_worker(
            &mut provider,
            &q,
            grant(),
            &mut context(),
            StopToken::default(),
            bounds,
        )
        .await
        .unwrap();
        assert_eq!(outcome.status, WorkerStatus::Stuck);
        assert!(!outcome.summary.contains("secret"));
        assert!(log.lock().unwrap().is_empty());
    }
}
#[tokio::test]
async fn stop_interrupts_pending_provider_without_dispatch() {
    let (q, log) = queue(false);
    let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
    let stop = StopToken::default();
    let other_stop = stop.clone();
    let task = tokio::spawn(async move {
        let mut provider = PendingProvider {
            entered: Some(entered_tx),
            fail: false,
        };
        run_worker(
            &mut provider,
            &q,
            grant(),
            &mut context(),
            other_stop,
            limits(2),
        )
        .await
        .unwrap()
    });
    entered_rx.await.unwrap();
    stop.stop();
    let outcome = tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(outcome.status, WorkerStatus::Stopped);
    assert!(log.lock().unwrap().is_empty());
}
#[tokio::test]
async fn image_free_completion_claim_is_not_done() {
    let (q, log) = queue(false);
    let mut provider = Script {
        replies: VecDeque::from([ModelReply::Finish {
            completed: true,
            summary: "Already done".into(),
        }]),
        calls: 0,
    };
    let outcome = run_worker(
        &mut provider,
        &q,
        grant(),
        &mut context(),
        StopToken::default(),
        limits(2),
    )
    .await
    .unwrap();
    assert_eq!(outcome.status, WorkerStatus::Stuck);
    assert!(log.lock().unwrap().is_empty());
}
