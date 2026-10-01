//! Private native JSON-lines transport. Provider or UI code does not own socket IO.
use serde_json::{Value, json};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub type Emit = Arc<dyn Fn(Value) -> io::Result<()> + Send + Sync>;
pub const FRAME_BYTES: usize = 32 * 1024 * 1024;
pub const INPUT_BYTES: usize = 64 * 1024 * 1024;
pub const PEERS: usize = 16;

#[cfg(unix)]
mod unix {
    use super::*;
    use crate::{private_dir, private_open};
    use std::collections::HashMap;
    use std::fs::{self, File};
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::thread::{self, JoinHandle};
    use std::time::Duration;

    type Peer = Arc<Mutex<UnixStream>>;
    struct Shared {
        id: String,
        emit: Emit,
        closing: AtomicBool,
        peers: Mutex<HashMap<String, Peer>>,
        readers: Mutex<Vec<JoinHandle<()>>>,
        input: AtomicUsize,
    }
    impl Shared {
        fn event(&self, device: &str, event: &str, frame: Option<Value>) -> io::Result<()> {
            (self.emit)(
                json!({"type":"transport_event","transportId":self.id,"device":device,"event":event,"frame":frame}),
            )
        }
    }
    struct Reserved<'a> {
        budget: &'a AtomicUsize,
        bytes: usize,
    }
    impl Reserved<'_> {
        fn grow(&mut self, bytes: usize) -> bool {
            if self
                .budget
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |total| {
                    total.checked_add(bytes).filter(|n| *n <= INPUT_BYTES)
                })
                .is_err()
            {
                return false;
            }
            self.bytes += bytes;
            true
        }
    }
    impl Drop for Reserved<'_> {
        fn drop(&mut self) {
            self.budget.fetch_sub(self.bytes, Ordering::AcqRel);
        }
    }
    fn read_peer(stream: UnixStream, shared: Arc<Shared>, device: String) {
        let mut input = BufReader::new(stream);
        'frames: loop {
            if shared.closing.load(Ordering::Acquire) {
                break;
            }
            let mut bytes = Vec::new();
            let mut reserved = Reserved {
                budget: &shared.input,
                bytes: 0,
            };
            loop {
                let Ok(part) = input.fill_buf() else {
                    break 'frames;
                };
                if part.is_empty() {
                    break 'frames;
                }
                let length = part
                    .iter()
                    .position(|b| *b == b'\n')
                    .map_or(part.len(), |n| n + 1);
                if bytes.len() + length > FRAME_BYTES || !reserved.grow(length) {
                    let _ = shared.event(&device, "error", Some(json!("transport-input-limit")));
                    break 'frames;
                }
                let complete = part[length - 1] == b'\n';
                bytes.extend_from_slice(&part[..length]);
                input.consume(length);
                if complete {
                    break;
                }
            }
            if bytes.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            match serde_json::from_slice::<Value>(&bytes) {
                Ok(frame) => {
                    if shared.event(&device, "frame", Some(frame)).is_err() {
                        break;
                    }
                }
                Err(_) => {
                    let _ = shared.event(&device, "error", Some(json!("invalid-local-frame")));
                }
            }
        }
        if let Some(peer) = shared.peers.lock().unwrap().remove(&device) {
            let _ = peer.lock().unwrap().shutdown(std::net::Shutdown::Both);
        }
        let _ = shared.event(&device, "close", None);
    }
    pub struct Transport {
        path: PathBuf,
        inode: u64,
        shared: Arc<Shared>,
        accept: Option<JoinHandle<()>>,
        owner: File,
    }
    impl Transport {
        pub fn open(root: &Path, name: &str, id: &str, emit: Emit) -> io::Result<Self> {
            if id.is_empty()
                || id.len() > 128
                || name.len() > 128
                || !name.ends_with(".sock")
                || !name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            {
                return Err(io::ErrorKind::InvalidInput.into());
            }
            private_dir(root)?;
            // Existing storage permissions are never changed. Refuse a non-private
            // root rather than exposing plaintext through a socket creation window.
            if fs::metadata(root)?.mode() & 0o077 != 0 {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            let owner = private_open(&root.join(format!(".rust-transport-{name}.lock")), false)?;
            owner.try_lock().map_err(io::Error::other)?;
            let path = root.join(name);
            match fs::symlink_metadata(&path) {
                Ok(meta) => {
                    if !meta.file_type().is_socket() {
                        return Err(io::ErrorKind::AlreadyExists.into());
                    }
                    match UnixStream::connect(&path) {
                        Ok(_) => return Err(io::ErrorKind::AddrInUse.into()),
                        Err(e) if e.kind() == io::ErrorKind::ConnectionRefused => {
                            fs::remove_file(&path)?
                        }
                        Err(e) => return Err(e),
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
            // The private parent blocks other users throughout creation. Set the
            // new socket mode before accepting a peer; parent/OS grants stay intact.
            let listener = UnixListener::bind(&path)?;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
            listener.set_nonblocking(true)?;
            let inode = fs::symlink_metadata(&path)?.ino();
            let shared = Arc::new(Shared {
                id: id.into(),
                emit,
                closing: AtomicBool::new(false),
                peers: Mutex::new(HashMap::new()),
                readers: Mutex::new(Vec::new()),
                input: AtomicUsize::new(0),
            });
            let accepting = shared.clone();
            let accept = thread::spawn(move || {
                let mut count = 0_u64;
                for stream in listener.incoming() {
                    if accepting.closing.load(Ordering::Acquire) {
                        break;
                    }
                    let stream = match stream {
                        Ok(stream) => stream,
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            thread::park_timeout(Duration::from_millis(20));
                            continue;
                        }
                        Err(_) => break,
                    };
                    if accepting.peers.lock().unwrap().len() >= PEERS {
                        let _ = stream.shutdown(std::net::Shutdown::Both);
                        continue;
                    }
                    // Darwin can inherit listener nonblocking mode on accepted FDs.
                    // A temporarily empty stream is not a disconnection.
                    if stream.set_nonblocking(false).is_err() {
                        continue;
                    }
                    let Ok(writer) = stream.try_clone() else {
                        continue;
                    };
                    if writer
                        .set_write_timeout(Some(Duration::from_secs(5)))
                        .is_err()
                    {
                        continue;
                    }
                    count += 1;
                    let device = format!("local-{count}");
                    accepting
                        .peers
                        .lock()
                        .unwrap()
                        .insert(device.clone(), Arc::new(Mutex::new(writer)));
                    if accepting.event(&device, "open", None).is_err() {
                        accepting.peers.lock().unwrap().remove(&device);
                        continue;
                    }
                    let peer = accepting.clone();
                    let reader = thread::spawn(move || read_peer(stream, peer, device));
                    let mut readers = accepting.readers.lock().unwrap();
                    readers.retain(|h| !h.is_finished());
                    readers.push(reader);
                }
            });
            Ok(Self {
                path,
                inode,
                shared,
                accept: Some(accept),
                owner,
            })
        }
        pub fn send(&self, device: &str, frame: &Value) -> io::Result<bool> {
            let Some(peer) = self.shared.peers.lock().unwrap().get(device).cloned() else {
                return Ok(false);
            };
            let mut bytes = serde_json::to_vec(frame).map_err(io::Error::other)?;
            bytes.push(b'\n');
            if bytes.len() > FRAME_BYTES {
                return Err(io::ErrorKind::InvalidInput.into());
            }
            let mut writer = peer.lock().unwrap();
            if let Err(error) = writer.write_all(&bytes) {
                let _ = writer.shutdown(std::net::Shutdown::Both);
                return Err(error);
            }
            Ok(true)
        }
        pub fn disconnect(&self, device: &str) {
            if let Some(peer) = self.shared.peers.lock().unwrap().get(device) {
                let _ = peer.lock().unwrap().shutdown(std::net::Shutdown::Both);
            }
        }
        pub fn close(&mut self) {
            if self.shared.closing.swap(true, Ordering::AcqRel) {
                return;
            }
            let peers: Vec<_> = self
                .shared
                .peers
                .lock()
                .unwrap()
                .values()
                .cloned()
                .collect();
            for peer in peers {
                let _ = peer.lock().unwrap().shutdown(std::net::Shutdown::Both);
            }
            if let Some(accept) = self.accept.take() {
                accept.thread().unpark();
                let _ = accept.join();
            }
            for reader in self.shared.readers.lock().unwrap().drain(..) {
                let _ = reader.join();
            }
            if fs::symlink_metadata(&self.path)
                .is_ok_and(|meta| meta.ino() == self.inode && meta.file_type().is_socket())
            {
                let _ = fs::remove_file(&self.path);
            }
            let _ = self.owner.unlock();
        }
    }
    impl Drop for Transport {
        fn drop(&mut self) {
            self.close();
        }
    }
}

pub struct Transports {
    root: PathBuf,
    emit: Emit,
    #[cfg(unix)]
    ports: std::collections::HashMap<String, unix::Transport>,
}
impl Transports {
    pub fn new(root: &Path, emit: Emit) -> Self {
        Self {
            root: root.into(),
            emit,
            #[cfg(unix)]
            ports: std::collections::HashMap::new(),
        }
    }
    pub fn request(&mut self, request: &Value) -> Value {
        #[cfg(unix)]
        {
            let id = request
                .get("transportId")
                .and_then(Value::as_str)
                .unwrap_or("");
            match request.get("op").and_then(Value::as_str) {
                Some("transport_open") => {
                    let name = request.get("name").and_then(Value::as_str).unwrap_or("");
                    if self.ports.contains_key(id) || self.ports.len() >= 8 {
                        return json!({"error":"transport-open-failed"});
                    }
                    match unix::Transport::open(&self.root, name, id, self.emit.clone()) {
                        Ok(port) => {
                            self.ports.insert(id.into(), port);
                            json!({"ready":true})
                        }
                        Err(_) => json!({"error":"transport-open-failed"}),
                    }
                }
                Some("transport_send") => self
                    .ports
                    .get(id)
                    .and_then(|port| {
                        port.send(request["device"].as_str().unwrap_or(""), &request["frame"])
                            .ok()
                    })
                    .map_or_else(
                        || json!({"error":"transport-write-failed"}),
                        |sent| json!({"sent":sent}),
                    ),
                Some("transport_disconnect") => {
                    if let Some(port) = self.ports.get(id) {
                        port.disconnect(request["device"].as_str().unwrap_or(""));
                    }
                    json!({"closed":true})
                }
                Some("transport_close") => {
                    self.ports.remove(id);
                    json!({"closed":true})
                }
                _ => json!({"error":"invalid-transport-request"}),
            }
        }
        #[cfg(not(unix))]
        {
            let _ = (&self.root, &self.emit, request);
            json!({"error":"local-transport-unavailable"})
        }
    }
}
