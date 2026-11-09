//! `qm list [--kind KIND]`: the table of work items; automations only with `--kind automation`.

use crate::cli_format::ljust;
use crate::outcome::{done, Outcome};
use crate::work_item::WorkItem;
use crate::work_item_commands::{failed, tri};

pub fn list(args: &[String]) -> Outcome {
    let kind = args.iter().position(|a| a == "--kind").and_then(|i| args.get(i + 1));
    let items: Vec<WorkItem> = tri!(WorkItem::all()).into_iter().filter(|i| kind.map_or(!i.automation(), |k| i.kind().as_deref() == Some(k.as_str()))).collect();
    if items.is_empty() {
        return done("No work items yet. Create one with: qm new TITLE\n".into());
    }
    let rows: Vec<[String; 5]> = items
        .iter()
        .map(|i| {
            let branches = i.branches();
            [
                i.state().unwrap_or_else(|| "?".into()),
                i.project().unwrap_or_else(|| "?".into()),
                i.slug.clone(),
                i.session_count().to_string(),
                if branches.is_empty() { "-".into() } else { branches.join(" ") },
            ]
        })
        .collect();
    let widths: Vec<usize> = (0..5).map(|c| rows.iter().map(|r| r[c].chars().count()).max().unwrap_or(0)).collect();
    let mut out = String::new();
    for row in &rows {
        let cells: Vec<String> = row.iter().enumerate().map(|(c, cell)| ljust(cell, widths[c])).collect();
        out.push_str(&cells.join("  "));
        out.push('\n');
    }
    done(out)
}
