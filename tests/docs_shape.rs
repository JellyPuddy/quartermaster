//! The shape of `docs/`, not its prose: every area page follows the template, every code file is owned by
//! exactly one page, links resolve, pages stay within their size caps and carry no history markers.

use regex::Regex;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

fn repo() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

fn areas() -> Vec<PathBuf> {
    let mut pages: Vec<PathBuf> = fs::read_dir(repo().join("docs/areas")).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "md")).collect();
    pages.sort();
    pages
}

fn rel(p: &Path) -> String {
    p.strip_prefix(repo()).unwrap().to_string_lossy().into_owned()
}

/// The backticked paths on a page's `**Label:**` line.
fn header_paths(page: &Path, label: &str) -> Vec<String> {
    let text = fs::read_to_string(page).unwrap();
    let Some(line) = text.lines().find(|l| l.starts_with(&format!("**{label}:**"))) else { return vec![] };
    Regex::new(r"`([^`]+)`").unwrap().captures_iter(line).map(|c| c[1].to_string()).collect()
}

fn files(dir: &str, ext: &str) -> Vec<String> {
    let mut out: Vec<String> = fs::read_dir(repo().join(dir)).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == ext)).map(|p| rel(&p)).collect();
    out.sort();
    out
}

#[test]
fn there_are_area_pages() {
    assert!(!areas().is_empty());
}

#[test]
fn every_area_page_follows_the_template() {
    for page in areas() {
        let text = fs::read_to_string(&page).unwrap();
        for label in ["Code", "Tests"] {
            assert!(Regex::new(&format!(r"(?m)^\*\*{label}:\*\* \S")).unwrap().is_match(&text), "{} needs a **{label}:** line", rel(&page));
        }
        for heading in ["## What it does", "## Rules"] {
            assert!(text.lines().any(|l| l == heading), "{} needs a `{heading}` heading", rel(&page));
        }
    }
}

#[test]
fn every_named_path_exists() {
    for page in areas() {
        for label in ["Code", "Tests"] {
            for path in header_paths(&page, label) {
                // the golden files and unit tests are named in prose, not as paths
                assert!(repo().join(&path).exists(), "{} names {path} on its {label} line, which doesn't exist", rel(&page));
            }
        }
    }
}

#[test]
fn every_code_file_is_owned_by_exactly_one_page() {
    let mut owners: HashMap<String, Vec<String>> = HashMap::new();
    for page in areas() {
        for path in header_paths(&page, "Code") {
            owners.entry(path).or_default().push(rel(&page));
        }
    }
    let mut all = files("src", "rs");
    all.extend(files("gui/js", "js"));
    all.extend(files("hooks", "sh"));
    assert!(!all.is_empty());
    let unowned: Vec<&String> = all.iter().filter(|f| !owners.contains_key(*f)).collect();
    assert!(unowned.is_empty(), "these files belong on some docs/areas page's **Code:** line: {unowned:?}");
    let shared: Vec<(&String, &Vec<String>)> = owners.iter().filter(|(_, pages)| pages.len() > 1).collect();
    assert!(shared.is_empty(), "a file is owned by one page only: {shared:?}");
}

#[test]
fn readme_links_resolve_and_list_every_area_page() {
    let docs = repo().join("docs");
    let text = fs::read_to_string(docs.join("README.md")).unwrap();
    let links: Vec<String> = Regex::new(r"\]\(([^)#\s]+)\)").unwrap().captures_iter(&text).map(|c| c[1].to_string()).filter(|l| !Regex::new(r"^\w+://").unwrap().is_match(l)).collect();
    for link in &links {
        assert!(docs.join(link).exists(), "README.md links {link}, which doesn't exist");
    }
    let linked: Vec<PathBuf> = links.iter().map(|l| fs::canonicalize(docs.join(l)).unwrap_or_else(|_| docs.join(l))).collect();
    for page in areas() {
        assert!(linked.contains(&fs::canonicalize(&page).unwrap()), "README.md must link {}", rel(&page));
    }
}

#[test]
fn pages_stay_within_their_line_caps() {
    for (name, cap) in [("README.md", 80), ("overview.md", 150), ("rejected.md", 120)] {
        let lines = fs::read_to_string(repo().join("docs").join(name)).unwrap().lines().count();
        assert!(lines <= cap, "docs/{name} has {lines} lines, cap {cap}");
    }
    for page in areas() {
        let lines = fs::read_to_string(&page).unwrap().lines().count();
        assert!(lines <= 200, "{} has {lines} lines, cap 200", rel(&page));
    }
}

#[test]
fn area_pages_carry_no_history_markers() {
    let date = Regex::new(r"\b20\d\d-\d\d-\d\d\b").unwrap();
    let decision = Regex::new(r"(?i)decision \d+").unwrap();
    for page in areas() {
        let text = fs::read_to_string(&page).unwrap();
        assert!(!date.is_match(&text), "{} has a date; history lives in git", rel(&page));
        assert!(!decision.is_match(&text), "{} cites a plan decision; say the rule instead", rel(&page));
    }
}
