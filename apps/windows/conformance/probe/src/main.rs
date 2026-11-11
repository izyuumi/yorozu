use serde_json::{json, Value};
use std::{
    io::{self, BufRead},
    path::PathBuf,
    sync::Arc,
};
use yorozu_core::{
    driver::{Command, Driver, Notification, Options},
    platform::SystemPlatform,
    store::{PlainProtector, Standing},
};
#[tokio::main]
async fn main() {
    let args: Vec<_> = std::env::args().collect();
    let dir = args
        .windows(2)
        .find(|w| w[0] == "--dir")
        .map(|w| PathBuf::from(&w[1]))
        .expect("--dir DIR required");
    let exit_joined = args.iter().any(|s| s == "--exit-after-joined-persist");
    let options = Options {
        fast: args.iter().any(|s| s == "--fast"),
    };
    let protector = Box::new(PlainProtector);
    let (handle, driver) = Driver::new(
        Arc::new(SystemPlatform { dir }),
        protector,
        options,
        "probe",
        move |event| {
            let value = match event {
                Notification::Pairing(state) => json!({"ev":"pairing","state":state}),
                Notification::Connection(state) => json!({"ev":"conn","state":state}),
                Notification::Close(code, reason) => {
                    json!({"ev":"close","code":code,"reason":reason})
                }
                Notification::Notice { state, text } => {
                    json!({"ev":"pairing","state":state,"notice":text})
                }
                Notification::File {
                    standing,
                    has_token,
                    has_secret,
                } => {
                    let value = json!({"ev":"file","standing":standing,"hasToken":has_token,"hasSecret":has_secret});
                    if exit_joined && standing == Standing::Known && has_secret {
                        println!("{value}");
                        std::process::exit(0);
                    }
                    value
                }
                Notification::Changed(_) => return,
            };
            println!("{value}");
        },
    );
    let reader = handle.clone();
    // Blocking stdin stays off the runtime, and EOF shuts the driver down.
    std::thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            let Ok(line) = line else {
                break;
            };
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let command = match value["cmd"].as_str() {
                Some("pair") => {
                    if let Some(link) = value["link"].as_str() {
                        let _ = reader.command(Command::SubmitLink(link.into()));
                        Command::Confirm
                    } else {
                        continue;
                    }
                }
                Some("forget") => Command::Forget,
                Some("drop") => Command::Drop,
                Some("quit") => Command::Quit,
                _ => continue,
            };
            if reader.command(command).is_err() {
                return;
            }
        }
        let _ = reader.command(Command::Quit);
    });
    driver.run().await;
}
