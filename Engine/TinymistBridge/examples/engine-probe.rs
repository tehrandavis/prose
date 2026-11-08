//! A native test host for the embedded library, not the Tinymist CLI.
unsafe extern "C" {
    fn dup(fd: i32) -> i32;
}

fn main() {
    let input = unsafe { dup(0) };
    let output = unsafe { dup(1) };
    assert!(input >= 0 && output >= 0);
    let status =
        unsafe { prose_tinymist::prose_tinymist_run(input, output, std::ptr::null()) };
    if std::env::args().any(|argument| argument == "--linger") {
        // An embedded app remains alive after a document worker stops. Give
        // in-flight Rayon callbacks time to expose a delayed shutdown panic.
        std::thread::sleep(std::time::Duration::from_secs(5));
    }
    std::process::exit(status);
}
