//! `qm draft add`: a chat's review finding as a draft on the item's PR, against a real local "origin"
//! holding the PR's head under `refs/pull/7/head`, the PRs view's cache and a `gh` that knows no PR.
//! Each step prints what the command said and the drafts file afterwards; generated from Ruby.

mod common;
use common::*;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use regex::Regex;

#[test]
fn draft_add_records_review_comments() {
    let qm = Qm::new();
    let root = qm.root.path().to_path_buf();
    let origin = root.join("acme/widgets.git");
    let repo = root.join("repo");
    fs::create_dir_all(&origin).unwrap();
    git(&origin, &["init", "-q", "--bare", "-b", "main"]);
    common::repo(&repo, "main");
    git(&repo, &["remote", "add", "origin", origin.to_str().unwrap()]);
    git(&repo, &["push", "-q", "origin", "main"]);
    git(&repo, &["checkout", "-q", "-b", "feat"]);
    fs::write(repo.join("a.txt"), "a\nb\nc\n").unwrap();
    git(&repo, &["commit", "-qam", "second"]);
    fs::write(repo.join("b.txt"), "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "third"]);
    fs::write(repo.join("b.txt"), "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\nTWELVE\nthirteen\n").unwrap();
    git(&repo, &["commit", "-qam", "fourth"]);
    git(&repo, &["push", "-q", "origin", "feat:refs/pull/7/head"]);
    let second = git(&repo, &["rev-parse", "HEAD~2"]);
    git(&repo, &["checkout", "-q", "main"]);
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    fs::write(bin.join("gh"), "#!/bin/sh\necho \"no pull requests found for $3\" >&2\nexit 1\n").unwrap();
    fs::set_permissions(bin.join("gh"), fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(root.join("config.yml"), format!("projects:\n  demo:\n    root: {}\n", repo.display())).unwrap();
    qm.ok(&["list"]);
    fs::write(root.join("pr-inbox.json"), r#"{"prs":[{"repo":"acme/widgets","number":7,"url":"https://github.com/acme/widgets/pull/7","title":"T","head":"feat","base":"main","state":"OPEN"},{"repo":"acme/widgets","number":8,"url":"https://github.com/acme/widgets/pull/8","title":"U","head":"other","base":"main","state":"OPEN"},{"repo":"acme/other","number":9,"url":"https://github.com/acme/other/pull/9","title":"V","head":"feat","base":"main","state":"OPEN"}]}"#).unwrap();
    fs::create_dir_all(root.join("work-items")).unwrap();
    let item = |slug: &str, project: &str, extra: &str, desc: &str| fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {}\nstate: in_progress\nproject: {project}\ncreated: '2026-01-01'\n{extra}---\n\n## Description\n\n{desc}\n\n## Notes\n\n## Snapshots\n", if desc.starts_with("Review") { format!("Review {slug}") } else { slug.to_string() })).unwrap();
    item("d-item", "demo", "branches:\n- feat\n", "d");
    item("d-multi", "demo", "branches:\n- feat\n- other\n", "d");
    item("d-none", "demo", "", "d");
    item("d-bare", "nowhere", "branches:\n- feat\n", "d");
    item("d-foreign", "demo", "branches:\n- feat\n", "d");
    let env: Vec<(&str, String)> = vec![("PATH", format!("{}:{}", bin.display(), std::env::var("PATH").unwrap())), ("HOME", root.join("home").display().to_string())];
    let env_refs: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
    fs::create_dir_all(root.join("home")).unwrap();
    let pr7 = "https://github.com/acme/widgets/pull/7";
    let cases: Vec<(Vec<&str>, &str)> = vec![
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2", "--body", "first finding"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2", "--body", "second wording"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2", "--side", "new", "--body=equals form"], ""),
        (vec!["draft", "add", "d-item", "--path", "b.txt", "--line", "3", "--start-line", "1", "--body", "a range"], ""),
        (vec!["draft", "add", "d-item", "--path", "b.txt", "--line", "12", "--body", "```suggestion\nTwelve\n```"], ""),
        (vec!["draft", "add", "d-item", "--path", "b.txt", "--line", "7", "--body", "too far"], ""),
        (vec!["draft", "add", "d-item", "--path", "b.txt", "--line", "7", "--file", "--body", "whole file"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "1", "--side", "old", "--body", "old side"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "9", "--file", "--body", "past the end"], ""),
        (vec!["draft", "add", "d-item", "--path", "nope.txt", "--line", "1", "--body", "no such file"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2", "--commit", "SECOND", "--body", "at a commit"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2", "--commit", "HEAD", "--body", "not a PR commit"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2", "--start-line", "3", "--body", "backwards"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "0", "--body", "zero"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--body", "no line"], ""),
        (vec!["draft", "add", "d-item", "--line", "2", "--body", "no path"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2", "--body", "   "], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2"], ""),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2", "--body-file", "-"], "from stdin\nsecond line\n"),
        (vec!["draft", "add", "d-item", "--path", "a.txt", "--line", "2", "--body", "x", "--body-file", "-"], "stdin"),
        (vec!["draft", "add", "d-item", "--reply-to", "PRRT_abc123", "--body", "a reply"], ""),
        (vec!["draft", "add", "d-item", "--reply-to", "PRRT_abc123", "--path", "a.txt", "--line", "2", "--body", "a second reply"], ""),
        (vec!["draft", "add", "d-item", "--reply-to", "PRRT_abc123", "--file", "--body", "a reply"], ""),
        (vec!["draft", "add", "d-item", "--reply-to", "bad id", "--body", "a reply"], ""),
        (vec!["draft", "add", "d-item", "--pr", pr7, "--path", "a.txt", "--line", "3", "--body", "by url"], ""),
        (vec!["draft", "add", "d-item", "--pr", "https://github.com/acme/other/pull/9", "--path", "a.txt", "--line", "2", "--body", "wrong repo"], ""),
        (vec!["draft", "add", "d-item", "--pr", "nonsense", "--path", "a.txt", "--line", "2", "--body", "bad url"], ""),
        (vec!["draft", "add", "d-item", "--pr", "https://github.com/acme/widgets/pull/99", "--path", "a.txt", "--line", "2", "--body", "unknown pr"], ""),
        (vec!["draft", "add", "d-item", "--branch", "feat", "--path", "a.txt", "--line", "3", "--body", "by branch"], ""),
        (vec!["draft", "add", "d-item", "--branch", "ghost", "--path", "a.txt", "--line", "3", "--body", "no pr for branch"], ""),
        (vec!["draft", "add", "d-multi", "--path", "a.txt", "--line", "2", "--body", "two prs"], ""),
        (vec!["draft", "add", "d-multi", "--branch", "feat", "--path", "a.txt", "--line", "2", "--body", "picked"], ""),
        (vec!["draft", "add", "d-none", "--path", "a.txt", "--line", "2", "--body", "no branches"], ""),
        (vec!["draft", "add", "d-bare", "--path", "a.txt", "--line", "2", "--body", "no root"], ""),
        (vec!["draft", "add", "nowhere", "--path", "a.txt", "--line", "2", "--body", "no item"], ""),
        (vec!["draft", "add"], ""),
        (vec!["draft", "add", "d-item"], ""),
        (vec!["draft", "add", "d-item", "--bogus"], ""),
        (vec!["draft", "add", "d-item", "--line", "x", "--body", "b"], ""),
        (vec!["draft", "add", "d-item", "--side", "left", "--path", "a.txt", "--line", "2", "--body", "b"], ""),
        (vec!["draft", "list", "d-item"], ""),
    ];
    let mut out = String::new();
    let ids = Regex::new(r#""id": "[0-9a-f]{12}""#).unwrap();
    for (args, stdin) in &cases {
        let args: Vec<String> = args.iter().map(|a| if *a == "SECOND" { second.clone() } else { a.to_string() }).collect();
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        out += &transcript_env(&qm, "none", &[(&refs[..], stdin)], &env_refs);
        out += &format!("--- drafts d-item\n{}\n", ids.replace_all(&fs::read_to_string(root.join("drafts/d-item.json")).unwrap_or_default(), r#""id": "ID""#));
        // the user's own draft on a line is never replaced
        if args.iter().any(|a| a == "first finding") {
            let path = root.join("drafts/d-item.json");
            let text = fs::read_to_string(&path).unwrap();
            fs::write(&path, text.replace("\"author\": \"claude\"", "\"author\": \"user\"")).unwrap();
        }
    }
    // commit ids depend on the clock, draft ids on chance
    let mut o = scrub(&qm, &out);
    for (pattern, to) in [(r"\b[0-9a-f]{40}\b", "SHA"), (r"@[0-9a-f]{7}\b", "@SHORT"), (r#""range": "[0-9a-f]{7}""#, r#""range": "SHORT""#), (r"\b[0-9a-f]{7}\.\.[0-9a-f]{7}\b", "SHORT..SHORT"), (r"\b[0-9a-f]{12}\b", "ID")] {
        o = Regex::new(pattern).unwrap().replace_all(&o, to).into_owned();
    }
    golden("cli_draft.txt", &o);
}

#[test]
fn pr_opens_the_branches_pull_request() {
    let qm = Qm::new();
    let root = qm.root.path().to_path_buf();
    let repo = root.join("repo");
    common::repo(&repo, "main");
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    fs::write(bin.join("gh"), "#!/bin/sh\necho \"gh $* in $(basename $(pwd))\" >> \"$FAKE_LOG\"\n[ -f \"$FAKE_LOG.fail\" ] && exit 1\nexit 0\n").unwrap();
    fs::set_permissions(bin.join("gh"), fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(root.join("config.yml"), format!("projects:\n  demo:\n    root: {}\n", repo.display())).unwrap();
    qm.ok(&["list"]);
    fs::create_dir_all(root.join("work-items")).unwrap();
    let item = |slug: &str, project: &str, extra: &str| fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {slug}\nstate: in_progress\nproject: {project}\ncreated: '2026-01-01'\n{extra}---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")).unwrap();
    item("p-one", "demo", "branches:\n- feat-a\n");
    item("p-none", "demo", "");
    item("p-bare", "nowhere", "branches:\n- feat-a\n");
    let env: Vec<(&str, String)> = vec![("PATH", format!("{}:{}", bin.display(), std::env::var("PATH").unwrap())), ("FAKE_LOG", root.join("gh.log").display().to_string())];
    let env_refs: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let mut out = String::new();
    for args in [vec!["pr"], vec!["pr", "nowhere"], vec!["pr", "p-none"], vec!["pr", "p-bare"], vec!["pr", "p-one"], vec!["pr", "p-one", "extra"]] {
        out += &transcript_env(&qm, "p-one", &[(&args[..], "")], &env_refs);
    }
    fs::write(root.join("gh.log.fail"), "").unwrap();
    out += &transcript_env(&qm, "p-one", &[(&["pr", "p-one"], "")], &env_refs);
    out += &format!("gh log:\n{}", fs::read_to_string(root.join("gh.log")).unwrap_or_default());
    golden("cli_pr.txt", &scrub(&qm, &out));
}
