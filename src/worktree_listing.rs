use std::cell::RefCell;

/// `branch_diff::branch_worktrees` remembered per project root for as long as this value lives: a state build
/// holds one, so each root is listed once per build however many items it has, and a new worktree shows on the
/// next build.
#[derive(Default)]
pub struct WorktreeListing {
    by_root: RefCell<Vec<(String, Vec<(String, String)>)>>,
}

impl WorktreeListing {
    pub fn get(&self, root: &str) -> Vec<(String, String)> {
        let mut cache = self.by_root.borrow_mut();
        if let Some((_, found)) = cache.iter().find(|(r, _)| r == root) {
            return found.clone();
        }
        let listed = crate::branch_diff::branch_worktrees(root);
        cache.push((root.to_string(), listed.clone()));
        listed
    }
}
