//! Default mode is inert; native mode requires explicit app-side authorization.
use std::io::{Read, Write};
use yorozu_computer_use::launch::LaunchRequest;
#[tokio::main(flavor = "current_thread")]
async fn main() {
    let native = match std::env::args().skip(1).collect::<Vec<_>>().as_slice() {
        [arg] if arg == "--native-stdio" => true,
        [arg] if arg == "--check-stdio" => false,
        _ => {
            eprintln!("Use --check-stdio or explicitly authorized --native-stdio");
            std::process::exit(2);
        }
    };
    // One length-delimited request avoids requiring EOF before execution.
    let result = async {
        let mut input = std::io::stdin().lock();
        let mut size = [0u8; 4];
        input
            .read_exact(&mut size)
            .map_err(|_| "missing frame header")?;
        let size = u32::from_be_bytes(size) as usize;
        if size > 65536 {
            return Err("launch frame too large".to_string());
        }
        let mut bytes = vec![0; size];
        input
            .read_exact(&mut bytes)
            .map_err(|_| "truncated launch frame")?;
        let request = LaunchRequest::decode(&bytes)?;
        drop(input);
        request.run(native).await
    }
    .await;
    let output = match result {
        Ok(outcome) => serde_json::json!({"version":1,"outcome":outcome}),
        Err(_) => serde_json::json!({"version":1,"error":"Invalid request; no execution"}),
    };
    let bytes = serde_json::to_vec(&output).expect("serializable outcome");
    let mut out = std::io::stdout().lock();
    let _ = out
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .and_then(|_| out.write_all(&bytes))
        .and_then(|_| out.flush());
}
