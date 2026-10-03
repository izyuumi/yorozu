fn main() {
    // Maintained ScreenCaptureKit bindings contain Swift bridge code. Resolve
    // the system Swift runtime on supported macOS versions, including tests.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
}
