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

impl WorkItem {
    /// Makes the item an automation of this runner: `kind: automation`, `runner: <runner>`.
    pub fn make_automation(&mut self, runner: &str) -> crate::error::Res<()> {
        self.edit(|_, lines, _| {
            Self::set_pair(lines, "kind", "automation")?;
            Self::set_pair(lines, "runner", runner)?;
            Ok(true)
        })
        .map(|_| ())
    }
}
