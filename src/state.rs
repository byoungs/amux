use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AmuxState {
    pub version: u32,
    pub selected: usize,
    pub view_mode: String,
    pub windows: Vec<WindowEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowEntry {
    pub position: usize,
    pub tmux_window: String,
    pub label: String,
}

impl AmuxState {
    /// Create a new default state.
    pub fn new() -> Self {
        AmuxState {
            version: 1,
            selected: 0,
            view_mode: "grid".to_string(),
            windows: Vec::new(),
        }
    }

    /// Load state from `path`. Returns `None` if the file is missing or corrupt.
    /// Currently unused in v2, but kept for future state persistence features.
    #[allow(dead_code)]
    pub fn load(path: &Path) -> Option<Self> {
        let contents = fs::read_to_string(path).ok()?;
        serde_json::from_str(&contents).ok()
    }

    /// Save state to `path` atomically via a temporary file + rename.
    /// Parent directories are created if they don't exist.
    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        // Write to a sibling temp file, then rename for atomicity.
        let tmp_path = path.with_extension("json.tmp");
        let json = serde_json::to_string_pretty(self)?;
        fs::write(&tmp_path, &json)?;
        fs::rename(&tmp_path, path)?;
        Ok(())
    }

    /// Return the default state file path: `~/.amux/state.json`.
    pub fn default_path() -> PathBuf {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        home.join(".amux").join("state.json")
    }

    /// Reconcile saved state against the current live tmux windows.
    ///
    /// - Saved windows that still exist in `live_windows` are kept in their
    ///   saved position order.
    /// - Live windows not present in the saved state are appended at the end.
    /// - `selected` is clamped to the valid range.
    ///
    /// Currently unused in v2, but kept for future state persistence features.
    #[allow(dead_code)]
    pub fn reconcile(&self, live_windows: &[String]) -> AmuxState {
        // Keep saved windows that still appear in the live set, preserving order.
        let mut result_windows: Vec<WindowEntry> = self
            .windows
            .iter()
            .filter(|w| live_windows.contains(&w.tmux_window))
            .cloned()
            .collect();

        // Collect the set of tmux_window names already in result.
        let already_saved: std::collections::HashSet<String> = result_windows
            .iter()
            .map(|w| w.tmux_window.clone())
            .collect();

        // Collect live windows not yet represented.
        let next_position = result_windows.len();
        let new_entries: Vec<WindowEntry> = live_windows
            .iter()
            .filter(|w| !already_saved.contains(*w))
            .enumerate()
            .map(|(i, live)| WindowEntry {
                position: next_position + i,
                tmux_window: live.clone(),
                label: live.clone(),
            })
            .collect();

        // Append the new entries.
        result_windows.extend(new_entries);

        // Reindex positions to be contiguous.
        for (i, w) in result_windows.iter_mut().enumerate() {
            w.position = i;
        }

        // Clamp selected index.
        let max_idx = result_windows.len().saturating_sub(1);
        let selected = self.selected.min(max_idx);

        AmuxState {
            version: self.version,
            selected,
            view_mode: self.view_mode.clone(),
            windows: result_windows,
        }
    }
}

impl Default for AmuxState {
    fn default() -> Self {
        Self::new()
    }
}
