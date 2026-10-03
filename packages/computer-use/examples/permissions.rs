fn main() {
    #[cfg(target_os = "macos")]
    {
        let (capture, input) = yorozu_computer_use::macos::permissions();
        println!("Existing permissions only: screen_recording={capture}, accessibility={input}");
    }
    #[cfg(not(target_os = "macos"))]
    println!("macOS required");
}
