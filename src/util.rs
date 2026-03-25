use std::process::Command;

/// Auto-generate a session title from the current directory.
/// Format: "<project>/<worktree-or-branch>" e.g. "myproject/feature-auth"
/// Falls back to directory name if not in a git repo under ~/src/.
pub fn auto_title(dir: &str) -> String {
    let abs = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.into());
    let abs_str = abs.to_string_lossy();

    let project = extract_src_project(&abs_str)
        .unwrap_or_else(|| {
            abs.file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "session".to_string())
        });

    let branch = git_worktree_or_branch(dir);

    match branch {
        Some(b) if b != "main" && b != "master" => format!("{}/{}", project, b),
        _ => project,
    }
}

fn extract_src_project(path: &str) -> Option<String> {
    let parts: Vec<&str> = path.split('/').collect();
    for (i, part) in parts.iter().enumerate() {
        if *part == "src" && i + 1 < parts.len() {
            return Some(parts[i + 1].to_string());
        }
    }
    None
}

fn git_worktree_or_branch(dir: &str) -> Option<String> {
    let output = Command::new("git")
        .args(["branch", "--show-current"])
        .current_dir(dir)
        .output()
        .ok()?;
    if output.status.success() {
        let branch = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !branch.is_empty() {
            return Some(branch);
        }
    }
    None
}
