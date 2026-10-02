use rand_core::{OsRng, RngCore};
use serde_json::{Value, json};
use std::io::{self, BufRead, Read, Write};
use std::path::Path;
use std::sync::{Arc, Mutex};
use yorozu_host_core::transport::{Emit, Transports};
use yorozu_host_core::{AttachmentStore, history::History, now_ms};

fn run() -> io::Result<()> {
    let mut args = std::env::args().skip(1);
    let mode = args.next().ok_or(io::ErrorKind::InvalidInput)?;
    let dir = args.next().ok_or(io::ErrorKind::InvalidInput)?;
    if args.next().is_some() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    if mode == "operational-prepare" {
        serde_json::to_writer(
            io::stdout().lock(),
            &yorozu_host_core::operational::prepare(Path::new(&dir))?,
        )
        .map_err(io::Error::other)?;
        return Ok(());
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
        let mut prepared: Option<(String, Vec<u8>)> = None;
        let mut serial = 0u64;
        let mut epoch = [0u8; 16];
        OsRng
            .try_fill_bytes(&mut epoch)
            .map_err(|_| io::ErrorKind::InvalidData)?;
        let epoch = u128::from_le_bytes(epoch);
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
            let bytes = if request["op"] == "bridge_result" {
                if prepared
                    .as_ref()
                    .is_some_and(|(token, _)| request["token"] == *token)
                {
                    prepared.take().unwrap().1
                } else {
                    serde_json::to_vec(&json!({"error":"response-unconfirmed"}))
                        .map_err(io::Error::other)?
                }
            } else {
                prepared = None;
                let bytes =
                    serde_json::to_vec(&store.request(&request)).map_err(io::Error::other)?;
                if bytes.len() + 4096 > 34 * 1024 * 1024 {
                    serde_json::to_vec(&json!({"error":"response-unconfirmed"}))
                        .map_err(io::Error::other)?
                } else if bytes.len() > 1024 * 1024 - 4096 {
                    serial = serial.checked_add(1).ok_or(io::ErrorKind::InvalidData)?;
                    let token = format!("reply:{epoch:032x}:{serial}");
                    let metadata = json!({"bridgeToken":token,"responseBytes":bytes.len()+4096});
                    prepared = Some((token, bytes));
                    serde_json::to_vec(&metadata).map_err(io::Error::other)?
                } else {
                    bytes
                }
            };
            // One bounded prepared response belongs to this process. Preserve result bytes.
            write!(
                &mut output,
                "{{\"id\":{},\"result\":",
                serde_json::to_string(id).map_err(io::Error::other)?
            )?;
            output.write_all(&bytes)?;
            output.write_all(b"}\n")?;
            output.flush()?;
        }
    }
    if mode != "attachments" {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let mut store = AttachmentStore::open(Path::new(&dir))?;
    let mut operations: Option<History> = None;
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
    let mut relays = yorozu_host_core::relay::Relays::new(write_frame.clone());
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
        let result = if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("relay_"))
        {
            match relays.request(&request) {
                Some(result) => result,
                None => continue,
            }
        } else if request
            .get("op")
            .and_then(Value::as_str)
            .is_some_and(|op| op.starts_with("transport_"))
        {
            transports.request(&request)
        } else if request["op"].as_str().is_some_and(|op| {
            ["accepted_", "stop_", "admission_", "outbox_"]
                .iter()
                .any(|prefix| op.starts_with(prefix))
        }) {
            // Legacy CLI callers use the same root owner and component locks as production.
            if operations.is_none() {
                match History::open(Path::new(&dir)) {
                    Ok(store) => operations = Some(store),
                    Err(_) => {
                        write_frame(
                            json!({"id":id,"result":{"error":"operational-storage-failed"}}),
                        )?;
                        continue;
                    }
                }
            }
            operations.as_mut().unwrap().request(&request)
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
