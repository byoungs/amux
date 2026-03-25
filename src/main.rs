// src/main.rs

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::os::fd::AsRawFd;

use amux::config;
use amux::state::AmuxState;
use amux::tmux;
use amux::util::auto_title;

/// Terminal workflow manager for AI coding
#[derive(Parser)]
#[command(name = "amux", about = "Terminal workflow manager for AI coding")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Session names to create on startup
    #[arg(short, long)]
    sessions: Vec<String>,
}

#[derive(Subcommand)]
enum Commands {
    /// Start a new amux session (default if no subcommand given)
    Start {
        /// Session names to create
        #[arg(short, long)]
        sessions: Vec<String>,
    },
    /// Create a new pane in the current amux session
    New {
        /// Pane name (auto-generated if omitted)
        name: Option<String>,
    },
    /// List all panes in the current amux session
    List,
    /// Attach to an existing amux session
    Attach,
    /// Start split selection — marks current pane as first split pane
    SplitStart,
    /// Complete split with the given pane index as second pane
    SplitPick {
        /// Pane index to split with
        pane: usize,
    },
    /// Cancel split selection
    SplitCancel,
    /// Exit split view — return panes to grid
    SplitExit,
    /// Refresh config and titles on existing session (preserves all panes)
    Refresh,
    /// Context-aware zoom to pane N (handles level transitions)
    Zoom {
        /// Pane index to zoom to
        pane: usize,
    },
    /// Zoom in one level (Ctrl-+)
    ZoomIn,
    /// Zoom out one level (Ctrl--)
    ZoomOut,
    /// Enter bird's eye mode explicitly
    BirdEye,
    /// Show space picker popup (Ctrl-P)
    Spaces,
    /// Send current pane to another space (Ctrl-S)
    Send,
    /// Mark a specific pane as needing attention (called by Claude Code Notification hook)
    AlertPane {
        /// Pane index that needs attention
        pane: usize,
    },
    /// Watch pane output for BEL characters (started by pipe-pane, internal)
    BellWatch {
        /// Pane index to alert on bell
        pane: usize,
        /// Session name
        #[arg(long)]
        session: String,
    },
}

/// The amux session name. AMUX_SESSION env var takes priority (used by hooks
/// and tests that target a specific session). Falls back to tmux client context
/// (works from key bindings), then "amux" default.
fn session_name() -> String {
    // Explicit env var takes priority (hooks, tests, multi-session)
    if let Ok(s) = std::env::var("AMUX_SESSION") {
        if !s.is_empty() {
            return s;
        }
    }
    // Try tmux client context (works from key bindings inside tmux)
    if let Ok(s) = current_session_from_tmux() {
        if !s.is_empty() {
            return s;
        }
    }
    "amux".to_string()
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    tmux::check_version()?;

    match cli.command {
        Some(Commands::Start { sessions }) => cmd_start(&sessions),
        Some(Commands::New { name }) => cmd_new(name),
        Some(Commands::List) => cmd_list(),
        Some(Commands::Attach) => cmd_attach(),
        Some(Commands::SplitStart) => cmd_split_start(),
        Some(Commands::SplitPick { pane }) => cmd_split_pick(pane),
        Some(Commands::SplitCancel) => cmd_split_cancel(),
        Some(Commands::SplitExit) => cmd_split_exit(),
        Some(Commands::Refresh) => cmd_refresh(),
        Some(Commands::Zoom { pane }) => cmd_zoom(pane),
        Some(Commands::ZoomIn) => cmd_zoom_in(),
        Some(Commands::ZoomOut) => cmd_zoom_out(),
        Some(Commands::BirdEye) => cmd_birdeye(),
        Some(Commands::Spaces) => cmd_spaces(),
        Some(Commands::Send) => cmd_send(),
        Some(Commands::AlertPane { pane }) => cmd_alert_pane(pane),
        Some(Commands::BellWatch { pane, session }) => cmd_bell_watch(session, pane),
        None => {
            // Default: start if no session exists, refresh+attach if it does
            let session = session_name();
            if tmux::session_exists(&session) {
                // Re-apply config and titles, then attach
                cmd_refresh()?;
                cmd_attach()
            } else {
                cmd_start(&cli.sessions)
            }
        }
    }
}

fn cmd_start(sessions: &[String]) -> Result<()> {
    let session = session_name();

    // Ensure Claude Code notification hook is installed
    let _ = amux::hooks::ensure_claude_hook();

    // Create the tmux session
    tmux::create_session(&session)?;
    tmux::mark_as_managed(&session)?;

    // Apply amux configuration (borders, styles, key bindings)
    config::apply_config(&session)?;

    // Determine pane names
    let cwd = std::env::current_dir().unwrap_or_else(|_| ".".into());
    let cwd_str = cwd.to_string_lossy().to_string();

    let names: Vec<String> = if sessions.is_empty() {
        vec![auto_title(&cwd_str)]
    } else {
        sessions.to_vec()
    };

    // The session starts with one default pane — set its title
    tmux::set_title(&session, 0, &names[0])?;

    // Create additional panes
    for name in &names[1..] {
        let idx = tmux::create_pane(&session, Some(&cwd_str))?;
        tmux::set_title(&session, idx, name)?;
    }

    // Apply tiled layout
    tmux::apply_grid_layout(&session)?;

    // Save state
    let state = build_state(&session)?;
    let _ = state.save(&AmuxState::default_path());

    // Start in bird's eye mode
    tmux::set_level(&session, 1)?;

    // Attach to the session
    tmux::attach(&session)?;

    Ok(())
}

fn cmd_new(name: Option<String>) -> Result<()> {
    let session = session_name();
    let cwd = std::env::current_dir().unwrap_or_else(|_| ".".into());
    let cwd_str = cwd.to_string_lossy().to_string();

    let title = name.unwrap_or_else(|| auto_title(&cwd_str));
    let idx = tmux::create_pane(&session, Some(&cwd_str))?;
    tmux::set_title(&session, idx, &title)?;

    // Save state
    let state = build_state(&session)?;
    let _ = state.save(&AmuxState::default_path());

    Ok(())
}

fn cmd_list() -> Result<()> {
    let session = session_name();
    let panes = tmux::list_panes(&session)?;

    for pane in &panes {
        let indicator = if pane.active { ">" } else { " " };
        println!("{} {} {} ({}x{})",
            indicator, pane.index, pane.title, pane.width, pane.height);
    }

    Ok(())
}

fn cmd_attach() -> Result<()> {
    let session = session_name();
    tmux::attach(&session)?;
    Ok(())
}

fn cmd_refresh() -> Result<()> {
    let session = session_name();

    if !tmux::session_exists(&session) {
        anyhow::bail!("No amux session '{}' found. Run `amux start` to create one.", session);
    }

    // Mark as amux-managed (for space listing)
    tmux::mark_as_managed(&session)?;

    // Re-apply config (borders, styles, key bindings)
    config::apply_config(&session)?;

    // Set titles on all existing panes based on their current cwd
    let panes = tmux::list_panes(&session)?;
    for pane in &panes {
        let cwd = tmux::pane_cwd(&session, pane.index)?;
        if !cwd.is_empty() {
            let title = auto_title(&cwd);
            tmux::set_title(&session, pane.index, &title)?;
        }
    }

    // Re-apply tiled layout
    tmux::apply_grid_layout(&session)?;

    // If at level 1, re-enter the bird's eye key table
    let level = tmux::get_level(&session).unwrap_or(2);
    if level == 1 {
        tmux::enter_birdeye_table()?;
    }

    eprintln!("Refreshed {} panes in session '{}'", panes.len(), session);
    Ok(())
}

fn cmd_split_start() -> Result<()> {
    let session = session_name();

    // Save the active pane index to a tmux environment variable
    let panes = tmux::list_panes(&session)?;
    let active = panes.iter().find(|p| p.active).map(|p| p.index).unwrap_or(0);

    // Store in tmux session environment
    let _output = std::process::Command::new("tmux")
        .args(["set-environment", "-t", &session, "AMUX_SPLIT_FIRST", &active.to_string()])
        .output()
        .context("failed to set split env")?;

    // Switch to the split-pick key table
    let _ = std::process::Command::new("tmux")
        .args(["switch-client", "-T", "amux-split-pick"])
        .output();

    Ok(())
}

fn cmd_split_pick(second_pane: usize) -> Result<()> {
    let session = session_name();

    // Read first pane from tmux environment
    let output = std::process::Command::new("tmux")
        .args(["show-environment", "-t", &session, "AMUX_SPLIT_FIRST"])
        .output()
        .context("failed to read split env")?;
    let env_line = String::from_utf8_lossy(&output.stdout);
    let first_pane: usize = env_line
        .trim()
        .strip_prefix("AMUX_SPLIT_FIRST=")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);

    // Enter split view
    tmux::enter_split(&session, first_pane, second_pane)?;

    // Clean up env var
    let _ = std::process::Command::new("tmux")
        .args(["set-environment", "-t", &session, "-u", "AMUX_SPLIT_FIRST"])
        .output();

    Ok(())
}

fn cmd_split_cancel() -> Result<()> {
    let session = session_name();
    // Clean up env var
    let _ = std::process::Command::new("tmux")
        .args(["set-environment", "-t", &session, "-u", "AMUX_SPLIT_FIRST"])
        .output();
    Ok(())
}

fn cmd_split_exit() -> Result<()> {
    let session = session_name();
    tmux::exit_split(&session)?;
    Ok(())
}

/// Dismiss alert on the target pane when the user focuses it.
fn dismiss_on_focus(session: &str, pane_index: usize) {
    let _ = tmux::dismiss_alert(session, pane_index);
}

/// Context-aware zoom: Ctrl-N behavior
fn cmd_zoom(target_pane: usize) -> Result<()> {
    let session = session_name();
    let level = tmux::get_level(&session)?;
    let current = tmux::active_pane_index(&session)?;
    let same_pane = current == target_pane;

    match (level, same_pane) {
        // L1 + any → select pane, go to L2
        (1, _) => {
            tmux::select_pane(&session, target_pane)?;
            dismiss_on_focus(&session, target_pane);
            tmux::set_level(&session, 2)?;
        }
        // L2 + same pane → go to L3
        (2, true) => {
            tmux::toggle_zoom(&session)?;
            tmux::set_level(&session, 3)?;
        }
        // L2 + different pane → switch pane, stay L2
        (2, false) => {
            tmux::select_pane(&session, target_pane)?;
            dismiss_on_focus(&session, target_pane);
        }
        // L3 + same pane → stay L3
        (3, true) => {
            // Already here, do nothing
        }
        // L3 + different pane → unzoom, select pane, go to L2
        (3, false) => {
            tmux::toggle_zoom(&session)?; // unzoom
            tmux::select_pane(&session, target_pane)?;
            dismiss_on_focus(&session, target_pane);
            tmux::set_level(&session, 2)?;
        }
        _ => {}
    }

    Ok(())
}

/// Ctrl-+ : zoom in one level
fn cmd_zoom_in() -> Result<()> {
    let session = session_name();
    let level = tmux::get_level(&session)?;
    let current = tmux::active_pane_index(&session)?;

    match level {
        1 => {
            // L1 → L2: activate the highlighted pane
            dismiss_on_focus(&session, current);
            tmux::set_level(&session, 2)?;
        }
        2 => {
            // L2 → L3: full screen
            tmux::toggle_zoom(&session)?;
            tmux::set_level(&session, 3)?;
        }
        3 => {
            // Already at L3, do nothing
        }
        _ => {}
    }

    Ok(())
}

/// Ctrl-- : zoom out one level
fn cmd_zoom_out() -> Result<()> {
    let session = session_name();
    let level = tmux::get_level(&session)?;

    match level {
        1 => {
            // Already at L1, do nothing
        }
        2 => {
            // L2 → L1: restore tiled, enter bird's eye key table
            tmux::restore_tiled(&session)?;
            tmux::set_level(&session, 1)?;
            tmux::enter_birdeye_table()?;
        }
        3 => {
            // L3 → L2: unzoom
            tmux::toggle_zoom(&session)?;
            tmux::set_level(&session, 2)?;
        }
        _ => {}
    }

    Ok(())
}

/// Enter bird's eye mode explicitly
fn cmd_birdeye() -> Result<()> {
    let session = session_name();
    tmux::restore_tiled(&session)?;
    tmux::set_level(&session, 1)?;
    tmux::enter_birdeye_table()?;
    Ok(())
}

/// Get the current session name directly from tmux (reliable inside popups).
/// Read a line of input with raw terminal support.
/// Escape cancels (returns None). Enter submits. Backspace deletes.
fn read_input_raw() -> Option<String> {
    use std::io::{Read, Write};

    // Put terminal in raw mode
    let fd = std::io::stdin().as_raw_fd();
    let orig = unsafe {
        let mut t: libc::termios = std::mem::zeroed();
        libc::tcgetattr(fd, &mut t);
        let orig = t;
        libc::cfmakeraw(&mut t);
        // Keep output processing so \n works
        t.c_oflag |= libc::OPOST;
        libc::tcsetattr(fd, libc::TCSANOW, &t);
        orig
    };

    let mut input = String::new();
    let mut buf = [0u8; 1];
    let result = loop {
        if std::io::stdin().read_exact(&mut buf).is_err() {
            break None;
        }
        match buf[0] {
            0x1B => break None,           // Escape — cancel
            b'\r' | b'\n' => {
                print!("\r\n");
                std::io::stdout().flush().ok();
                break Some(input);
            }
            0x7F | 0x08 => {              // Backspace/Delete
                if !input.is_empty() {
                    input.pop();
                    print!("\x08 \x08");   // erase character
                    std::io::stdout().flush().ok();
                }
            }
            b if b >= 0x20 => {           // Printable character
                input.push(b as char);
                print!("{}", b as char);
                std::io::stdout().flush().ok();
            }
            _ => {}                       // Ignore control chars
        }
    };

    // Restore terminal
    unsafe { libc::tcsetattr(fd, libc::TCSANOW, &orig); }

    result
}

fn current_session_from_tmux() -> Result<String> {
    let output = std::process::Command::new("tmux")
        .args(["display-message", "-p", "#{session_name}"])
        .output()
        .context("failed to get current session")?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Key events from raw terminal input.
enum RawKey {
    Char(u8),
    Enter,
    Escape,
    Up,
    Down,
    Backspace,
}

/// Read a single key event in raw mode. Handles multi-byte escape sequences (arrows).
fn read_raw_key() -> RawKey {
    use std::io::Read;
    let mut buf = [0u8; 1];

    if std::io::stdin().read_exact(&mut buf).is_err() {
        return RawKey::Escape;
    }

    match buf[0] {
        0x1B => {
            // Could be bare Escape or start of an escape sequence (arrows)
            // Try to read more bytes with a short timeout
            let mut seq = [0u8; 2];
            // Set a very short read timeout to distinguish bare Escape from sequences
            // If nothing follows quickly, it's bare Escape
            use std::io::Read;
            let fd = std::io::stdin().as_raw_fd();
            // Temporarily set VMIN=0, VTIME=1 (0.1s timeout)
            unsafe {
                let mut t: libc::termios = std::mem::zeroed();
                libc::tcgetattr(fd, &mut t);
                t.c_cc[libc::VMIN] = 0;
                t.c_cc[libc::VTIME] = 1;
                libc::tcsetattr(fd, libc::TCSANOW, &t);
            }
            let n = std::io::stdin().read(&mut seq).unwrap_or(0);
            // Restore VMIN=1, VTIME=0 for blocking reads
            unsafe {
                let mut t: libc::termios = std::mem::zeroed();
                libc::tcgetattr(fd, &mut t);
                t.c_cc[libc::VMIN] = 1;
                t.c_cc[libc::VTIME] = 0;
                libc::tcsetattr(fd, libc::TCSANOW, &t);
            }
            if n == 2 && seq[0] == b'[' {
                match seq[1] {
                    b'A' => RawKey::Up,
                    b'B' => RawKey::Down,
                    _ => RawKey::Escape,
                }
            } else {
                RawKey::Escape
            }
        }
        b'\r' | b'\n' => RawKey::Enter,
        0x7F | 0x08 => RawKey::Backspace,
        b => RawKey::Char(b),
    }
}

/// Enter raw terminal mode. Returns the original termios to restore later.
fn enter_raw_mode() -> libc::termios {
    let fd = std::io::stdin().as_raw_fd();
    unsafe {
        let mut orig: libc::termios = std::mem::zeroed();
        libc::tcgetattr(fd, &mut orig);
        let mut raw = orig;
        libc::cfmakeraw(&mut raw);
        raw.c_oflag |= libc::OPOST;
        libc::tcsetattr(fd, libc::TCSANOW, &raw);
        orig
    }
}

/// Restore terminal mode.
fn restore_term(orig: &libc::termios) {
    let fd = std::io::stdin().as_raw_fd();
    unsafe { libc::tcsetattr(fd, libc::TCSANOW, orig); }
}

/// Switch to a space with smart landing based on alert state.
fn switch_to_space(target: &str) -> Result<()> {
    let alert_states = tmux::alert_states(target).unwrap_or_default();
    let prev_level = tmux::get_level(target).unwrap_or(2);
    let prev_pane = tmux::active_pane_index(target).unwrap_or(0);

    let landing = amux::alert::smart_landing(&alert_states, prev_level, prev_pane);

    tmux::switch_session(target)?;

    match landing {
        amux::alert::LandingTarget::FocusPane { index, level } => {
            tmux::select_pane(target, index)?;
            dismiss_on_focus(target, index);
            tmux::set_level(target, level)?;
        }
        amux::alert::LandingTarget::Resume { level, pane } => {
            tmux::select_pane(target, pane)?;
            tmux::set_level(target, level)?;
            if level == 1 {
                tmux::enter_birdeye_table()?;
            }
        }
    }

    Ok(())
}

fn cmd_spaces() -> Result<()> {
    use std::io::Write;
    let current = current_session_from_tmux()?;
    let sessions = tmux::list_focus_sessions()?;

    // Find current selection index
    let mut selected = sessions.iter().position(|s| *s == current).unwrap_or(0);

    let orig = enter_raw_mode();

    loop {
        // Clear screen and redraw
        print!("\x1b[2J\x1b[H"); // clear + home
        println!("\n  \x1b[1;36m Spaces \x1b[0m\n");

        if sessions.is_empty() {
            println!("  \x1b[90m(no spaces yet)\x1b[0m\n");
        } else {
            for (i, s) in sessions.iter().enumerate() {
                let current_dot = if *s == current { " \x1b[32m●\x1b[0m" } else { "" };
                let arrow = if i == selected { "\x1b[36m→\x1b[0m" } else { " " };
                let name_style = if i == selected { "\x1b[1m" } else { "" };

                let alert_count = tmux::get_alert_count(s).unwrap_or(0);
                let alert_dots = if alert_count > 0 {
                    format!(" \x1b[38;5;214m{}\x1b[0m",
                        "⬤".repeat(alert_count.min(5)))
                } else {
                    String::new()
                };

                println!("  {} \x1b[33m{}\x1b[0m {}{}{}{}",
                    arrow, i + 1, name_style, s, current_dot, alert_dots);
            }
            println!();
        }

        println!("  \x1b[90m↑↓ select · Enter switch · 1-9 jump · n new · Esc cancel\x1b[0m");
        std::io::stdout().flush().ok();

        match read_raw_key() {
            RawKey::Escape => {
                restore_term(&orig);
                return Ok(());
            }
            RawKey::Up => {
                if !sessions.is_empty() && selected > 0 {
                    selected -= 1;
                }
            }
            RawKey::Down => {
                if !sessions.is_empty() && selected < sessions.len() - 1 {
                    selected += 1;
                }
            }
            RawKey::Enter => {
                restore_term(&orig);
                if !sessions.is_empty() {
                    let target = &sessions[selected];
                    if target != &current {
                        switch_to_space(target)?;
                    }
                }
                return Ok(());
            }
            RawKey::Char(b) if b >= b'1' && b <= b'9' => {
                restore_term(&orig);
                let num = (b - b'0') as usize;
                if num >= 1 && num <= sessions.len() {
                    let target = &sessions[num - 1];
                    if target != &current {
                        switch_to_space(target)?;
                    }
                }
                return Ok(());
            }
            RawKey::Char(b'n') | RawKey::Char(b'N') => {
                restore_term(&orig);
                print!("\n  Name: ");
                std::io::stdout().flush()?;
                let name = match read_input_raw() {
                    Some(s) if !s.is_empty() => s,
                    _ => return Ok(()),
                };

                tmux::create_session(&name)?;
                config::apply_config(&name)?;
                tmux::set_level(&name, 1)?;
                tmux::mark_as_managed(&name)?;

                let cwd = std::env::current_dir().unwrap_or_else(|_| ".".into());
                let title = auto_title(&cwd.to_string_lossy());
                tmux::set_title(&name, 0, &title)?;

                tmux::switch_session(&name)?;
                return Ok(());
            }
            _ => {} // ignore other keys, stay in loop
        }
    }
}

/// Send the active pane to the target space. If it was the last pane in
/// the source space, switch to the target instead of staying on an empty session.
fn send_and_follow_if_last(from: &str, to: &str) -> Result<()> {
    let count_before = tmux::pane_count(from)?;
    tmux::send_pane_to_session(from, to)?;
    if count_before <= 1 {
        // Source space is now empty — switch to target
        switch_to_space(to)?;
    }
    Ok(())
}

fn cmd_send() -> Result<()> {
    use std::io::Write;
    let current = current_session_from_tmux()?;
    let sessions = tmux::list_focus_sessions()?;

    let other_sessions: Vec<&String> = sessions.iter()
        .filter(|s| **s != current)
        .collect();

    let mut selected: usize = 0;
    let orig = enter_raw_mode();

    loop {
        print!("\x1b[2J\x1b[H");
        println!("\n  \x1b[1;36m Send pane to space \x1b[0m\n");

        for (i, s) in other_sessions.iter().enumerate() {
            let arrow = if i == selected { "\x1b[36m→\x1b[0m" } else { " " };
            let name_style = if i == selected { "\x1b[1m" } else { "" };
            println!("  {} \x1b[33m{}\x1b[0m {}{}",
                arrow, i + 1, name_style, s);
        }

        if other_sessions.is_empty() {
            println!("  \x1b[90m(no other spaces yet)\x1b[0m");
        }

        println!("\n  \x1b[90m↑↓ select · Enter send · 1-9 jump · n new space · Esc cancel\x1b[0m");
        std::io::stdout().flush().ok();

        match read_raw_key() {
            RawKey::Escape => {
                restore_term(&orig);
                return Ok(());
            }
            RawKey::Up => {
                if selected > 0 { selected -= 1; }
            }
            RawKey::Down => {
                if !other_sessions.is_empty() && selected < other_sessions.len() - 1 {
                    selected += 1;
                }
            }
            RawKey::Enter => {
                if !other_sessions.is_empty() {
                    restore_term(&orig);
                    let target = other_sessions[selected];
                    send_and_follow_if_last(&current, target)?;
                    return Ok(());
                }
            }
            RawKey::Char(b) if b >= b'1' && b <= b'9' => {
                let num = (b - b'0') as usize;
                if num >= 1 && num <= other_sessions.len() {
                    restore_term(&orig);
                    let target = other_sessions[num - 1];
                    send_and_follow_if_last(&current, target)?;
                    return Ok(());
                }
            }
            RawKey::Char(b'n') | RawKey::Char(b'N') => {
                restore_term(&orig);
                print!("\n  Name: ");
                std::io::stdout().flush()?;
                let name = match read_input_raw() {
                    Some(s) if !s.is_empty() => s,
                    _ => return Ok(()),
                };

                // Create the new space
                tmux::create_session(&name)?;
                config::apply_config(&name)?;
                tmux::set_level(&name, 1)?;
                tmux::mark_as_managed(&name)?;

                let cwd = std::env::current_dir().unwrap_or_else(|_| ".".into());
                let title = auto_title(&cwd.to_string_lossy());
                tmux::set_title(&name, 0, &title)?;

                // Send the pane to the new space
                send_and_follow_if_last(&current, &name)?;
                return Ok(());
            }
            _ => {}
        }
    }
}

/// Core alert logic: mark a pane, update count, optionally notify.
/// Used by both alert-pane (Claude Code hook) and bell-watch (pipe-pane).
fn trigger_alert(session: &str, pane_index: usize) -> Result<()> {
    // Only skip the active pane if the terminal is frontmost AND the user
    // is zoomed in (L2/L3). If the terminal isn't frontmost, the user isn't
    // looking at ANY pane — alert everything. At L1 (bird's eye), the
    // "active" pane is just the cursor position, not real focus.
    let terminal_focused = amux::notify::is_terminal_frontmost();
    if terminal_focused {
        let level = tmux::get_level(session).unwrap_or(2);
        if level > 1 {
            let active = tmux::active_pane_index(session)?;
            if pane_index == active {
                return Ok(());
            }
        }
    }
    if tmux::get_alert(session, pane_index)? {
        return Ok(());
    }

    tmux::set_alert(session, pane_index, true)?;

    let states = tmux::alert_states(session)?;
    let count = amux::alert::count_alerts(&states);
    tmux::set_alert_count(session, count)?;

    if !amux::notify::is_terminal_frontmost() {
        let elapsed = tmux::get_last_notification_elapsed(session).unwrap_or(u64::MAX);
        if elapsed >= 30 {
            let msg = amux::notify::format_message(count);
            let _ = amux::notify::send_notification("amux", &msg);
            let _ = tmux::set_last_notification_time(session);
        }
    }

    Ok(())
}

/// Mark a specific pane as needing attention.
/// Called by Claude Code's Notification hook, which runs inside the pane and
/// can identify itself via `tmux display-message -p '#{pane_index}'`.
///
/// This replaces the old alert-scan approach (which couldn't identify the bell
/// source). Amux now owns the entire notification path — Claude Code tells us
/// which pane needs attention, and we decide how/when to alert the user.
fn cmd_alert_pane(pane_index: usize) -> Result<()> {
    trigger_alert(&session_name(), pane_index)
}

/// Watch stdin for BEL characters and alert the pane.
/// Started by tmux pipe-pane — runs until the pane closes (EOF on stdin).
fn cmd_bell_watch(session: String, pane_index: usize) -> Result<()> {
    use std::io::Read;
    let mut state = amux::bell::ScanState::new();
    let mut buf = [0u8; 4096];

    loop {
        let n = std::io::stdin().read(&mut buf)?;
        if n == 0 { break; }

        let bells = amux::bell::scan_bytes(&mut state, &buf[..n]);
        if bells > 0 {
            let _ = trigger_alert(&session, pane_index);
        }
    }

    Ok(())
}

/// Build a AmuxState from the current tmux session.
fn build_state(session: &str) -> Result<AmuxState> {
    let panes = tmux::list_panes(session)?;
    let windows: Vec<amux::state::WindowEntry> = panes
        .iter()
        .map(|p| amux::state::WindowEntry {
            position: p.index,
            tmux_window: p.title.clone(),
            label: p.title.clone(),
        })
        .collect();

    let selected = panes.iter()
        .position(|p| p.active)
        .unwrap_or(0);

    Ok(AmuxState {
        version: 2,
        selected,
        view_mode: "grid".to_string(),
        windows,
    })
}
