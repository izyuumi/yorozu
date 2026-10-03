//! Opt-in manual native fixture. Never run as part of automated tests.
#[cfg(target_os = "macos")]
#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    use screencapturekit::prelude::*;
    use std::{path::Path, time::Duration};
    use yorozu_computer_use::{
        contract::*,
        executor::*,
        macos::{MacDesktop, permissions},
        worker::WorkerContext,
    };
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 2 || args[1] != "--coordinated" {
        return Err("Requires --coordinated after parent coordination: foreground only the task-owned Yorozu Computer Use Fixture.txt in TextEdit, caret in its blank line".into());
    }
    if permissions() != (true, true) {
        return Err(
            "existing Screen Recording/Accessibility access unavailable; no prompts requested"
                .into(),
        );
    }
    let content = SCShareableContent::get()?;
    let matches: Vec<_> = content
        .windows()
        .into_iter()
        .filter(|w| {
            w.is_on_screen()
                && w.window_layer() == 0
                && w.title().as_deref() == Some("Yorozu Computer Use Fixture.txt")
                && w.owning_application()
                    .is_some_and(|a| a.bundle_identifier() == "com.apple.TextEdit")
        })
        .collect();
    if matches.len() != 1 {
        return Err("Need exactly one task-owned fixture window, unchanged title".into());
    }
    let window = &matches[0];
    let frame = window.frame();
    let display = content
        .displays()
        .into_iter()
        .find(|d| {
            let f = d.frame();
            frame.origin.x >= f.origin.x
                && frame.origin.y >= f.origin.y
                && frame.origin.x + frame.size.width <= f.origin.x + f.size.width
                && frame.origin.y + frame.size.height <= f.origin.y + f.size.height
        })
        .ok_or("Fixture window must fit inside one display")?;
    let target = Target {
        process_id: window
            .owning_application()
            .ok_or("missing fixture process")?
            .process_id(),
        window_id: window.window_id(),
        display_id: display.display_id(),
    };
    let ids = TaskIds {
        task_id: "textedit-fixture".into(),
        parent_id: "secretary".into(),
        origin_id: "coordinated-manual-fixture".into(),
        attempt_id: uuid::Uuid::new_v4().to_string(),
    };
    let grant = Grant::new(
        ids.clone(),
        target.clone(),
        [ActionKind::Screenshot, ActionKind::Text, ActionKind::Wait],
        Duration::from_secs(30),
        4,
    )?;
    let queue = DesktopQueue::start(|| Ok(Box::new(MacDesktop::new()?)))?;
    let stop = StopToken::default();
    let mut worker = WorkerContext::new(WorkerGoal { ids: ids.clone(), goal: "Type fixed English/Japanese fixture text".into(),
        context: "Only the task-owned TextEdit fixture document; no save/close, keys, clicks or other apps".into(),
        authorization: "Parent-coordinated fixture run with existing permissions".into() })?;
    let batch = |name: &str, actions| DesktopBatch {
        ids: ids.clone(),
        batch_id: name.into(),
        deadline_ms: 10000,
        actions,
    };
    let before = queue
        .submit(
            batch("before", vec![Action::Screenshot {}]),
            grant.clone(),
            stop.clone(),
        )
        .await?;
    let observation = before
        .results
        .first()
        .and_then(|r| r.observation.as_ref())
        .ok_or("before observation failed")?;
    let observation_id = observation.observation_id.clone();
    // No input until exact foreground-window preflight succeeds.
    let front = objc2_app_kit::NSWorkspace::sharedWorkspace().frontmostApplication();
    if front.is_none_or(|app| app.processIdentifier() != target.process_id) {
        return Err("Foreground the isolated TextEdit fixture before running".into());
    }
    let out = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("target/textedit-fixture")
        .join(&ids.attempt_id);
    std::fs::create_dir_all(&out)?;
    std::fs::write(out.join("before.png"), &observation.image)?;
    worker.record(before)?;
    let after = queue
        .submit(
            batch(
                "type-and-observe",
                vec![
                    Action::Text {
                        observation_id,
                        text: "Hello Yorozu — こんにちは、よろず".into(),
                    },
                    Action::Wait { milliseconds: 250 },
                    Action::Screenshot {},
                ],
            ),
            grant,
            stop,
        )
        .await?;
    let completed = after.rejection.is_none()
        && after.results.len() == 3
        && after
            .results
            .iter()
            .all(|r| r.status == ActionStatus::Completed);
    if let Some(o) = after.results.iter().find_map(|r| r.observation.as_ref()) {
        std::fs::write(out.join("after.png"), &o.image)?;
    }
    worker.record(after)?;
    let outcome = worker.outcome(WorkerStatus::Stuck, if completed {
        "Native dispatch acknowledged. Visual verification of English/Japanese in after.png is required; no live model agent was used."
    } else { "Native fixture stopped. Inspect results and evidence; do not replay." }.into())?;
    println!("{}", serde_json::to_string_pretty(&outcome)?);
    println!("Fixture-only evidence: {}", out.display());
    if !completed {
        return Err("fixture did not complete; no automatic replay".into());
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("macOS 14+ required");
}
