//! Bounded private append journals with retained interrupted tails and one OS-held owner.
use crate::{TEMP_ID, private_dir, private_open, sync_dir};
use serde_json::Value;
#[cfg(unix)]
use std::fs::Metadata;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
const JOURNAL_BYTES: u64 = 64 * 1024 * 1024;
const RECORD_BYTES: usize = 1024 * 1024;
const RECORDS: usize = 65_536;
fn invalid() -> io::Error {
    io::ErrorKind::InvalidData.into()
}
#[cfg(unix)]
fn identity(meta: &Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (meta.dev(), meta.ino())
}
pub(crate) struct Journal {
    root: PathBuf,
    name: &'static str,
    owner: File,
    records: Vec<Value>,
    count: usize,
    length: u64,
    complete: u64,
    #[cfg(unix)]
    identity: Option<(u64, u64)>,
    existed: bool,
    failed: bool,
}
impl Drop for Journal {
    fn drop(&mut self) {
        let _ = self.owner.unlock();
    }
}
impl Journal {
    pub fn open(root: &Path, name: &'static str, owner_name: &str) -> io::Result<Self> {
        private_dir(root)?;
        let owner = private_open(&root.join(owner_name), false)?;
        owner.try_lock().map_err(io::Error::other)?;
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW);
        }
        let mut records = Vec::new();
        let mut complete = 0;
        let mut length = 0;
        let mut existed = false;
        #[cfg(unix)]
        let mut file_identity = None;
        match options.open(root.join(name)) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            file => {
                let file = file?;
                let meta = file.metadata()?;
                length = meta.len();
                existed = true;
                #[cfg(unix)]
                {
                    file_identity = Some(identity(&meta));
                }
                if !meta.is_file() || length > JOURNAL_BYTES {
                    return Err(invalid());
                }
                let mut reader = BufReader::new(file);
                loop {
                    let mut bytes = Vec::new();
                    if Read::by_ref(&mut reader)
                        .take((RECORD_BYTES + 1) as u64)
                        .read_until(b'\n', &mut bytes)?
                        == 0
                    {
                        break;
                    }
                    if bytes.len() > RECORD_BYTES {
                        return Err(invalid());
                    }
                    if !bytes.ends_with(b"\n") {
                        break;
                    }
                    if records.len() >= RECORDS {
                        return Err(invalid());
                    }
                    records.push(serde_json::from_slice(&bytes).map_err(io::Error::other)?);
                    complete += bytes.len() as u64;
                }
            }
        }
        Ok(Self {
            root: root.into(),
            name,
            owner,
            count: records.len(),
            records,
            length,
            complete,
            #[cfg(unix)]
            identity: file_identity,
            existed,
            failed: false,
        })
    }
    pub fn available(&self) -> bool {
        !self.failed
    }
    pub fn take_records(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.records)
    }
    fn append_inner(&mut self, entry: &Value) -> io::Result<()> {
        let mut bytes = serde_json::to_vec(entry).map_err(io::Error::other)?;
        bytes.push(b'\n');
        if bytes.len() > RECORD_BYTES
            || self.count >= RECORDS
            || self.complete + bytes.len() as u64 > JOURNAL_BYTES
        {
            return Err(invalid());
        }
        let path = self.root.join(self.name);
        let mut file = private_open(&path, !self.existed)?;
        let meta = file.metadata()?;
        if !meta.is_file() || meta.len() != self.length {
            return Err(invalid());
        }
        #[cfg(unix)]
        if self.identity.is_some_and(|prior| prior != identity(&meta)) {
            return Err(invalid());
        }
        if self.length != self.complete {
            let backup = self.root.join(format!(
                ".{}-recovery.{}.{}.jsonl",
                self.name.trim_end_matches(".jsonl"),
                std::process::id(),
                TEMP_ID.fetch_add(1, Ordering::Relaxed)
            ));
            let mut recovery = private_open(&backup, true)?;
            file.seek(SeekFrom::Start(0))?;
            if io::copy(
                &mut Read::by_ref(&mut file).take(self.length),
                &mut recovery,
            )? != self.length
            {
                return Err(invalid());
            }
            recovery.sync_all()?;
            sync_dir(&self.root)?;
            file.set_len(self.complete)?;
            file.sync_all()?;
            self.length = self.complete;
        }
        file.seek(SeekFrom::End(0))?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        sync_dir(&self.root)?;
        // A replaced or removed path must never yield a durable acknowledgement for an orphan.
        let current = fs::symlink_metadata(&path)?;
        if !current.is_file() || current.file_type().is_symlink() {
            return Err(invalid());
        }
        #[cfg(unix)]
        if identity(&current) != identity(&meta) {
            return Err(invalid());
        }
        self.length += bytes.len() as u64;
        self.complete = self.length;
        self.count += 1;
        self.existed = true;
        #[cfg(unix)]
        {
            self.identity = Some(identity(&meta));
        }
        Ok(())
    }
    pub fn append(&mut self, entry: &Value) -> io::Result<()> {
        if self.failed {
            return Err(invalid());
        }
        let result = self.append_inner(entry);
        if result.is_err() {
            self.failed = true;
        }
        result
    }
}
