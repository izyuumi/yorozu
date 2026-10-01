use serde_json::{Value, json};
use std::io::{self, BufRead, Read, Write};
use std::path::Path;
use std::sync::{Arc, Mutex};
use yorozu_host_core::transport::{Emit, Transports};
use yorozu_host_core::{
    AttachmentStore, accepted::Accepted, admission::Admissions, history::History, now_ms,
    outbox::ChannelOutbox, stops::Stops,
};

fn run() -> io::Result<()> {
    let mut args = std::env::args().skip(1);
    let mode = args.next().ok_or(io::ErrorKind::InvalidInput)?;
    let dir = args.next().ok_or(io::ErrorKind::InvalidInput)?;
    if args.next().is_some() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    if mode == "thread-index" {
        let mut bytes = Vec::new();
        io::stdin()
            .take(32 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 32 * 1024 * 1024 {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let request: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        serde_json::to_writer(
            io::stdout().lock(),
            &yorozu_host_core::thread_index::request(Path::new(&dir), &request),
        )
        .map_err(io::Error::other)?;
        return Ok(());
    }
    if mode == "history" {
        let mut store = History::open(Path::new(&dir))?;
        let mut input = io::stdin().lock();
        let mut output = io::stdout().lock();
        loop {
            let mut bytes = Vec::new();
            let length = Read::by_ref(&mut input)
                .take(32 * 1024 * 1024 + 1)
                .read_until(b'\n', &mut bytes)?;
            if length == 0 {
                return Ok(());
            }
            if length > 32 * 1024 * 1024 || !bytes.ends_with(b"\n") {
                return Err(io::ErrorKind::InvalidData.into());
            }
            let request: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            let id = request["id"]
                .as_str()
                .filter(|id| !id.is_empty() && id.len() <= 128)
                .ok_or(io::ErrorKind::InvalidData)?;
            let result = store.request(&request);
            serde_json::to_writer(&mut output, &json!({"id":id,"result":result}))
                .map_err(io::Error::other)?;
            output.write_all(b"\n")?;
            output.flush()?;
        }
    }
    if mode != "attachments" {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let mut store = AttachmentStore::open(Path::new(&dir))?;
    let mut outbox: Option<ChannelOutbox> = None;
    let mut admissions: Option<Admissions> = None;
    let mut stops: Option<Stops> = None;
    let mut accepted: Option<Accepted> = None;
    let mut input = io::stdin().lock();
    let output = Arc::new(Mutex::new(io::stdout()));
    let write_frame: Emit = Arc::new(move |frame| {
        let mut output = output
            .lock()
            .map_err(|_| io::Error::other("output unavailable"))?;
        serde_json::to_writer(&mut *output, &frame).map_err(io::Error::other)?;
        output.write_all(b"\n")?;
        output.flush()
    });
    let mut transports = Transports::new(Path::new(&dir), write_frame.clone());
    loop {
        // Read bounded frames without allocating an unbounded line from a broken bridge.
        let mut bytes = Vec::new();
        let mut complete = false;
        while bytes.len() <= 32 * 1024 * 1024 {
            let part = input.fill_buf()?;
            if part.is_empty() {
                if bytes.is_empty() {
                    return Ok(());
                }
                break;
            }
            let length = part
                .iter()
                .position(|b| *b == b'\n')
                .map_or(part.len(), |n| n + 1);
            if bytes.len() + length > 32 * 1024 * 1024 {
                return Err(io::ErrorKind::InvalidData.into());
            }
            complete = part[length - 1] == b'\n';
            bytes.extend_from_slice(&part[..length]);
            input.consume(length);
            if complete {
                break;
            }
        }
        if !complete {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        let request: Value = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty() && s.len() <= 128)
            .ok_or(io::ErrorKind::InvalidData)?;
        let result = if request
            .get("op")
            .and_then(Value::as_str)
            .is_some_and(|op| op.starts_with("transport_"))
        {
            transports.request(&request)
        } else if request
            .get("op")
            .and_then(Value::as_str)
            .is_some_and(|op| op.starts_with("accepted_"))
        {
            if accepted.is_none() {
                match Accepted::open(Path::new(&dir)) {
                    Ok(store) => accepted = Some(store),
                    Err(_) => {
                        write_frame(json!({"id":id,"result":{"error":"accepted-storage-failed"}}))?;
                        continue;
                    }
                }
            }
            accepted.as_mut().unwrap().request(&request)
        } else if request
            .get("op")
            .and_then(Value::as_str)
            .is_some_and(|op| op.starts_with("stop_"))
        {
            if stops.is_none() {
                match Stops::open(Path::new(&dir)) {
                    Ok(store) => stops = Some(store),
                    Err(_) => {
                        write_frame(json!({"id":id,"result":{"error":"stop-storage-failed"}}))?;
                        continue;
                    }
                }
            }
            stops.as_mut().unwrap().request(&request)
        } else if request
            .get("op")
            .and_then(Value::as_str)
            .is_some_and(|op| op.starts_with("admission_"))
        {
            if admissions.is_none() {
                match Admissions::open(Path::new(&dir)) {
                    Ok(store) => admissions = Some(store),
                    Err(_) => {
                        write_frame(
                            json!({"id":id,"result":{"error":"admission-storage-failed"}}),
                        )?;
                        continue;
                    }
                }
            }
            admissions.as_mut().unwrap().request(&request)
        } else if request
            .get("op")
            .and_then(Value::as_str)
            .is_some_and(|op| op.starts_with("outbox_"))
        {
            if outbox.is_none() {
                match ChannelOutbox::open(Path::new(&dir)) {
                    Ok(store) => outbox = Some(store),
                    Err(_) => {
                        write_frame(json!({"id":id,"result":{"error":"channel-storage-failed"}}))?;
                        continue;
                    }
                }
            }
            outbox.as_mut().unwrap().request(&request)
        } else {
            let source = request
                .get("source")
                .and_then(Value::as_str)
                .ok_or(io::ErrorKind::InvalidData)?;
            let thread = request
                .get("threadId")
                .and_then(Value::as_str)
                .ok_or(io::ErrorKind::InvalidData)?;
            match request.get("op").and_then(Value::as_str) {
                Some("chunk") => store.chunk(source, thread, &request["data"], now_ms()),
                Some("assemble") => {
                    let message = request
                        .get("messageId")
                        .and_then(Value::as_str)
                        .ok_or(io::ErrorKind::InvalidData)?;
                    let deadline = request
                        .get("deadline")
                        .and_then(Value::as_u64)
                        .unwrap_or(u64::MAX);
                    store.assemble(source, message, thread, &request["descriptors"], deadline)
                }
                _ => return Err(io::ErrorKind::InvalidData.into()),
            }
        };
        write_frame(json!({"id":id,"result":result}))?;
    }
}
fn main() {
    if run().is_err() {
        eprintln!("Rust host worker stopped; request remains unconfirmed.");
        std::process::exit(1);
    }
}
