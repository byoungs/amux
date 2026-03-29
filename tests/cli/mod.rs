/// CLI binary helpers for end-to-end integration tests.
///
/// These invoke the compiled amux binary as a subprocess, testing the
/// full CLI boundary rather than library internals.
use std::process::Command;

/// Get the amux binary path (debug build from cargo).
/// Respects CARGO_TARGET_DIR if set (used by Makefile for shared target dir).
pub fn amux_bin() -> String {
    if let Ok(target_dir) = std::env::var("CARGO_TARGET_DIR") {
        format!("{}/debug/amux", target_dir)
    } else {
        let manifest = env!("CARGO_MANIFEST_DIR");
        format!("{}/target/debug/amux", manifest)
    }
}

/// Run an amux subcommand against a test session.
pub fn amux_cmd(session: &str, args: &[&str]) -> std::process::Output {
    Command::new(amux_bin())
        .args(args)
        .env("AMUX_SESSION", session)
        .output()
        .expect("amux command failed")
}
