//! Ephemeral plaintext catch-up jobs. Encryption/currency are reserved only at dispatch.
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::time::{Duration, Instant};
const JOBS: usize = 32;
const JOB_BYTES: usize = 32 * 1024 * 1024;
const TOTAL_BYTES: usize = 64 * 1024 * 1024;
const PACE: Duration = Duration::from_millis(100);
struct Job {
    pubkey: String,
    generation: String,
    connection: String,
    events: VecDeque<(Value, usize)>,
    bytes: usize,
}
struct Claim {
    token: String,
    pubkey: String,
    generation: String,
}
#[derive(Default)]
pub struct Catchup {
    jobs: VecDeque<Job>,
    bytes: usize,
    serial: u64,
    claim: Option<Claim>,
    next: Option<Instant>,
}
fn key(value: &Value) -> Option<&str> {
    value.as_str().filter(|s| !s.is_empty() && s.len() <= 256)
}
impl Catchup {
    fn remove(&mut self, pubkey: &str) {
        if let Some(at) = self.jobs.iter().position(|job| job.pubkey == pubkey) {
            self.bytes -= self.jobs.remove(at).unwrap().bytes;
        }
        if self
            .claim
            .as_ref()
            .is_some_and(|claim| claim.pubkey == pubkey)
        {
            self.claim = None;
        }
    }
    fn replace(&mut self, request: &Value) -> Result<Value, ()> {
        let pubkey = key(&request["pub"]).ok_or(())?;
        let generation = key(&request["generation"]).ok_or(())?;
        let connection = key(&request["connection"]).ok_or(())?;
        let events = request["events"]
            .as_array()
            .filter(|events| events.len() <= 65_536)
            .ok_or(())?;
        let mut pending = VecDeque::new();
        let mut bytes = 0;
        let mut response_bytes = 1024 * 1024;
        for event in events {
            if !event.is_object()
                || !event["id"].is_string()
                || !event["threadId"].is_string()
                || !event["kind"].is_string()
                || !event["data"].is_object()
            {
                return Err(());
            }
            let size = serde_json::to_vec(event).map_err(|_| ())?.len();
            bytes += size;
            if bytes > JOB_BYTES {
                return Err(());
            }
            response_bytes = response_bytes.max(size + 4096);
            pending.push_back((event.clone(), size));
        }
        // New generation supersedes the previous job, including its outstanding claim.
        self.remove(pubkey);
        if !pending.is_empty() {
            if self.jobs.len() == JOBS || self.bytes + bytes > TOTAL_BYTES {
                return Err(());
            }
            self.bytes += bytes;
            self.jobs.push_back(Job {
                pubkey: pubkey.into(),
                generation: generation.into(),
                connection: connection.into(),
                events: pending,
                bytes,
            });
        }
        Ok(json!({"stored":true,"remaining":!self.jobs.is_empty(),"responseBytes":response_bytes}))
    }
    fn poll(&mut self, request: &Value) -> Result<Value, ()> {
        let writable = request["writable"].as_bool().ok_or(())?;
        let buffered_bytes = request["bufferedBytes"].as_u64().ok_or(())?;
        if self.claim.is_some() {
            return Err(());
        }
        let connection = key(&request["connection"]).ok_or(())?;
        let eligible = request["eligible"]
            .as_array()
            .filter(|rows| rows.len() <= JOBS)
            .ok_or(())?;
        if eligible
            .iter()
            .any(|row| key(&row["pub"]).is_none() || key(&row["generation"]).is_none())
        {
            return Err(());
        }
        self.jobs.retain(|job| {
            job.connection == connection
                && eligible
                    .iter()
                    .any(|row| row["pub"] == job.pubkey && row["generation"] == job.generation)
        });
        self.bytes = self.jobs.iter().map(|job| job.bytes).sum();
        if self.jobs.is_empty() {
            return Ok(json!({"remaining":false}));
        }
        let now = Instant::now();
        if let Some(next) = self.next.filter(|next| *next > now) {
            return Ok(
                json!({"remaining":true,"waitMs":next.duration_since(now).as_millis().saturating_add(1)}),
            );
        }
        let mut job = self.jobs.pop_front().ok_or(())?;
        if !writable || buffered_bytes > 512 * 1024 {
            self.jobs.push_back(job);
            return Ok(json!({"remaining":true,"waitMs":100}));
        }
        self.serial = self.serial.checked_add(1).ok_or(())?;
        let token = format!("catchup:{}", self.serial);
        let (event, size) = job.events.pop_front().ok_or(())?;
        job.bytes -= size;
        self.bytes -= size;
        let pubkey = job.pubkey.clone();
        let generation = job.generation.clone();
        let done = job.events.is_empty();
        if !done {
            self.jobs.push_back(job);
        }
        self.claim = Some(Claim {
            token: token.clone(),
            pubkey: pubkey.clone(),
            generation: generation.clone(),
        });
        Ok(
            json!({"event":event,"pub":pubkey,"generation":generation,"claim":token,"remaining":!self.jobs.is_empty(),"done":done}),
        )
    }
    pub fn request(&mut self, request: &Value) -> Value {
        let result = match request["op"].as_str() {
            Some("catchup_replace") => self.replace(request),
            Some("catchup_next") => self.poll(request),
            Some("catchup_cancel") => key(&request["pub"])
                .map(|pubkey| {
                    self.remove(pubkey);
                    json!({"stored":true})
                })
                .ok_or(()),
            Some("catchup_clear") => {
                self.jobs.clear();
                self.claim = None;
                self.bytes = 0;
                Ok(json!({"stored":true}))
            }
            Some("catchup_finish") => (|| {
                let sent = request["sent"].as_bool().ok_or(())?;
                let claim = self
                    .claim
                    .as_ref()
                    .filter(|claim| {
                        request["claim"] == claim.token
                            && request["pub"] == claim.pubkey
                            && request["generation"] == claim.generation
                    })
                    .ok_or(())?;
                let _ = claim;
                self.claim = None;
                if sent {
                    self.next = Some(Instant::now() + PACE);
                }
                Ok(
                    json!({"stored":true,"remaining":!self.jobs.is_empty(),"waitMs":if sent {100} else {0}}),
                )
            })(),
            _ => Err(()),
        };
        result.unwrap_or_else(|_| json!({"error":"catchup-unconfirmed"}))
    }
}
