//! What makes a work item an automation: `kind: automation` in its front matter, with the cloud routine's
//! id and the runner (`cloud` or `local`). Every list of the user's work leaves these items out.

use crate::work_item::WorkItem;

impl WorkItem {
    /// `automation` on an item that tracks a scheduled routine, absent on ordinary ones.
    pub fn kind(&self) -> Option<String> {
        self.field("kind")
    }

    pub fn routine(&self) -> Option<String> {
        self.field("routine")
    }

    pub fn runner(&self) -> Option<String> {
        self.field("runner")
    }

    /// The one test every list of the user's work filters with.
    pub fn automation(&self) -> bool {
        self.kind().as_deref() == Some("automation")
    }
}
