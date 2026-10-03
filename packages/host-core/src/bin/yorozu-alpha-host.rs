//! JSON-lines Rust alpha owner; provider execution remains the existing Node adapter.
use serde_json::{Value, json};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, SyncSender};
use std::time::{Duration, Instant};
use yorozu_host_core::alpha::{Conversation, FRAME_BYTES};

enum Input {
    Request(Value),
    Worker(String, Value),
    WorkerClosed(String),
    Closed,
}
fn output(value: Value) -> io::Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &value).map_err(io::Error::other)?;
    out.write_all(b"\n")?;
    out.flush()
}
fn event(value: Value) -> io::Result<()> {
    output(json!({"version":1,"event":value}))
}
fn read_frames(reader: impl Read, sender: SyncSender<Input>, run: Option<String>) {
    let mut reader = BufReader::new(reader);
    loop {
        let mut bytes = Vec::new();
        match Read::by_ref(&mut reader)
            .take(FRAME_BYTES + 1)
            .read_until(b'\n', &mut bytes)
        {
            Ok(0) | Err(_) => break,
            Ok(_) if bytes.len() as u64 > FRAME_BYTES || !bytes.ends_with(b"\n") => break,
            Ok(_) => match serde_json::from_slice(&bytes) {
                Ok(value) => {
                    let input = if let Some(run) = &run {
                        Input::Worker(run.clone(), value)
                    } else {
                        Input::Request(value)
                    };
                    if sender.send(input).is_err() {
                        return;
                    }
                }
                Err(_) => break,
            },
        }
    }
    let _ = sender.send(if let Some(run) = run {
        Input::WorkerClosed(run)
    } else {
        Input::Closed
    });
}
struct Worker {
    child: Child,
    run: String,
    terminal: bool,
    output_closed: bool,
    started: Instant,
    stopping: Option<Instant>,
}
fn send(child: &mut Child, value: &Value) -> io::Result<()> {
    let input = child.stdin.as_mut().ok_or(io::ErrorKind::BrokenPipe)?;
    serde_json::to_writer(&mut *input, value).map_err(io::Error::other)?;
    input.write_all(b"\n")?;
    input.flush()
}
fn launch(
    node: &str,
    script: &str,
    owner: &Conversation,
    run: &str,
    request: &Value,
    secretary: bool,
    sender: SyncSender<Input>,
) -> io::Result<Worker> {
    let mut child = Command::new(node)
        .arg(script)
        .current_dir(&owner.workspace)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let stdout = child.stdout.take().ok_or(io::ErrorKind::BrokenPipe)?;
    let key = run.to_owned();
    std::thread::spawn(move || read_frames(stdout, sender, Some(key)));
    if let Err(error) = send(
        &mut child,
        &json!({"version":1,"op":"run","runId":run,"cwd":owner.workspace,"text":request["text"],
            "secretary":secretary,"turn":request["turn"]}),
    ) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }
    Ok(Worker {
        child,
        run: run.to_owned(),
        terminal: false,
        output_closed: false,
        started: Instant::now(),
        stopping: None,
    })
}
fn run() -> io::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() == 3 && args[0] == "--secretary-init" {
        let root = Conversation::prepare_secretary(Path::new(&args[1]), Path::new(&args[2]))?;
        return output(json!({"root":root,"workspace":args[2]}));
    }
    let secretary = args.first().is_some_and(|arg| arg == "--secretary");
    let (mut owner, node, script) = if secretary && args.len() == 6 {
        (
            Conversation::open_secretary(Path::new(&args[1]), &args[2], Path::new(&args[3]))?,
            &args[4],
            &args[5],
        )
    } else if !secretary && args.len() == 3 {
        (Conversation::open(Path::new(&args[0]))?, &args[1], &args[2])
    } else {
        return Err(io::ErrorKind::InvalidInput.into());
    };
    if !Path::new(script).is_absolute() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let (sender, receiver) = mpsc::sync_channel(32);
    let input_sender = sender.clone();
    std::thread::spawn(move || read_frames(io::stdin(), input_sender, None));
    let mut worker: Option<Worker> = None;
    let mut closing = false;
    loop {
        if closing && worker.is_none() {
            return Ok(());
        }
        match receiver.recv_timeout(Duration::from_millis(50)) {
            Ok(Input::Request(request)) if !closing => {
                let id = request["id"]
                    .as_str()
                    .filter(|id| !id.is_empty() && id.len() <= 128)
                    .ok_or(io::ErrorKind::InvalidData)?;
                let mut emitted = None;
                let result = if request["version"] != 1 {
                    json!({"error":"unsupported-version"})
                } else {
                    match request["op"].as_str() {
                        Some("snapshot") => owner.snapshot(),
                        Some("submit") => {
                            // A provider with a retained terminal result still exits before new work.
                            if worker.is_some()
                                && owner.active.is_none()
                                && !request["runId"]
                                    .as_str()
                                    .is_some_and(|run| owner.has_run(run))
                            {
                                json!({"error":"worker-busy"})
                            } else {
                                let (result, event) = owner.submit(&request)?;
                                emitted = event;
                                result
                            }
                        }
                        Some("steer") if secretary => {
                            let (result, event) = owner.steer(&request)?;
                            emitted = event;
                            result
                        }
                        Some("respond") if secretary => {
                            if let Some(current) = &mut worker
                                && !current.terminal
                                && owner.active.as_deref() == request["runId"].as_str()
                                && request["requestId"]
                                    .as_str()
                                    .is_some_and(|id| !id.is_empty() && id.len() <= 128)
                            {
                                // Record UI decisions before delivering them back to the provider.
                                owner.record(&current.run, "response", None, Some(json!({"requestId":request["requestId"],"value":request["value"]})))?;
                                // Stop can settle a card while the worker is exiting. A closed
                                // input must not discard its buffered terminal evidence.
                                let delivered = send(
                                    &mut current.child,
                                    &json!({"version":1,"op":"respond","runId":current.run,
                                    "requestId":request["requestId"],"value":request["value"]}),
                                ).is_ok();
                                json!({"delivered":delivered})
                            } else {
                                json!({"delivered":false})
                            }
                        }
                        Some("stop") => {
                            let (result, event) = owner.stop(&request)?;
                            emitted = event;
                            result
                        }
                        _ => json!({"error":"invalid-operation"}),
                    }
                };
                output(json!({"version":1,"id":id,"result":result}))?;
                if let Some(emitted) = emitted {
                    let kind = emitted["kind"].clone();
                    let run = emitted["runId"].as_str().unwrap().to_owned();
                    event(emitted)?;
                    if kind == "accepted" {
                        match launch(
                            node,
                            script,
                            &owner,
                            &run,
                            &request,
                            secretary,
                            sender.clone(),
                        ) {
                            Ok(child) => worker = Some(child),
                            Err(_) => {
                                event(owner.record(
                                    &run,
                                    "unconfirmed",
                                    Some("Provider worker launch was not confirmed."),
                                    None,
                                )?)?;
                                owner.active = None;
                            }
                        }
                    } else if kind == "steer_requested" {
                        if let Some(current) = &mut worker {
                            // A failed write remains uncertain in the durable intent ledger.
                            if send(
                                &mut current.child,
                                &json!({"version":1,"op":"steer","runId":run,
                                "deliveryId":request["deliveryId"],"text":request["text"],"attachments":request["attachments"]}),
                            ).is_err() {
                                event(owner.record(&run, "steer_result", None,
                                    Some(json!({"deliveryId":request["deliveryId"],"accepted":null})))?)?;
                            }
                        }
                    } else if kind == "stop_requested"
                        && let Some(worker) = &mut worker
                    {
                        worker.stopping = Some(Instant::now());
                        let _ = send(
                            &mut worker.child,
                            &json!({"version":1,"op":"stop","runId":run}),
                        );
                    }
                }
            }
            Ok(Input::Worker(run, packet)) => {
                if let Some(current) = &mut worker
                    && current.run == run
                    && !current.terminal
                {
                    if packet["version"] != 1 || packet["runId"] != run {
                        continue;
                    }
                    let kind = packet["kind"].as_str().unwrap_or("");
                    let proof = packet["data"]["evidence"].as_str().unwrap_or("");
                    let valid = match kind {
                        "running" | "update" | "activity" | "unconfirmed" => true,
                        "session" => {
                            secretary
                                && packet["data"]["sessionId"]
                                    .as_str()
                                    .is_some_and(|id| !id.is_empty() && id.len() <= 256)
                        }
                        "request" => {
                            secretary
                                && ["approve", "ask", "beforeTool"]
                                    .contains(&packet["data"]["type"].as_str().unwrap_or(""))
                        }
                        "tool_boundary" => secretary,
                        "steer_result" => owner.accepts_steer_result(&run, &packet),
                        "completed" => proof == "provider-terminal",
                        "stopped" => ["provider-terminal", "process-exited"].contains(&proof),
                        _ => false,
                    };
                    if !valid {
                        continue;
                    }
                    event(owner.record(
                        &run,
                        kind,
                        packet["text"].as_str(),
                        packet.get("data").cloned(),
                    )?)?;
                    if ["completed", "stopped", "unconfirmed"].contains(&kind) {
                        current.terminal = true;
                        current.stopping = Some(Instant::now());
                        current.child.stdin.take();
                        owner.active = None;
                    }
                }
            }
            Ok(Input::WorkerClosed(run)) => {
                if let Some(current) = &mut worker
                    && current.run == run
                {
                    current.output_closed = true;
                    current.child.stdin.take();
                    current.stopping.get_or_insert_with(Instant::now);
                }
            }
            Ok(Input::Closed) => {
                closing = true;
                if let Some(current) = &mut worker {
                    current.stopping = Some(Instant::now());
                    let _ = send(
                        &mut current.child,
                        &json!({"version":1,"op":"stop","runId":current.run}),
                    );
                }
            }
            _ => {}
        }
        if let Some(current) = &mut worker {
            if !current.terminal
                && current.started.elapsed()
                    > Duration::from_secs(if secretary { 24 * 60 * 60 } else { 190 })
                && current.stopping.is_none()
            {
                event(owner.record(
                    &current.run,
                    "stop_requested",
                    Some("Task time limit reached."),
                    None,
                )?)?;
                current.stopping = Some(Instant::now());
                let _ = send(
                    &mut current.child,
                    &json!({"version":1,"op":"stop","runId":current.run}),
                );
            }
            if current
                .stopping
                .is_some_and(|t| t.elapsed() > Duration::from_secs(5))
            {
                current.child.stdin.take();
            }
            if current
                .stopping
                .is_some_and(|t| t.elapsed() > Duration::from_secs(10))
            {
                let _ = current.child.kill();
            }
            // WorkerClosed follows every packet on this producer's FIFO channel.
            // Observed child exit alone cannot discard already queued terminal evidence.
            if current.child.try_wait()?.is_some() && current.output_closed {
                // Process exit of the bridge does not prove its provider grandchild ceased.
                if !current.terminal {
                    event(owner.record(
                        &current.run,
                        "unconfirmed",
                        Some("Worker connection closed without provider terminal evidence."),
                        None,
                    )?)?;
                    owner.active = None;
                }
                worker = None;
            }
        }
    }
}
fn main() {
    if run().is_err() {
        eprintln!("alpha-host-unavailable");
        std::process::exit(1);
    }
}
