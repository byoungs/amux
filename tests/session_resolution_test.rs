/// Session resolution priority: --session flag > AMUX_SESSION env > tmux context > default
mod cli;
mod common;

#[test]
fn cli_session_flag_is_passed_to_subcommand() {
    let ts = common::TestSession::new(3);

    let output = std::process::Command::new(cli::amux_bin())
        .args(["--session", &ts.name, "zoom-in"])
        .env("AMUX_SESSION", "wrong-session-name")
        .output()
        .expect("amux command failed");

    assert!(
        output.status.success(),
        "zoom-in with --session flag should succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        amux::tmux::is_zoomed(&ts.name).expect("is_zoomed"),
        "--session flag should target the correct session"
    );
}
