//! The Rust GUI server (`QM_RUST_GUI=1 qm gui`) next to Ruby's, both on one data root: the same
//! request goes to each and the status, content type and body must agree, route by route. Only what
//! is ported is compared; the rest answers 501 here.

mod common;
use common::git;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

struct Server {
    child: Child,
    port: u16,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn start(rust: bool, root: &Path, home: &Path) -> Server {
    let port = free_port();
    let bin: PathBuf = if rust { Path::new(env!("CARGO_BIN_EXE_qm")).into() } else { Path::new(env!("CARGO_MANIFEST_DIR")).join("quartermaster") };
    let mut cmd = Command::new(bin);
    cmd.arg("gui").env("QM_ROOT", root).env("HOME", home).env("QM_GUI_PORT", port.to_string()).env("QM_GUI_NO_OPEN", "1").env("LANG", "C.UTF-8").env("LC_ALL", "C.UTF-8").env("QM_TMUX_SOCKET", "qm-test-gui").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    if rust {
        cmd.env("QM_RUST_GUI", "1");
    }
    let child = cmd.spawn().unwrap();
    for _ in 0..100 {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return Server { child, port };
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    panic!("the GUI did not come up");
}

struct Answer {
    status: String,
    content_type: String,
    body: Vec<u8>,
}

fn request(port: u16, method: &str, path: &str, headers: &[(&str, String)], body: &str, own_host: bool) -> Answer {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let mut req = format!("{method} {path} HTTP/1.1\r\n");
    if own_host {
        req += &format!("Host: 127.0.0.1:{port}\r\n");
    }
    for (k, v) in headers {
        req += &format!("{k}: {}\r\n", v.replace("PORT", &port.to_string()));
    }
    req += &format!("Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
    stream.write_all(req.as_bytes()).unwrap();
    let mut raw = vec![];
    stream.read_to_end(&mut raw).unwrap();
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = String::from_utf8_lossy(&raw[..split]).into_owned();
    let status = head.lines().next().unwrap().trim_start_matches("HTTP/1.1 ").to_string();
    let content_type = head.lines().find_map(|l| l.strip_prefix("Content-Type: ")).unwrap_or("").to_string();
    Answer { status, content_type, body: raw[split + 4..].to_vec() }
}

fn shown(a: &Answer, port: u16) -> String {
    let body = String::from_utf8_lossy(&a.body).replace(&port.to_string(), "PORT");
    let body = regex::Regex::new(r"let terminalToken = \x22[0-9a-f]{48}\x22").unwrap().replace_all(&body, "let terminalToken = TOKEN").into_owned();
    format!("{} | {} | {body}", a.status, a.content_type)
}

fn world(base: &Path) -> (PathBuf, PathBuf, String) {
    let (root, home, repo) = (base.join("root"), base.join("home"), base.join("repo"));
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("a.txt"), "one\ntwo\r\nthree\n\nlast without newline").unwrap();
    fs::write(repo.join("bytes.bin"), b"ok \xff\xfe bad\nnext \xe2\x82 line\n").unwrap();
    fs::write(repo.join("big.txt"), "x".repeat(70) + "\n").unwrap();
    let many: String = (0..25_000).map(|i| format!("line {i}\n")).collect();
    fs::write(repo.join("many.txt"), many).unwrap();
    let wide: String = (0..30_000).map(|i| format!("{i:030}\n")).collect();
    fs::write(repo.join("wide.txt"), wide).unwrap();
    fs::write(repo.join("empty.txt"), "").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t.test", "commit", "-q", "-m", "one"]);
    let sha = git(&repo, &["rev-parse", "HEAD"]);
    fs::create_dir_all(root.join("work-items")).unwrap();
    fs::write(root.join("config.yml"), format!("projects:\n  demo: {}\n", repo.display())).unwrap();
    for (slug, project) in [("demo-item", "demo"), ("orphan", "elsewhere")] {
        fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {slug}\nstate: in_progress\nproject: {project}\ncreated: '2026-01-01'\n---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")).unwrap();
    }
    fs::write(root.join("sessions.jsonl"), "{\"v\":1,\"event\":\"start\",\"session_id\":\"s1\",\"ts\":\"2026-03-01T00:00:00+00:00\"}\n").unwrap();
    fs::write(root.join("events.jsonl"), "{\"v\":1}\n").unwrap();
    fs::create_dir_all(root.join("drafts")).unwrap();
    fs::write(root.join("drafts/demo-item.json"), "{\"v\":1,\"entries\":[]}").unwrap();
    fs::write(root.join("drafts/.demo-item.lock"), "").unwrap();
    fs::create_dir_all(root.join("issues/demo-item/.prev")).unwrap();
    fs::write(root.join("issues/demo-item/01-a.md"), "---\ntitle: A\nkind: bug\n---\n").unwrap();
    fs::write(root.join("issues/demo-item/.prev/01-a.md.json"), "{}").unwrap();
    fs::create_dir_all(root.join("issues/a-b")).unwrap();
    fs::write(root.join("issues/a-b/x.md"), "x").unwrap();
    fs::create_dir_all(root.join("issues/a")).unwrap();
    fs::write(root.join("issues/a/x.md"), "x").unwrap();
    (root, home, sha)
}

#[test]
fn the_rust_server_answers_the_ported_routes_as_ruby_does() {
    let base = tempfile::tempdir().unwrap();
    let (root, home, sha) = world(base.path());
    let ruby = start(false, &root, &home);
    let rust = start(true, &root, &home);
    let mut log = String::new();
    let mut check = |label: &str, method: &str, path: &str, headers: &[(&str, String)], body: &str, own_host: bool| {
        let (a, b) = (request(ruby.port, method, path, headers, body, own_host), request(rust.port, method, path, headers, body, own_host));
        let (ra, rb) = (shown(&a, ruby.port), shown(&b, rust.port));
        assert_eq!(rb, ra, "{label}: {method} {path}");
        log += &format!("{label}: {}\n", ra.chars().take(160).collect::<String>().replace('\n', "↵"));
    };
    check("page", "GET", "/", &[], "", true);
    for asset in ["css/base.css", "js/core.js", "js/events.js", "css/diff.css"] {
        check("asset", "GET", &format!("/assets/{asset}"), &[], "", true);
    }
    for bad in ["/assets/css/nope.css", "/assets/js/../../page.html", "/assets/css/Base.css", "/assets/js/core.js.map", "/assets/"] {
        check("bad asset", "GET", bad, &[], "", true);
    }
    check("pulse", "GET", "/api/pulse", &[], "", true);
    check("pulse with query", "GET", "/api/pulse?visible=1&focused=1&chat=demo-item", &[], "", true);
    fs::write(root.join("events.jsonl"), "{\"v\":1}\n{\"v\":2}\n").unwrap();
    fs::write(root.join("drafts/other.json"), "{\"v\":1,\"entries\":[{\"id\":\"x\"}]}").unwrap();
    fs::create_dir_all(root.join("issues/zz")).unwrap();
    fs::write(root.join("issues/zz/y.md"), "y").unwrap();
    check("pulse after changes", "GET", "/api/pulse", &[], "", true);
    let slug = "demo-item";
    for (label, query) in [
        ("file", format!("rev={sha}&path=a.txt")),
        ("short sha", format!("rev={}&path=a.txt", &sha[..7])),
        ("upper sha", format!("rev={}&path=a.txt", sha.to_uppercase())),
        ("bytes", format!("rev={sha}&path=bytes.bin")),
        ("empty file", format!("rev={sha}&path=empty.txt")),
        ("many lines", format!("rev={sha}&path=many.txt")),
        ("many bytes", format!("rev={sha}&path=wide.txt")),
        ("missing", format!("rev={sha}&path=nope.txt")),
        ("tree not blob", format!("rev={sha}&path=")),
        ("no path", format!("rev={sha}")),
        ("no rev", "path=a.txt".to_string()),
        ("bad rev", "rev=zzzz&path=a.txt".to_string()),
        ("quoted rev", "rev=a%22b%0A%23%7Bx%7D&path=a.txt".to_string()),
        ("too short", "rev=abc&path=a.txt".to_string()),
        ("plus path", format!("rev={sha}&path=a%20.txt")),
        ("nul path", format!("rev={sha}&path=a.txt%00x")),
        ("option-like path", format!("rev={sha}&path=--help")),
        ("repeated key", format!("rev=zzz&rev={sha}&path=a.txt")),
    ] {
        check(label, "GET", &format!("/api/diff-file/{slug}?{query}"), &[], "", true);
    }
    check("unknown item", "GET", &format!("/api/diff-file/nosuch?rev={sha}&path=a.txt"), &[], "", true);
    check("no project root", "GET", &format!("/api/diff-file/orphan?rev={sha}&path=a.txt"), &[], "", true);
    check("encoded slug", "GET", &format!("/api/diff-file/demo%2Ditem?rev={sha}&path=a.txt"), &[], "", true);
    check("bad host", "GET", "/api/pulse", &[("Host", "evil.test".into())], "", false);
    check("no host", "GET", "/api/pulse", &[], "", false);
    check("localhost host", "GET", "/api/pulse", &[("Host", "localhost:PORT".into())], "", false);
    check("foreign origin", "POST", "/api/action", &[("Origin", "http://evil.test".into())], "{}", true);
    check("no origin, not local", "POST", "/api/action", &[], "{\"cmd\":\"state\"}", true);
    check("no origin, junk", "POST", "/api/action", &[], "not json", true);
    check("no origin, other route", "POST", "/api/grep", &[], "{}", true);
    // the use log: what each server recorded, by kind and name only
    let uses = fs::read_to_string(root.join("feature-use.jsonl")).unwrap_or_default();
    let names: Vec<String> = uses.lines().map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()).map(|v| format!("{} {}", v["kind"], v["name"])).collect();
    let mut counts = std::collections::BTreeMap::new();
    for n in names.iter().filter(|n| !n.starts_with("\"cli\"")) {
        *counts.entry(n.clone()).or_insert(0) += 1;
    }
    assert!(counts.contains_key("\"get\" \"/api/diff-file\"") && counts.contains_key("\"action\" \"state\"") == false);
    for (name, n) in &counts {
        assert_eq!(n % 2, 0, "{name} is recorded once by each server: {counts:?}");
    }
    assert!(log.lines().count() > 40, "{log}");
}

fn sh(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(["-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t.test", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"])
        .args(args)
        .env("GIT_AUTHOR_DATE", "2026-02-01T10:00:00+00:00")
        .env("GIT_COMMITTER_DATE", "2026-02-01T10:00:00+00:00")
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn lines(prefix: &str, n: usize) -> String {
    (1..=n).map(|i| format!("{prefix} {i}\n")).collect()
}

fn commit(dir: &Path, msg: &str) {
    sh(dir, &["add", "-A"]);
    sh(dir, &["commit", "-q", "-m", msg]);
}

/// A repo with a checked-out feature branch (committed, staged-and-not and untracked changes, a rename,
/// a deletion, a binary), an issue branch, a gh-stack of two (the top has no worktree), a ref-only
/// branch and an origin-only one.
fn diff_world(base: &Path) -> (PathBuf, PathBuf, PathBuf) {
    let (root, home, repo, origin) = (base.join("root"), base.join("home"), base.join("repo"), base.join("origin.git"));
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    fs::create_dir_all(&origin).unwrap();
    sh(&origin, &["init", "-q", "--bare"]);
    sh(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("a.txt"), lines("alpha", 20)).unwrap();
    fs::write(repo.join("b.txt"), lines("beta", 12)).unwrap();
    fs::write(repo.join("old_name.txt"), lines("rename me", 15)).unwrap();
    fs::write(repo.join("del.txt"), lines("delete me", 5)).unwrap();
    fs::write(repo.join("bin.dat"), b"\x00\x01\x02binary\xff").unwrap();
    fs::write(repo.join("héllo wörld.txt"), lines("unicode", 4)).unwrap();
    fs::write(repo.join("crlf.txt"), (1..=8).map(|i| format!("crlf {i}\r\n")).collect::<String>()).unwrap();
    fs::write(repo.join("nonl.txt"), "first\nsecond\nno newline at the end").unwrap();
    fs::write(repo.join("shift.txt"), lines("shift", 40)).unwrap();
    commit(&repo, "base");
    sh(&repo, &["remote", "add", "origin", origin.to_str().unwrap()]);
    sh(&repo, &["push", "-q", "origin", "main"]);

    let wt = |name: &str, branch: &str, from: &str| -> PathBuf {
        let p = base.join(name);
        sh(&repo, &["worktree", "add", "-q", "-b", branch, p.to_str().unwrap(), from]);
        p
    };
    let feat = wt("wt-feat", "feat", "main");
    let mut a = lines("alpha", 20);
    a = a.replace("alpha 3\n", "alpha three changed\n");
    fs::write(feat.join("a.txt"), a).unwrap();
    fs::write(feat.join("d.txt"), lines("new file", 6)).unwrap();
    fs::write(feat.join("crlf.txt"), (1..=8).map(|i| if i == 4 { "crlf four changed\r\n".to_string() } else { format!("crlf {i}\r\n") }).collect::<String>()).unwrap();
    fs::write(feat.join("nonl.txt"), "first\nsecond\nchanged without newline").unwrap();
    fs::write(feat.join("shift.txt"), lines("top", 3) + &lines("shift", 40)).unwrap();
    commit(&feat, "feat one");
    fs::rename(feat.join("old_name.txt"), feat.join("new_name.txt")).unwrap();
    fs::remove_file(feat.join("del.txt")).unwrap();
    fs::write(feat.join("bin.dat"), b"\x00\x09changed\xff\xfe").unwrap();
    fs::write(feat.join("héllo wörld.txt"), lines("unicode", 4) + "more\n").unwrap();
    commit(&feat, "feat two: rename, delete, binary");
    let a2 = fs::read_to_string(feat.join("a.txt")).unwrap().replace("alpha 8\n", "alpha eight uncommitted\n").replace("alpha 15\n", "");
    fs::write(feat.join("a.txt"), a2).unwrap();
    fs::write(feat.join("b.txt"), lines("beta", 12).replace("beta 6\n", "beta six uncommitted\nextra line\n")).unwrap();
    fs::write(feat.join("new_name.txt"), lines("rename me", 15) + "appended later\n").unwrap();
    let shifted = fs::read_to_string(feat.join("shift.txt")).unwrap().replace("shift 25\n", "");
    fs::write(feat.join("shift.txt"), shifted).unwrap();
    fs::write(feat.join("untracked.txt"), "brand new\nfile\n").unwrap();
    fs::write(feat.join("big_untracked.txt"), lines("big", 25_000)).unwrap();
    fs::write(feat.join("too_big_untracked.bin"), vec![b'x'; 1_100_000]).unwrap();

    let issue = wt("wt-issue", "issue/12-x", "main");
    fs::write(issue.join("issue.txt"), lines("issue work", 3)).unwrap();
    commit(&issue, "issue one");
    let issue3 = wt("wt-issue3", "issue/3-y", "main");
    fs::write(issue3.join("issue3.txt"), lines("issue three", 2)).unwrap();
    commit(&issue3, "issue three one");
    let sa = wt("wt-sa", "stack-a", "main");
    fs::rename(sa.join("old_name.txt"), sa.join("sa_renamed.txt")).unwrap();
    fs::write(sa.join("sa.txt"), lines("stack a", 4)).unwrap();
    fs::write(sa.join("a.txt"), lines("alpha", 20).replace("alpha 1\n", "alpha one from stack a\n")).unwrap();
    commit(&sa, "stack a one");
    sh(&repo, &["branch", "stack-b", "stack-a"]);
    sh(&repo, &["branch", "refonly", "main"]);
    sh(&repo, &["checkout", "-q", "refonly"]);
    fs::write(repo.join("ro.txt"), lines("ref only", 3)).unwrap();
    commit(&repo, "ref only one");
    sh(&repo, &["checkout", "-q", "-b", "remote-only", "main"]);
    fs::write(repo.join("rem.txt"), lines("remote only", 2)).unwrap();
    commit(&repo, "remote only one");
    sh(&repo, &["push", "-q", "origin", "remote-only"]);
    sh(&repo, &["checkout", "-q", "main"]);
    sh(&repo, &["branch", "-q", "-D", "remote-only"]);
    // stack-b gets its own commit through a temporary worktree, then the worktree goes
    let tmp = wt("wt-tmp", "stack-b-tmp", "stack-b");
    fs::write(tmp.join("sb.txt"), lines("stack b", 2)).unwrap();
    commit(&tmp, "stack b one");
    let tip = sh(&tmp, &["rev-parse", "HEAD"]);
    sh(&repo, &["worktree", "remove", "--force", tmp.to_str().unwrap()]);
    sh(&repo, &["branch", "-q", "-D", "stack-b-tmp"]);
    sh(&repo, &["branch", "-f", "stack-b", &tip]);
    // the trunk takes a copy of stack-b's commit (a squash-merge leftover): `git cherry` calls it equivalent
    sh(&repo, &["cherry-pick", &tip]);
    sh(&repo, &["push", "-q", "origin", "main"]);
    sh(&repo, &["checkout", "-q", "-b", "many", "main"]);
    for i in 0..205 {
        sh(&repo, &["commit", "-q", "--allow-empty", "-m", &format!("empty {i}")]);
    }
    sh(&repo, &["checkout", "-q", "main"]);
    sh(&repo, &["remote", "set-url", "origin", "git@github.com:acme/widgets.git"]);
    fs::write(repo.join(".git/gh-stack"), r#"{"stacks":[{"trunk":{"branch":"main"},"branches":[{"branch":"stack-a"},{"branch":"stack-b","pullRequest":{"number":2,"url":"https://github.com/acme/widgets/pull/2"}}]},{"trunk":{"branch":"main"},"branches":[{"branch":"many"}]}]}"#).unwrap();

    fs::create_dir_all(root.join("work-items")).unwrap();
    fs::write(root.join("config.yml"), format!("projects:\n  demo: {}\n", repo.display())).unwrap();
    let item = |slug: &str, branches: &[&str], title: &str, desc: &str| {
        let list: String = branches.iter().map(|b| format!("- {b}\n")).collect();
        let list = if list.is_empty() { String::new() } else { format!("branches:\n{list}") };
        fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {title}\nstate: in_progress\nproject: demo\ncreated: '2026-01-01'\n{list}---\n\n## Description\n\n{desc}\n\n## Notes\n\n## Snapshots\n")).unwrap();
    };
    item("diff-item", &["feat", "refonly", "remote-only", "stack-a", "issue/12-x", "issue/3-y", "many"], "Diff item", "d");
    item("stack-item-r", &["stack-a"], "Stack item r", "d");
    item("stack-item", &["stack-a"], "Stack item", "d");
    item("nobranch", &[], "No branch", "d");
    item("review-item", &["feat"], "Review acme/widgets#9: x", "Review of pull request https://github.com/acme/widgets/pull/9");
    fs::write(root.join("pr-inbox.json"), r#"{"prs":[{"repo":"Acme/Widgets","head":"feat","number":5,"url":"https://github.com/acme/widgets/pull/5"}],"ts":1}"#).unwrap();
    fs::create_dir_all(root.join("viewed")).unwrap();
    (root, home, feat)
}

#[test]
fn the_diff_payload_matches_ruby_scope_by_scope() {
    let base = tempfile::tempdir().unwrap();
    let (root, home, _feat) = diff_world(base.path());
    let ruby = start(false, &root, &home);
    let rust = start(true, &root, &home);
    let mut compared = 0;
    let mut seen = String::new();
    let mut check = |path: &str| {
        let (a, b) = (request(ruby.port, "GET", path, &[], "", true), request(rust.port, "GET", path, &[], "", true));
        if a.status.starts_with("501") {
            return;
        }
        assert_eq!(b.status, a.status, "{path}");
        let (sa, sb) = (shown(&a, ruby.port), shown(&b, rust.port));
        if sa != sb {
            let at = sa.bytes().zip(sb.bytes()).position(|(x, y)| x != y).unwrap_or(sa.len().min(sb.len()));
            let from = at.saturating_sub(200);
            let cut = |s: &str| s.get(from..(from + 500).min(s.len())).unwrap_or("").to_string();
            panic!("{path}: first difference at byte {at}\nRuby: …{}\nRust: …{}", cut(&sa), cut(&sb));
        }
        compared += 1;
        seen.push_str(&sa);
    };
    for (slug, query) in [
        ("diff-item", ""),
        ("diff-item", "?scope=branch"),
        ("diff-item", "?scope=branch&branch=feat"),
        ("diff-item", "?scope=commits&branch=feat"),
        ("diff-item", "?scope=uncommitted&branch=feat"),
        ("diff-item", "?scope=branch&branch=issue%2F12-x"),
        ("diff-item", "?scope=commits&branch=stack-a"),
        ("diff-item", "?scope=branch&branch=stack-a"),
        ("diff-item", "?scope=branch&branch=stack-b"),
        ("diff-item", "?scope=commits&branch=stack-b"),
        ("diff-item", "?scope=uncommitted&branch=stack-b"),
        ("diff-item", "?scope=branch&branch=stack-b&base=main"),
        ("diff-item", "?scope=commits&branch=stack-b&base=stack-a"),
        ("diff-item", "?scope=branch&branch=stack-b&base=nope"),
        ("diff-item", "?scope=branch&branch=refonly"),
        ("diff-item", "?scope=commits&branch=refonly"),
        ("diff-item", "?scope=uncommitted&branch=refonly"),
        ("diff-item", "?scope=branch&branch=remote-only"),
        ("diff-item", "?scope=commits&branch=remote-only"),
        ("diff-item", "?scope=branch&branch=unlinked"),
        ("diff-item", "?scope=bogus"),
        ("diff-item", "?scope="),
        ("stack-item", ""),
        ("stack-item", "?scope=commits"),
        ("diff-item", "?scope=commits&branch=many"),
        ("diff-item", "?scope=branch&branch=many"),
        ("diff-item", "?scope=branch&branch=issue%2F3-y"),
        ("nobranch", ""),
        ("nosuch", ""),
    ] {
        check(&format!("/api/diff/{slug}{query}"));
    }
    // the first load of a stack's item links its other stack branches: Rust must do that too
    let (b, a) = (request(rust.port, "GET", "/api/diff/stack-item-r?scope=branch", &[], "", true), request(ruby.port, "GET", "/api/diff/stack-item-r?scope=branch", &[], "", true));
    assert_eq!(shown(&b, rust.port), shown(&a, ruby.port));
    assert!(fs::read_to_string(root.join("work-items/stack-item-r.md")).unwrap().contains("- stack-b"), "the item should now link the whole stack");
    // a selected run of commits
    let feat_commits = sh(&base.path().join("repo"), &["log", "--format=%H", "main..feat"]);
    let shas: Vec<&str> = feat_commits.lines().collect();
    let (newest, oldest) = (shas[0], shas[1]);
    for query in [
        format!("?scope=commits&branch=feat&from={oldest}&to={oldest}"),
        format!("?scope=commits&branch=feat&from={oldest}&to={newest}"),
        format!("?scope=commits&branch=feat&from={}", &newest[..8]),
        format!("?scope=commits&branch=feat&to={}", &oldest[..7]),
        format!("?scope=commits&branch=feat&from={newest}&to={oldest}"),
        "?scope=commits&branch=feat&from=zzzz".to_string(),
        "?scope=commits&branch=feat&from=abcd1234".to_string(),
        format!("?scope=commits&branch=feat&from={}", sh(&base.path().join("repo"), &["rev-parse", "main"])),
    ] {
        check(&format!("/api/diff/diff-item{query}"));
    }
    // viewed marks ride along
    let first = request(ruby.port, "GET", "/api/diff/diff-item?scope=branch&branch=feat", &[], "", true);
    let payload: serde_json::Value = serde_json::from_slice(&first.body).unwrap();
    let file = &payload["files"][0];
    fs::write(root.join("viewed/diff-item.json"), serde_json::json!({"v": 1, "marks": {file["path"].as_str().unwrap(): [file["digest"]]}}).to_string()).unwrap();
    check("/api/diff/diff-item?scope=branch&branch=feat");
    // without a pr-inbox cache
    fs::remove_file(root.join("pr-inbox.json")).unwrap();
    check("/api/diff/diff-item?scope=branch&branch=feat");
    // the chat's own pane picks the checkout
    let socket = "qm-test-gui";
    let tmux = |args: &[&str]| Command::new("tmux").args(["-L", socket]).args(args).output();
    let _ = tmux(&["kill-server"]);
    if tmux(&["new-session", "-d", "-s", "diff-item", "-c", base.path().join("wt-sa").to_str().unwrap(), "sleep 60"]).is_ok_and(|o| o.status.success()) {
        check("/api/diff/diff-item");
        check("/api/diff/diff-item?scope=commits");
        let _ = tmux(&["kill-server"]);
    }
    assert!(compared > 35, "compared {compared}");
    for expected in ["\"ok\":true", "\"ok\":false", "\"commitStatus\":\"mixed\"", "\"commitStatus\":\"uncommitted\"", "\"commitStatus\":\"committed\"", "\"uncommitted\":true", "\"layers\":[", "\"alsoIn\":\"", "\"fileLayers\"", "\"kind\":\"stack\"", "\"kind\":\"stack-span\"", "\"kind\":\"trunk\"", "\"checkout\":false", "\"truncated\":true", "\"binary\":true", "\"status\":\"renamed\"", "\"status\":\"deleted\"", "\"prAvailable\":true", "\"viewed\":true", "\"chat\":true", "\"range\":{", "\"messages\":[{", "\"commitCount\":205", "\"n\":205"] {
        assert!(seen.contains(expected), "the payloads should contain {expected}");
    }
}
