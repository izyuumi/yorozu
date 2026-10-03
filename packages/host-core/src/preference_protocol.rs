//! Bounded, separate host-only preference endpoint. Worker frames never reach it.
use crate::preferences::{Budget, Change, Context, Key, Owner, Preferences, Scope};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, Read, Write},
    path::Path,
};

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", deny_unknown_fields)]
enum Request {
    Apply {
        change: Change,
    },
    Latest {
        scope: Scope,
        key: Key,
    },
    Receipt {
        #[serde(rename = "eventId")]
        event_id: String,
    },
    Retrieve {
        context: Context,
        budget: Budget,
    },
}

/// One request per process; a dedicated private store retains the single OS owner lock.
pub fn serve(
    root: &Path,
    owner: &Owner,
    input: impl BufRead,
    mut output: impl Write,
) -> io::Result<()> {
    let mut bytes = Vec::new();
    input.take(8193).read_to_end(&mut bytes)?;
    if bytes.len() > 8192 {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let request: Request = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    let mut store = Preferences::open(root, owner).map_err(io::Error::other)?;
    let result: Result<Value, crate::preferences::Error> = match request {
        Request::Apply { change } => store.apply(&change).map(|receipt| json!(receipt)),
        Request::Latest { scope, key } => store.latest(&scope, key).map(|record| json!(record)),
        Request::Receipt { event_id } => store.receipt(&event_id).map(|record| json!(record)),
        Request::Retrieve { context, budget } => store
            .retrieve(&context, budget)
            .map(|snapshot| json!({"snapshot":snapshot,"markdown":snapshot.markdown()})),
    };
    let response = match result {
        Ok(value) => json!({"version":1,"ok":true,"value":value}),
        Err(error) => json!({"version":1,"ok":false,"error":error.to_string()}),
    };
    serde_json::to_writer(&mut output, &response).map_err(io::Error::other)?;
    output.write_all(b"\n")?;
    output.flush()
}
