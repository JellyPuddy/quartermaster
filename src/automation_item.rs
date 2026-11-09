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

impl WorkItem {
    /// A new cloud `kind: automation` item under `slug`, which needn't be the title's slug (the item is made
    /// under the slug as its title, then retitled, in one move); `routine` is recorded once the routine exists.
    pub fn create_automation(slug: &str, title: &str, project: &str, description: Option<&str>, routine: Option<&str>) -> crate::error::Res<WorkItem> {
        Self::with_lock(|| {
            let mut item = Self::create(slug, project, None, None, description, None)?;
            if item.slug != slug {
                return Err(crate::error::QmError::argument(format!("'{slug}' is not a slug a work item can have")));
            }
            item.edit(|_, lines, _| {
                Self::set_pair(lines, "title", title)?;
                Self::set_pair(lines, "kind", "automation")?;
                Self::set_pair(lines, "runner", "cloud")?;
                if let Some(id) = routine {
                    Self::set_pair(lines, "routine", id)?;
                }
                Ok(true)
            })?;
            Ok(item)
        })
    }

    /// Records the routine the item's automation runs as.
    pub fn set_routine(&mut self, id: &str) -> crate::error::Res<()> {
        self.edit(|_, lines, _| Self::set_pair(lines, "routine", id).map(|_| true)).map(|_| ())
    }
}
