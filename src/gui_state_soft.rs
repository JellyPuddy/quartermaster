//! A state build shows a part it cannot read as empty and logs why, as `GuiState` rescued per section: one odd
//! timestamp, draft file or work item must not blank the whole `/api/state`.

use std::fmt::Debug;

use crate::data_root;
use crate::work_item::WorkItem;

/// The value, or None after logging that `section` could not be read.
pub fn logged<T, E: Debug>(section: &str, result: Result<T, E>) -> Option<T> {
    match result {
        Ok(v) => Some(v),
        Err(e) => {
            data_root::log_error(section, "StandardError", &format!("{e:?}"));
            None
        }
    }
}

/// Every item that reads, in file-name order; one that does not is logged and left out.
pub fn readable_items() -> Vec<WorkItem> {
    let Ok(dir) = std::fs::read_dir(data_root::work_items_dir()) else { return vec![] };
    let mut names: Vec<String> = dir.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n.ends_with(".md") && !n.starts_with('.')).collect();
    names.sort();
    names.iter().filter_map(|n| logged("gui-item", WorkItem::find(n.trim_end_matches(".md")))).collect()
}
