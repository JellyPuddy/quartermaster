//! Which `/api/action` commands skip the global action mutex: the benchmark ones and the three that only wait
//! on `gh` (a hung `gh` must not freeze every other action).

use quartermaster::gui_actions::runs_unlocked;

#[test]
fn the_gh_bound_previews_and_the_benchmark_actions_run_unlocked_the_rest_locked() {
    for cmd in ["issue-preview", "pr-thread-resolve", "review-preview", "benchmark-start", "benchmark-cancel", "benchmark-rerun"] {
        assert!(runs_unlocked(cmd), "{cmd}");
    }
    for cmd in ["note", "state", "pane-start", "review-post", "issue-start", "cleanup", "drafts-send", ""] {
        assert!(!runs_unlocked(cmd), "{cmd}");
    }
}
