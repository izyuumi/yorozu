// The web view lock-down (spec section 9). Each test fails when a later change loosens it.

use std::fs;
use std::path::Path;

use serde_json::{json, Value};
use tauri::Url;
use yorozu_windows_lib::allowed_navigation;

const CSP: &str = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src ipc: http://ipc.localhost; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

fn read(relative: &str) -> String {
    fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(relative)).unwrap()
}

fn json_file(relative: &str) -> Value {
    serde_json::from_str(&read(relative)).unwrap()
}

#[test]
fn csp_is_exact() {
    assert_eq!(json_file("tauri.conf.json")["app"]["security"]["csp"], CSP);
}

#[test]
fn permissions_are_exact() {
    let capability = json_file("capabilities/default.json");
    assert_eq!(capability["windows"], json!(["main"]));
    let want = [
        "core:event:allow-listen",
        "core:event:allow-unlisten",
        "allow-snapshot",
    ];
    assert_eq!(capability["permissions"], json!(want));
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("capabilities");
    assert_eq!(fs::read_dir(dir).unwrap().count(), 1, "one capability file");
}

#[test]
fn no_dev_tools_feature() {
    assert!(!read("Cargo.toml").contains("devtools"));
}

#[test]
fn no_global_tauri_and_a_relative_frontend() {
    let config = json_file("tauri.conf.json");
    assert_eq!(config["app"]["withGlobalTauri"], false);
    let dist = config["build"]["frontendDist"].as_str().unwrap();
    assert!(!dist.contains("://"), "frontendDist must not be a URL");
    assert!(Path::new(dist).is_relative());
    assert!(config["build"].get("devUrl").is_none());
}

#[test]
fn navigation_stays_in_the_app_origin() {
    let allowed = [
        "http://tauri.localhost",
        "http://tauri.localhost/",
        "https://tauri.localhost/index.html",
        "tauri://localhost",
        "tauri://localhost/assets/index.js",
    ];
    for url in allowed {
        assert!(allowed_navigation(&Url::parse(url).unwrap()), "{url}");
    }
    let refused = [
        "https://example.com",
        "file:///C:/Windows/System32/drivers/etc/hosts",
        "about:blank",
        "http://localhost:1420",
        "http://tauri.localhost.evil.com",
        "http://tauri.localhost:8080",
        "http://localhost",
        "tauri://example.com",
        "ipc://localhost",
    ];
    for url in refused {
        assert!(!allowed_navigation(&Url::parse(url).unwrap()), "{url}");
    }
}

#[test]
fn ui_uses_no_storage_and_no_network() {
    let banned = [
        "localStorage",
        "sessionStorage",
        "indexedDB",
        "fetch(",
        "WebSocket",
    ];
    let mut files = 0;
    let mut dirs = vec![Path::new(env!("CARGO_MANIFEST_DIR")).join("../src")];
    while let Some(dir) = dirs.pop() {
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                dirs.push(path);
                continue;
            }
            files += 1;
            let text = fs::read_to_string(&path).unwrap();
            for word in banned {
                assert!(!text.contains(word), "{} uses {word}", path.display());
            }
        }
    }
    assert!(files > 0, "found no UI sources");
}
