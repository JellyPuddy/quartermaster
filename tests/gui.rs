//! The Rust GUI server (`QM_RUST_GUI=1 qm gui`) next to Ruby's, both on one data root: the same
//! request goes to each and the status, content type and body must agree, route by route. Only what
//! is ported is compared; the rest answers 501 here.

mod common;
use common::{attention_world, git};
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
    start_env(rust, root, home, &[])
}

fn start_env(rust: bool, root: &Path, home: &Path, extra: &[(&str, String)]) -> Server {
    let port = free_port();
    let bin: PathBuf = if rust { Path::new(env!("CARGO_BIN_EXE_qm")).into() } else { Path::new(env!("CARGO_MANIFEST_DIR")).join("quartermaster") };
    let mut cmd = Command::new(bin);
    cmd.arg("gui").env("QM_ROOT", root).env("HOME", home).env("QM_GUI_PORT", port.to_string()).env("QM_GUI_NO_OPEN", "1").env("LANG", "C.UTF-8").env("LC_ALL", "C.UTF-8").env("QM_TMUX_SOCKET", "qm-test-gui").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    if rust {
        cmd.env("QM_RUST_GUI", "1");
    }
    for (k, v) in extra {
        cmd.env(k, v);
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

fn git_at(dir: &Path, when: &str, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(["-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t.test", "-c", "init.defaultBranch=main"])
        .args(args)
        .env("GIT_AUTHOR_DATE", when)
        .env("GIT_COMMITTER_DATE", when)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// Records the worktree as the UserPromptSubmit hook does, then dates the line `at`.
fn snapshot(root: &Path, wt: &Path, session: &str, at: &str) {
    let mut child = Command::new("sh")
        .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("hooks/snapshot-worktree.sh"))
        .env("QM_ROOT", root)
        .env_remove("QM_SKIP")
        .env_remove("QM_ASIDE")
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(format!("{{\"session_id\":\"{session}\",\"cwd\":\"{}\"}}", wt.display()).as_bytes()).unwrap();
    child.wait().unwrap();
    let file = root.join("prompt-snapshots.jsonl");
    let text = fs::read_to_string(&file).unwrap();
    let mut lines: Vec<String> = text.lines().map(String::from).collect();
    let last = lines.pop().unwrap();
    lines.push(regex::Regex::new(r#""at":"[^"]+""#).unwrap().replace(&last, format!("\"at\":\"{at}\"")).into_owned());
    fs::write(file, lines.join("\n") + "\n").unwrap();
}

fn prompt_world(base: &Path) -> (PathBuf, PathBuf) {
    let (root, home, repo) = (base.join("root"), base.join("home"), base.join("repo"));
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    fs::create_dir_all(root.join("work-items")).unwrap();
    let d = |t: &str| format!("2026-04-01T{t}+00:00");
    git_at(&repo, &d("09:00:00"), &["init", "-q", "-b", "main"]);
    fs::write(repo.join("a.txt"), lines("alpha", 10)).unwrap();
    fs::write(repo.join("c.txt"), lines("gamma", 6)).unwrap();
    fs::write(repo.join("d.txt"), lines("delta", 6)).unwrap();
    fs::write(repo.join("gone.txt"), "going away\n").unwrap();
    git_at(&repo, &d("09:00:00"), &["add", "-A"]);
    git_at(&repo, &d("09:00:00"), &["commit", "-q", "-m", "base"]);
    let wt = base.join("wt-chat");
    git_at(&repo, &d("09:01:00"), &["worktree", "add", "-q", "-b", "feat", wt.to_str().unwrap(), "main"]);
    git_at(&repo, &d("09:02:00"), &["branch", "refonly", "main"]);
    git_at(&repo, &d("10:05:00"), &["branch", "before-only", "main"]);
    snapshot(&root, &wt, "s1", "2026-04-01T10:00:00Z");
    fs::write(wt.join("a.txt"), lines("alpha", 10).replace("alpha 3\n", "alpha three changed\n")).unwrap();
    fs::write(wt.join("new.txt"), "a new file\n").unwrap();
    fs::remove_file(wt.join("gone.txt")).unwrap();
    snapshot(&root, &wt, "s1", "2026-04-01T10:10:00Z");
    git_at(&wt, &d("10:15:00"), &["add", "-A"]);
    git_at(&wt, &d("10:15:00"), &["commit", "-q", "-m", "feat one"]);
    fs::write(wt.join("a.txt"), fs::read_to_string(wt.join("a.txt")).unwrap().replace("alpha 7\n", "alpha seven uncommitted\n")).unwrap();
    snapshot(&root, &wt, "s1", "2026-04-01T10:20:00Z");
    fs::write(wt.join("c.txt"), lines("gamma", 6).replace("gamma 2\n", "gamma two mine\n")).unwrap();
    snapshot(&root, &wt, "s1", "2026-04-01T10:30:00Z");
    // work elsewhere: branches that moved since the prompts
    let tree = git_at(&repo, &d("10:31:00"), &["rev-parse", "main^{tree}"]);
    let parent = git_at(&repo, &d("10:31:00"), &["rev-parse", "main"]);
    let other = git_at(&repo, &d("10:32:00"), &["commit-tree", &tree, "-p", &parent, "-m", "other work"]);
    git_at(&repo, &d("10:32:00"), &["update-ref", "-m", "other moves", "refs/heads/other", &other]);
    git_at(&repo, &d("10:33:00"), &["update-ref", "-m", "branch: Created", "refs/heads/created-later", &other]);
    let before_only = git_at(&repo, &d("10:05:00"), &["commit-tree", &tree, "-p", &parent, "-m", "before only"]);
    git_at(&repo, &d("10:06:00"), &["update-ref", "-m", "moved early", "refs/heads/before-only", &before_only]);
    let (mut tip, mut n) = (parent.clone(), 0);
    for (when, name) in [("10:20:00", "a"), ("10:30:00", "b"), ("10:34:00", "c")] {
        n += 1;
        tip = git_at(&repo, &d(when), &["commit-tree", &tree, "-p", &tip, "-m", &format!("at prompt {name}{n}")]);
        git_at(&repo, &d(when), &["update-ref", "-m", "step", "refs/heads/at-prompt", &tip]);
    }
    git_at(&repo, &d("10:30:00"), &["update-ref", "-m", "exactly at the prompt", "refs/heads/at-exact", &parent]);
    // the trunk moves on, and the chat's branch is rebased onto it
    fs::write(repo.join("d.txt"), lines("delta", 6).replace("delta 5\n", "delta five upstream\n")).unwrap();
    git_at(&repo, &d("10:35:00"), &["commit", "-q", "-a", "-m", "m1"]);
    fs::write(repo.join("c.txt"), lines("gamma", 6).replace("gamma 2\n", "gamma two theirs\n")).unwrap();
    git_at(&repo, &d("10:36:00"), &["commit", "-q", "-a", "-m", "m2"]);
    git_at(&wt, &d("10:39:00"), &["stash", "-q"]);
    git_at(&wt, &d("10:40:00"), &["rebase", "-q", "main"]);
    git_at(&wt, &d("10:41:00"), &["stash", "drop", "-q"]);
    fs::write(wt.join("a.txt"), fs::read_to_string(wt.join("a.txt")).unwrap().replace("alpha 9\n", "alpha nine after\n")).unwrap();
    fs::write(wt.join("after.txt"), "after the rebase\n").unwrap();

    // the transcript the prompts come from, and the log of sessions
    let transcript = base.join("s1.jsonl");
    let user = |ts: &str, text: &str| serde_json::json!({"type": "user", "timestamp": ts, "message": {"content": text}}).to_string();
    let long = format!("{}\nsecond line of the prompt", "A very long first line of a prompt that goes on and on past the eighty character limit for labels ");
    fs::write(
        &transcript,
        [
            serde_json::json!({"type": "user", "timestamp": "2026-04-01T10:00:00.500Z", "isSidechain": true, "message": {"content": "a sidechain prompt that comes first"}}).to_string(),
            user("2026-04-01T10:00:01.000Z", "first prompt"),
            serde_json::json!({"type": "user", "timestamp": "2026-04-01T10:05:00.000Z", "isSidechain": true, "message": {"content": "a sidechain prompt"}}).to_string(),
            user("2026-04-01T10:10:02.500Z", &long),
            user("2026-04-01T10:20:01.000Z", "[Request interrupted by user]"),
            serde_json::json!({"type": "user", "timestamp": "2026-04-01T10:21:00.000Z", "isCompactSummary": true, "message": {"content": "summary"}}).to_string(),
            serde_json::json!({"type": "user", "timestamp": "2026-04-01T10:22:00.000Z", "toolUseResult": {"x": 1}, "message": {"content": "tool output"}}).to_string(),
            user("2026-04-01T10:29:57.500Z", "fourth prompt, a couple of seconds before its snapshot"),
            "not json at all".to_string(),
        ]
        .join("\n")
            + "\n",
    )
    .unwrap();
    let me = std::process::id();
    let start = |id: &str, pid: u32, cwd: &Path, ts: &str, transcript: &str| format!("{{\"v\":1,\"event\":\"start\",\"session_id\":\"{id}\",\"cwd\":\"{}\",\"pid\":{pid},\"transcript_path\":\"{transcript}\",\"ts\":\"{ts}\"}}\n", cwd.display());
    fs::write(
        root.join("sessions.jsonl"),
        start("s1", me, &wt, "2026-04-01T10:00:00+00:00", transcript.to_str().unwrap())
            + &start("s0", 999_999, &wt, "2026-03-01T10:00:00+00:00", "/nonexistent.jsonl")
            + &start("s2", 999_999, &wt, "2026-03-02T10:00:00+00:00", "/nonexistent.jsonl")
            + &start("s3", 999_999, &wt, "2026-03-03T10:00:00+00:00", "/nonexistent.jsonl")
            + &start("s4", 999_999, &wt, "2026-03-04T10:00:00+00:00", "/nonexistent.jsonl")
            + &start("s5", me, &wt, "2026-03-10T10:00:00+00:00", "/nonexistent.jsonl")
            + &start("s6", 999_999, &wt, "2026-03-11T10:00:00+00:00", "/nonexistent.jsonl"),
    )
    .unwrap();
    let mut snaps = fs::read_to_string(root.join("prompt-snapshots.jsonl")).unwrap();
    let t0 = git_at(&wt, &d("11:00:00"), &["rev-parse", "HEAD^{tree}"]);
    snaps += &format!("{{\"v\":1,\"session_id\":\"s0\",\"cwd\":\"{w}\",\"toplevel\":\"{w}\",\"tree\":\"{t0}\",\"at\":\"2026-03-01T10:00:00Z\"}}\n", w = wt.display());
    for s in ["s5", "s6"] {
        snaps += &format!("{{\"v\":1,\"session_id\":\"{s}\",\"cwd\":\"{w}\",\"toplevel\":\"{w}\",\"tree\":\"{t0}\",\"at\":\"2026-03-12T10:00:00Z\"}}\n", w = wt.display());
    }
    snaps += &format!("{{\"v\":1,\"session_id\":\"s3\",\"cwd\":\"/nowhere/at/all\",\"toplevel\":\"/nowhere/at/all\",\"tree\":\"{t0}\",\"at\":\"2026-03-03T10:00:00Z\"}}\n");
    snaps += &format!("{{\"v\":1,\"session_id\":\"s4\",\"cwd\":\"{w}\",\"toplevel\":\"{w}\",\"tree\":\"{}\",\"at\":\"2026-03-04T10:00:00Z\"}}\n", "ab".repeat(20), w = wt.display());
    snaps += &format!("{{\"v\":1,\"session_id\":\"s1\",\"toplevel\":\"{w}\",\"tree\":\"not a tree\",\"at\":\"2026-04-01T10:40:00Z\"}}\n{{\"v\":1,\"session_id\":\"s1\",\"tree\":\"{t0}\",\"at\":\"nonsense\"}}\n{{\"v\":1,\"session_id\":\"s1\",\"toplevel\":\"{w}\",\"tre", w = wt.display());
    fs::write(root.join("prompt-snapshots.jsonl"), snaps).unwrap();
    fs::write(root.join("config.yml"), format!("projects:\n  demo: {}\n", repo.display())).unwrap();
    let item = |slug: &str, sessions: &[&str], branches: &[&str]| {
        let s: String = sessions.iter().map(|s| format!("- id: {s}\n")).collect();
        let s = if s.is_empty() { String::new() } else { format!("sessions:\n{s}") };
        let b: String = branches.iter().map(|b| format!("- {b}\n")).collect();
        let b = if b.is_empty() { String::new() } else { format!("branches:\n{b}") };
        fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {slug}\nstate: in_progress\nproject: demo\ncreated: '2026-01-01'\n{b}{s}---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")).unwrap();
    };
    item("chat-item", &["s1", "s0"], &["feat", "refonly"]);
    item("nosession", &[], &["feat"]);
    item("nosnap", &["s2"], &[]);
    item("gone-item", &["s3"], &[]);
    item("pruned-item", &["s4"], &[]);
    item("uncaptured-item", &["never-logged"], &[]);
    item("live-older", &["s6", "s5"], &[]);
    (root, home)
}

#[test]
fn the_prompt_scope_matches_ruby() {
    let base = tempfile::tempdir().unwrap();
    let (root, home) = prompt_world(base.path());
    let ruby = start(false, &root, &home);
    let rust = start(true, &root, &home);
    let mut seen = String::new();
    let mut compared = 0;
    let mut check = |path: &str| {
        let (a, b) = (request(ruby.port, "GET", path, &[], "", true), request(rust.port, "GET", path, &[], "", true));
        assert!(!b.status.starts_with("501"), "{path} should be served: {}", String::from_utf8_lossy(&b.body));
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
    let q = "/api/diff/chat-item?scope=prompt";
    for extra in [
        "", "&prompt=s1:1", "&prompt=s1:2", "&prompt=s1:3", "&prompt=s1:4", "&prompt=s1:5", "&prompt=s1:0", "&prompt=s1:%2B2", "&prompt=s1:0x2", "&prompt=s1:_2", "&prompt=s1:2_", "&prompt=s1:2_0", "&prompt=s9:1", "&prompt=nonsense",
        "&prompt=s1:1&rebase=show", "&prompt=s1:2&rebase=show", "&prompt=s1:4&rebase=show", "&rebase=show",
        "&prompt=s1:1&moved=other", "&prompt=s1:2&moved=other", "&prompt=s1:2&moved=created-later", "&prompt=s1:1&moved=before-only", "&prompt=s1:2&moved=before-only", "&prompt=s1:2&moved=feat", "&prompt=s1:2&moved=nope",
        "&prompt=s1:2&moved=at-prompt", "&prompt=s1:4&moved=at-prompt", "&prompt=s1:2&moved=other&rebase=show", "&prompt=s1:2&moved=main", "&branch=feat", "&branch=refonly", "&branch=unlinked",
    ] {
        check(&format!("{q}{extra}"));
    }
    for slug in ["nosession", "nosnap", "gone-item", "pruned-item", "uncaptured-item", "live-older", "nosuch"] {
        check(&format!("/api/diff/{slug}?scope=prompt"));
    }
    assert!(compared > 30);
    // git 2.43 refuses a tree where `merge-tree --write-tree` wants a commit, so replaying the prompt's
    // tree onto the new base fails here, in Ruby too ("hidden": true and the conflict notice need a
    // git that accepts it); the failure path and the unhidden (`rebase=show`) one are what is compared.
    for expected in ["\"kind\":\"prompt\"", "\"kind\":\"prompt-branch\"", "\"rebase\":{\"onto\":", "\"hidden\":false", "\"rebaseNotice\":\"Couldn't hide the rebase: git merge-tree failed.\"", "\"movedBranches\":[{\"branch\":\"feat\",\"commits\":3},{\"branch\":\"main\"", "\"branch\":\"created-later\",\"commits\":0", "\"prompt\":null", "before “first prompt”", "before the prompt at 2026-04-01T10:20:00Z", "…\"", "\"notice\":\"This item has no captured chat session", "\"notice\":\"No prompt snapshots", "is gone — nothing to diff.", "snapshot is gone: git pruned it", "\"oldRev\":\"", "is not checked out anywhere"] {
        assert!(seen.contains(expected), "the payloads should contain {expected}");
    }
}

/// A repo whose origin is `<base>/acme/widgets.git` (so its GitHub name is acme/widgets and `git
/// fetch origin` works), with PR heads published as `refs/pull/<n>/head`.
fn pr_world(base: &Path) -> (PathBuf, PathBuf, PathBuf) {
    let (root, home, repo) = (base.join("root"), base.join("home"), base.join("repo"));
    let origin = base.join("acme/widgets.git");
    for d in [&home, &repo, &origin, &base.join("bin"), &base.join("ghdata")] {
        fs::create_dir_all(d).unwrap();
    }
    sh(&origin, &["init", "-q", "--bare"]);
    sh(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("a.txt"), lines("alpha", 30)).unwrap();
    fs::write(repo.join("b.txt"), lines("beta", 10)).unwrap();
    fs::write(repo.join("gone.txt"), lines("gone", 4)).unwrap();
    fs::write(repo.join("far.txt"), lines("far", 40)).unwrap();
    commit(&repo, "base");
    sh(&repo, &["remote", "add", "origin", origin.to_str().unwrap()]);
    sh(&repo, &["push", "-q", "origin", "main"]);
    let feat = base.join("wt-feat");
    sh(&repo, &["worktree", "add", "-q", "-b", "feat", feat.to_str().unwrap(), "main"]);
    fs::write(feat.join("a.txt"), lines("alpha", 30).replace("alpha 5\n", "alpha five\n").replace("alpha 25\n", "alpha twenty-five\n").replace("alpha 12\n", "alpha twelve\n").replace("alpha 20\n", "alpha twenty\n")).unwrap();
    commit(&feat, "feat one: two edits far apart");
    fs::write(feat.join("b.txt"), lines("beta", 10).replace("beta 3\n", "")).unwrap();
    fs::remove_file(feat.join("gone.txt")).unwrap();
    fs::write(feat.join("new.txt"), lines("new", 3)).unwrap();
    fs::write(feat.join("dup.txt"), "dup\ndup\ndup\n").unwrap();
    fs::write(feat.join("far.txt"), lines("far", 40).replace("far 2\n", "far two\n").replace("far 38\n", "far thirty-eight\n")).unwrap();
    commit(&feat, "feat two: removals and a new file");
    fs::write(feat.join("a.txt"), fs::read_to_string(feat.join("a.txt")).unwrap().replace("alpha 6\n", "alpha 6\nalpha 6b\n").replace("alpha five\n", "")).unwrap();
    commit(&feat, "feat three");
    sh(&repo, &["push", "-q", "origin", "feat:refs/pull/5/head"]);
    // a second PR onto another base, found through gh
    sh(&repo, &["checkout", "-q", "-b", "release", "main"]);
    fs::write(repo.join("rel.txt"), lines("release", 2)).unwrap();
    commit(&repo, "release one");
    sh(&repo, &["push", "-q", "origin", "release"]);
    sh(&repo, &["checkout", "-q", "-b", "feat2", "release"]);
    fs::write(repo.join("two.txt"), lines("two", 5)).unwrap();
    commit(&repo, "feat2 one");
    sh(&repo, &["push", "-q", "origin", "feat2:refs/pull/6/head"]);
    sh(&repo, &["checkout", "-q", "main"]);
    sh(&repo, &["branch", "nopr", "main"]);
    sh(&repo, &["branch", "gone-pr", "main"]);
    sh(&repo, &["branch", "wrong-repo", "main"]);
    sh(&repo, &["branch", "bad-base", "main"]);
    sh(&repo, &["branch", "gh-fails", "main"]);
    sh(&repo, &["branch", "closed-br", "main"]);
    sh(&repo, &["branch", "dots-base", "main"]);
    // gh answers from files; every call is logged to the server's own log
    let gh = "#!/bin/sh\necho \"$*\" >> \"$FAKE_GH_LOG\"\nsel=\"$3\"\nf=\"$FAKE_GH_DATA/$(echo \"$sel\" | tr '/:' '__').json\"\nif [ -f \"$f\" ]; then cat \"$f\"; exit 0; fi\nif [ -f \"$FAKE_GH_DATA/$sel.fail\" ]; then echo 'HTTP 502: bad gateway' >&2; exit 1; fi\necho \"no pull requests found for branch $sel\" >&2\nexit 1\n";
    fs::write(base.join("bin/gh"), gh).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(base.join("bin/gh"), fs::Permissions::from_mode(0o755)).unwrap();
    }
    let pr = |n: u32, head: &str, base_ref: &str| format!("{{\"number\":{n},\"url\":\"https://github.com/acme/widgets/pull/{n}\",\"title\":\"PR {n}\",\"headRefName\":\"{head}\",\"baseRefName\":\"{base_ref}\",\"state\":\"OPEN\"}}");
    fs::write(base.join("ghdata/feat2.json"), pr(6, "feat2", "release")).unwrap();
    fs::write(base.join("ghdata/https___github.com_acme_widgets_pull_6.json"), pr(6, "feat2", "release")).unwrap();
    fs::write(base.join("ghdata/gh-fails.fail"), "").unwrap();
    fs::create_dir_all(root.join("work-items")).unwrap();
    fs::write(root.join("config.yml"), format!("projects:\n  demo: {}\n", repo.display())).unwrap();
    let item = |slug: &str, title: &str, branches: &[&str], desc: &str| {
        let list: String = branches.iter().map(|b| format!("- {b}\n")).collect();
        let list = if list.is_empty() { String::new() } else { format!("branches:\n{list}") };
        fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: \"{title}\"\nstate: in_progress\nproject: demo\ncreated: '2026-01-01'\n{list}---\n\n## Description\n\n{desc}\n\n## Notes\n\n## Snapshots\n")).unwrap();
    };
    item("pr-item", "PR item", &["feat", "feat2", "nopr", "gone-pr", "wrong-repo", "bad-base", "gh-fails", "closed-br", "dots-base"], "d");
    item("review-cached", "Review acme/widgets#5: x", &[], "Review of pull request https://github.com/acme/widgets/pull/5");
    item("review-gh", "Review acme/widgets#6: y", &[], "Review of pull request https://github.com/acme/widgets/pull/6");
    item("review-branch", "Review acme/widgets#5: z", &["feat"], "Review of pull request https://github.com/acme/widgets/pull/5");
    item("review-unknown", "Review acme/widgets#77: w", &[], "Review of pull request https://github.com/acme/widgets/pull/77");
    item("draft-item", "Draft item", &["feat"], "d");
    item("review-other", "Review other/repo#3: v", &[], "Review of pull request https://github.com/other/repo/pull/3");
    let real_git = String::from_utf8_lossy(&Command::new("sh").args(["-c", "command -v git"]).output().unwrap().stdout).trim().to_string();
    fs::write(base.join("bin/git"), format!("#!/bin/sh\ncase \" $* \" in *\" fetch \"*) echo \"$*\" | sed 's#-C [^ ]* ##' >> \"$FAKE_GIT_LOG\" ;; esac\nexec {real_git} \"$@\"\n")).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(base.join("bin/git"), fs::Permissions::from_mode(0o755)).unwrap();
    }
    fs::write(base.join("ghdata/closed-br.json"), pr(8, "closed-br", "main").replace("OPEN", "MERGED")).unwrap();
    let prs = serde_json::json!([
        {"repo": "Acme/Widgets", "number": 5, "url": "https://github.com/acme/widgets/pull/5", "title": "PR 5", "head": "feat", "base": "main"},
        {"repo": "acme/widgets", "number": 99, "url": "https://github.com/acme/widgets/pull/99", "title": "PR 99", "head": "gone-pr", "base": "main"},
        {"repo": "other/repo", "number": 3, "url": "https://github.com/other/repo/pull/3", "title": "PR 3", "head": "wrong-repo", "base": "main"},
        {"repo": "acme/widgets", "number": 4, "url": "https://github.com/acme/widgets/pull/4", "title": "PR 4", "head": "bad-base", "base": "-evil"},
        {"repo": "acme/widgets", "number": 7, "url": "https://github.com/acme/widgets/pull/7", "title": "PR 7", "head": "dots-base", "base": "a..b"}
    ]);
    fs::write(root.join("pr-inbox.json"), serde_json::json!({"prs": prs, "ts": 1}).to_string()).unwrap();
    (root, home, base.to_path_buf())
}

#[test]
fn the_pr_scope_matches_ruby() {
    let base = tempfile::tempdir().unwrap();
    let (root, home, b) = pr_world(base.path());
    let env = |tag: &str| -> Vec<(&'static str, String)> {
        vec![("PATH", format!("{}:{}", b.join("bin").display(), std::env::var("PATH").unwrap())), ("FAKE_GH_DATA", b.join("ghdata").display().to_string()), ("FAKE_GH_LOG", b.join(format!("gh-{tag}.log")).display().to_string()), ("FAKE_GIT_LOG", b.join(format!("git-{tag}.log")).display().to_string())]
    };
    let ruby = start_env(false, &root, &home, &env("ruby"));
    let rust = start_env(true, &root, &home, &env("rust"));
    let mut seen = String::new();
    let mut compared = 0;
    let mut check = |path: &str| {
        let (a, c) = (request(ruby.port, "GET", path, &[], "", true), request(rust.port, "GET", path, &[], "", true));
        assert!(!c.status.starts_with("501"), "{path} should be served: {}", String::from_utf8_lossy(&c.body));
        let (sa, sc) = (shown(&a, ruby.port), shown(&c, rust.port));
        if sa != sc {
            let at = sa.bytes().zip(sc.bytes()).position(|(x, y)| x != y).unwrap_or(sa.len().min(sc.len()));
            let from = at.saturating_sub(200);
            let cut = |s: &str| s.get(from..(from + 500).min(s.len())).unwrap_or("").to_string();
            panic!("{path}: first difference at byte {at}\nRuby: …{}\nRust: …{}", cut(&sa), cut(&sc));
        }
        compared += 1;
        seen.push_str(&sa);
    };
    let repo = base.path().join("repo");
    let shas = sh(&repo, &["log", "--format=%H", "main..feat"]);
    let shas: Vec<&str> = shas.lines().collect(); // newest first
    let (c3, c2, c1) = (shas[0], shas[1], shas[2]);
    for query in [
        "?scope=pr&branch=feat".to_string(),
        "?scope=pr&branch=feat&fresh=1".to_string(),
        "?scope=pr&branch=feat".to_string(),
        format!("?scope=pr&branch=feat&from={c1}&to={c1}"),
        format!("?scope=pr&branch=feat&from={c2}&to={c2}"),
        format!("?scope=pr&branch=feat&from={c1}&to={c3}"),
        format!("?scope=pr&branch=feat&from={c3}&to={c1}"),
        "?scope=pr&branch=feat&from=zzzz".to_string(),
        "?scope=pr&branch=feat2".to_string(),
        "?scope=pr&branch=nopr".to_string(),
        "?scope=pr&branch=gone-pr".to_string(),
        "?scope=pr&branch=wrong-repo".to_string(),
        "?scope=pr&branch=bad-base".to_string(),
        "?scope=pr&branch=gh-fails".to_string(),
        "?scope=pr&branch=closed-br".to_string(),
        "?scope=pr&branch=dots-base".to_string(),
        "?scope=pr&branch=unlinked".to_string(),
        "?scope=pr".to_string(),
        "?scope=branch&branch=feat".to_string(),
    ] {
        check(&format!("/api/diff/pr-item{query}"));
    }
    for slug in ["review-cached", "review-gh", "review-branch", "review-unknown", "review-other"] {
        for query in ["", "?scope=pr", "?scope=branch", "?scope=commits", "?scope=uncommitted"] {
            check(&format!("/api/diff/{slug}{query}"));
        }
    }
    // the same questions asked of gh and of git, by each server, with the memo in between
    let calls = |tag: &str| fs::read_to_string(b.join(format!("gh-{tag}.log"))).unwrap_or_default();
    assert_eq!(calls("rust"), calls("ruby"), "gh must be asked the same things");
    assert!(!calls("ruby").is_empty());
    let fetches = |tag: &str| fs::read_to_string(b.join(format!("git-{tag}.log"))).unwrap_or_default();
    assert_eq!(fetches("rust"), fetches("ruby"), "git must be asked to fetch the same things");
    assert!(fetches("ruby").contains("fetch --quiet --no-tags origin +refs/pull/5/head:refs/quartermaster/pr/5 +refs/heads/main:refs/remotes/origin/main"));
    assert!(compared > 40);
    for expected in ["\"scope\":\"pr\"", "\"kind\":\"pr\"", "\"reviewRoutes\":{}", "\"anchor\":\"", "\"gh\":false", "\"messages\":[{", "has no open pull request", "is not in this project's repo", "has no usable base branch", "could not fetch", "gh pr view gh-fails failed: HTTP 502", "\"prAvailable\":true", "\"checkout\":false"] {
        assert!(seen.contains(expected), "the payloads should contain {expected}");
    }
}

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for e in fs::read_dir(from).unwrap().filter_map(|e| e.ok()) {
        let (src, dst) = (e.path(), to.join(e.file_name()));
        if src.is_dir() {
            copy_dir(&src, &dst)
        } else {
            fs::copy(&src, &dst).unwrap();
            let when = fs::metadata(&src).unwrap().modified().unwrap();
            fs::OpenOptions::new().write(true).open(&dst).unwrap().set_modified(when).unwrap();
        }
    }
}

#[test]
fn github_drafts_are_re_anchored_like_ruby() {
    let base = tempfile::tempdir().unwrap();
    let (root, home, b) = pr_world(base.path());
    let repo = base.path().join("repo");
    let shas = sh(&repo, &["log", "--format=%H", "main..feat"]);
    let shas: Vec<&str> = shas.lines().collect();
    let (c3, c2, c1) = (shas[0].to_string(), shas[1].to_string(), shas[2].to_string());
    let base_sha = sh(&repo, &["merge-base", "main", "feat"]);
    // a commit outside the PR with the patch of its first commit (a rebase that kept the changes)
    sh(&repo, &["checkout", "-q", "-b", "side", "main"]);
    sh(&repo, &["cherry-pick", "-x", &c1]);
    let twin = sh(&repo, &["rev-parse", "HEAD"]);
    sh(&repo, &["checkout", "-q", "main"]);
    let entry = |id: &str, extra: serde_json::Value| {
        let mut e = serde_json::json!({"id": id, "kind": "github-comment", "comment": format!("comment {id}"), "rev": 1, "path": "a.txt", "side": "new", "line": 12, "code": "alpha twelve", "repo": "acme/widgets", "number": 5, "commit": c3, "base": base_sha, "subject": "line", "author": "user", "createdAt": "2026-04-01T00:00:00Z", "updatedAt": "2026-04-01T00:00:00Z"});
        for (k, v) in extra.as_object().unwrap() {
            if v.is_null() { e.as_object_mut().unwrap().remove(k); } else { e[k] = v.clone(); }
        }
        e
    };
    let entries = serde_json::json!([
        entry("head-same", serde_json::json!({})),
        entry("moved-by-push", serde_json::json!({"line": 99, "code": "alpha twenty", "commit": c1})),
        entry("moved-range", serde_json::json!({"line": 99, "start_line": 98, "code": "alpha 11\nalpha twelve", "commit": c1})),
        entry("moved-range-sides", serde_json::json!({"line": 99, "start_line": 98, "start_side": "old", "code": "alpha 11\nalpha twelve", "commit": c1})),
        entry("moved-range-bad-start", serde_json::json!({"line": 99, "start_line": 98, "code": "wrong first\nalpha twelve", "commit": c1})),
        entry("ambiguous", serde_json::json!({"path": "dup.txt", "line": 99, "code": "dup", "commit": c1})),
        entry("head-old-commit", serde_json::json!({"commit": c1, "base": "fffffff"})),
        entry("outdated-range-context", serde_json::json!({"start_line": 10, "code": "alpha 10\nalpha 11\nalpha 12 as it was", "commit": c1})),
        entry("moved-failed", serde_json::json!({"line": 98, "code": "alpha twelve", "commit": c1, "failed": "GitHub said no"})),
        entry("on-commit", serde_json::json!({"line": 5, "code": "alpha five", "commit": c1, "range": "aaa..bbb"})),
        entry("on-twin", serde_json::json!({"line": 5, "code": "alpha five", "commit": twin, "range": "aaa..bbb"})),
        entry("on-unknown", serde_json::json!({"commit": "1234567890abcdef1234567890abcdef12345678", "range": "aaa..bbb"})),
        entry("pinned", serde_json::json!({"line": 12, "commit": c1, "pin": "commit"})),
        entry("pinned-gone", serde_json::json!({"line": 77, "commit": c1, "pin": "commit"})),
        entry("file-in-pr", serde_json::json!({"subject": "file", "line": 1})),
        entry("file-deleted", serde_json::json!({"subject": "file", "path": "gone.txt"})),
        entry("file-not-in-pr", serde_json::json!({"subject": "file", "path": "nowhere.txt"})),
        entry("outdated-text", serde_json::json!({"line": 99, "code": "text that is nowhere", "commit": c2})),
        entry("outdated-context", serde_json::json!({"line": 12, "code": "alpha 12 as it was", "commit": c1})),
        entry("outdated-old-commit", serde_json::json!({"line": 5, "code": "alpha five", "commit": c1})),
        entry("outdated-file-gone", serde_json::json!({"path": "nowhere.txt", "line": 3, "code": "x", "commit": c1})),
        entry("range-same-hunk", serde_json::json!({"start_line": 10, "code": "alpha 10\nalpha 11\nalpha twelve"})),
        entry("range-two-hunks", serde_json::json!({"path": "far.txt", "line": 38, "start_line": 2, "code": "far two\nfar thirty-eight"})),
        entry("old-side", serde_json::json!({"path": "b.txt", "side": "old", "line": 3, "code": "beta 3"})),
        entry("old-side-moved", serde_json::json!({"path": "b.txt", "side": "old", "line": 8, "code": "beta 3", "commit": c1})),
        entry("string-line", serde_json::json!({"line": "12"})),
        entry("other-pr", serde_json::json!({"number": 6})),
        entry("other-repo", serde_json::json!({"repo": "other/repo"})),
        {"id": "a-chat-draft", "kind": "diff-comment", "comment": "x", "rev": 1, "path": "a.txt", "side": "new", "line": 1}
    ]);
    let write = |dir: &Path, slug: &str, entries: &serde_json::Value| {
        fs::create_dir_all(dir.join("drafts")).unwrap();
        fs::write(dir.join(format!("drafts/{slug}.json")), serde_json::to_string_pretty(&serde_json::json!({"v": 1, "entries": entries})).unwrap()).unwrap();
    };
    let bad = serde_json::json!([entry("bad-side", serde_json::json!({"side": "sideways", "line": 99, "commit": c1}))]);
    let root2 = base.path().join("root2");
    for r in [&root] {
        write(r, "draft-item", &entries);
        write(r, "draft-bad", &bad);
        let item = fs::read_to_string(r.join("work-items/draft-item.md")).unwrap().replace("title: \"Draft item\"", "title: \"Draft bad\"");
        fs::write(r.join("work-items/draft-bad.md"), item).unwrap();
    }
    copy_dir(&root, &root2);
    let env = |tag: &str| -> Vec<(&'static str, String)> {
        vec![("PATH", format!("{}:{}", b.join("bin").display(), std::env::var("PATH").unwrap())), ("FAKE_GH_DATA", b.join("ghdata").display().to_string()), ("FAKE_GH_LOG", b.join(format!("gh-{tag}.log")).display().to_string()), ("FAKE_GIT_LOG", b.join(format!("git-{tag}.log")).display().to_string())]
    };
    let ruby = start_env(false, &root, &home, &env("ruby"));
    let rust = start_env(true, &root2, &home, &env("rust"));
    let mut seen = String::new();
    for path in ["/api/diff/draft-item?scope=pr&branch=feat", "/api/diff/draft-item?scope=pr&branch=feat", "/api/diff/draft-item?scope=pr&branch=feat&fresh=1", &format!("/api/diff/draft-item?scope=pr&branch=feat&from={c1}&to={c2}"), "/api/diff/draft-bad?scope=pr&branch=feat"] {
        let (a, c) = (request(ruby.port, "GET", path, &[], "", true), request(rust.port, "GET", path, &[], "", true));
        assert!(!c.status.starts_with("501"), "{path} should be served: {}", String::from_utf8_lossy(&c.body));
        let (sa, sc) = (shown(&a, ruby.port), shown(&c, rust.port));
        if sa != sc {
            let at = sa.bytes().zip(sc.bytes()).position(|(x, y)| x != y).unwrap_or(sa.len().min(sc.len()));
            let from = at.saturating_sub(300);
            let cut = |s: &str| s.get(from..(from + 700).min(s.len())).unwrap_or("").to_string();
            panic!("{path}: first difference at byte {at}\nRuby: …{}\nRust: …{}", cut(&sa), cut(&sc));
        }
        seen.push_str(&sa);
    }
    // the drafts each server left behind
    let left = |r: &Path| {
        let text = fs::read_to_string(r.join("drafts/draft-item.json")).unwrap();
        regex::Regex::new(r#""updatedAt": "[^"]+""#).unwrap().replace_all(&text, "\"updatedAt\": \"T\"").into_owned()
    };
    assert_eq!(left(&root2), left(&root), "the re-anchored drafts differ");
    assert_ne!(left(&root), regex::Regex::new(r#""updatedAt": "[^"]+""#).unwrap().replace_all(&serde_json::to_string_pretty(&serde_json::json!({"v": 1, "entries": entries})).unwrap(), "\"updatedAt\": \"T\"").into_owned(), "drafts should have moved");
    for expected in ["\"route\":\"head\"", "\"route\":\"commit\"", "\"route\":\"outdated\"", "\"moved\":true", "\"fileGone\":true", "\"oldCommit\":\"", "\"position\":", "no longer in the pull request", "its commit's line can't take a comment any more", "since the push its line isn't in the PR's diff once, unchanged", "\"at\":true", "side must be LEFT or RIGHT, not \\\"SIDEWAYS\\\""] {
        assert!(seen.contains(expected), "the payloads should contain {expected}");
    }
}

/// What a state build is compared on: everything but the terminal token.
fn compare_state(ruby: &Server, rust: &Server, label: &str) -> String {
    let (a, b) = (request(ruby.port, "GET", "/api/state", &[], "", true), request(rust.port, "GET", "/api/state", &[], "", true));
    assert!(!b.status.starts_with("501"), "{label}: the state should be served: {}", String::from_utf8_lossy(&b.body));
    let (sa, sb) = (shown(&a, ruby.port), shown(&b, rust.port));
    let (sa, sb) = (regex::Regex::new(r#""terminalToken":"[0-9a-f]{48}""#).unwrap().replace_all(&sa, "\"terminalToken\":\"T\"").into_owned(), regex::Regex::new(r#""terminalToken":"[0-9a-f]{48}""#).unwrap().replace_all(&sb, "\"terminalToken\":\"T\"").into_owned());
    let sb = sb.replace("/root2", "/root");
    if sa != sb {
        let at = sa.bytes().zip(sb.bytes()).position(|(x, y)| x != y).unwrap_or(sa.len().min(sb.len()));
        let from = at.saturating_sub(300);
        let cut = |s: &str| s.get(from..(from + 700).min(s.len())).unwrap_or("").to_string();
        panic!("{label}: first difference at byte {at}\nRuby: …{}\nRust: …{}", cut(&sa), cut(&sb));
    }
    sa
}

#[test]
fn the_state_matches_ruby() {
    let base = tempfile::tempdir().unwrap();
    let w = attention_world(base.path(), std::time::SystemTime::now(), None);
    let env: Vec<(&str, String)> = vec![
        ("HOME", w.home.display().to_string()),
        ("QM_TRANSCRIPTS_DIR", w.transcripts.display().to_string()),
        ("PATH", format!("{}:{}", w.bin.display(), std::env::var("PATH").unwrap())),
        ("FAKE_GH_DATA", w.gh_data.display().to_string()),
        ("FAKE_GH_LOG", base.path().join("gh.log").display().to_string()),
    ];
    // each server gets its own copy of the data root: a build rewrites caches and links branches
    let root2 = base.path().join("root2");
    copy_dir(&w.root, &root2);
    let mut env_rust = env.clone();
    env_rust[4].1 = base.path().join("gh-rust.log").display().to_string();
    let ruby = start_env(false, &w.root, &w.home, &env);
    let rust = start_env(true, &root2, &w.home, &env_rust);
    // the first build starts the background PR lookups (a race of its own); compare once they landed
    for s in [&ruby, &rust] {
        request(s.port, "GET", "/api/state", &[], "", true);
    }
    std::thread::sleep(std::time::Duration::from_millis(800));
    let first = compare_state(&ruby, &rust, "first build");
    assert!(first.contains("\"items\":[{"));
    compare_state(&ruby, &rust, "second build");
}

/// Everything the attention world leaves out: usage transcripts, events, notes of every kind,
/// rotations, an aside, inbox sessions, drafts, issues, rate limits and a linked worktree.
fn richer_state_world(w: &common::AttentionWorld, base: &Path) {
    let now = std::time::SystemTime::now();
    let stamp = |secs: u64| -> String {
        let t: chrono::DateTime<chrono::Utc> = (now - std::time::Duration::from_secs(secs)).into();
        t.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
    };
    let me = std::process::id();
    let put = |path: PathBuf, text: String| {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    };
    let user = |secs: u64, text: &str| format!("{}\n", serde_json::json!({"type": "user", "timestamp": stamp(secs), "message": {"role": "user", "content": text}}));
    let assistant = |secs: u64, model: &str, input: u64, out: u64, read: u64| {
        format!("{}\n", serde_json::json!({"type": "assistant", "timestamp": stamp(secs), "message": {"model": model, "usage": {"input_tokens": input, "output_tokens": out, "cache_read_input_tokens": read, "cache_creation_input_tokens": 50}}}))
    };
    let tpath = |id: &str| w.transcripts.join(format!("p/{id}.jsonl"));
    // usage: a priced model, an unpriced one, and a very large session
    put(tpath("d-fresh"), user(300, "first prompt of the fresh session") + &assistant(280, "claude-opus-5-5", 1000, 2000, 30_000) + &assistant(200, "claude-opus-5-5", 1500, 900, 40_000));
    put(tpath("d-live"), user(250, "live prompt") + &assistant(240, "mystery-model-9", 10, 20, 30) + &assistant(100, "claude-sonnet-5-5", 700_000, 400_000, 0));
    put(tpath("q-recent"), user(86_000, "quiet one") + &assistant(85_000, "claude-haiku-5-5", 5, 6, 7));
    // asides and inbox sessions, an extra live session for events
    let mut log = fs::read_to_string(w.root.join("sessions.jsonl")).unwrap();
    let start = |id: &str, extra: &str, pid: u32, secs: u64| format!("{{\"v\":1,\"event\":\"start\",\"session_id\":\"{id}\",\"cwd\":\"/srv/app\",\"pid\":{pid},\"transcript_path\":\"{}\"{extra},\"ts\":\"{}\"}}\n", tpath(id).display(), stamp(secs).replace(".000", ""));
    log += &start("a-one", ",\"aside\":\"degrade\"", 999999, 5000);
    log += &start("a-two", ",\"aside\":\"degrade\"", 999999, 4000);
    log += &start("a-stale", ",\"aside\":\"stale\"", 999999, 4000);
    log += &start("i-one", "", 999999, 900);
    log += &start("i-two", "", 999999, 7200);
    log += &start("i-none", "", 999999, 90_000);
    log += &start("w-live", "", me, 600);
    // sessions whose last activity sits in each relative-time bucket
    for (id, age) in [("r-sec", 20u64), ("r-min", 600), ("r-hour", 18_000), ("r-edge", 86_200), ("r-day", 3 * 86_400), ("r-ten", 10 * 86_400 + 43_200), ("r-eleven", 11 * 86_400 + 43_200), ("r-old", 12 * 86_400)] {
        log += &start(id, "", 999999, age + 5);
        put(tpath(id), user(age, "relative"));
        let t = now - std::time::Duration::from_secs(age);
        fs::File::options().write(true).open(tpath(id)).unwrap().set_modified(t).unwrap();
    }
    log += &start("s-snz", "", me, 800);
    put(tpath("s-snz"), user(790, "snoozed turn") + &assistant(700, "claude-opus-5-5", 5, 5, 5));
    put(w.root.join("sessions.jsonl"), log);
    put(tpath("a-one"), user(4900, "aside question") + &assistant(4800, "claude-opus-5-5", 3, 4, 5));
    put(tpath("a-two"), user(3900, "second aside") + &assistant(3800, "claude-opus-5-5", 3, 4, 5));
    put(tpath("a-stale"), user(3900, "stale aside"));
    put(tpath("i-one"), user(800, "inbox prompt one\nwith a second line"));
    put(tpath("i-two"), user(7100, "x".repeat(300).as_str()));
    put(tpath("w-live"), user(500, "working prompt") + &assistant(450, "claude-opus-5-5", 12345, 6789, 4321));
    // events: a working chat and a blocked one
    let ev = |secs: u64, name: &str, id: &str, tool: &str| format!("{{\"v\":1,\"ts\":\"{}\",\"event\":\"{name}\",\"session_id\":\"{id}\",\"tool\":\"{tool}\"}}\n", stamp(secs).replace(".000", ""));
    let snoozed_at = stamp(100).replace(".000", "").replace('Z', "+00:00");
    put(w.root.join("work-items/snoozed-chat.md"), format!("---\nv: 1\ntitle: Snoozed chat\nstate: in_progress\nproject: demo\ncreated: '2026-02-03'\nsnooze_until: '2099-01-01'\nturn_snoozed_at: '{}'\nsessions:\n- id: s-snz\n---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n", snoozed_at));
    put(w.root.join("events.jsonl"), ev(600, "Stop", "s-snz", "") + &ev(400, "UserPromptSubmit", "w-live", "Edit") + &ev(120, "PermissionRequest", "d-live", "Bash") + &ev(60, "UserPromptSubmit", "d-fresh", "Read"));
    // an item with every note kind, rotations, snapshots and a session of each sort
    let item = format!(
        "---\nv: 1\ntitle: Rich item\nstate: in_progress\nproject: demo\ncreated: '2026-02-03'\nrotations:\n- at: '2026-01-01T00:00:00+00:00'\n  from: s0\n  carried: [1, 2]\n- at: '2026-01-05T00:00:00+00:00'\n  from: s1\nsessions:\n- id: w-live\n- id: i-none\n- id: r-sec\n- id: r-min\n- id: r-hour\n- id: r-edge\n- id: r-day\n- id: r-ten\n- id: r-eleven\n- id: r-old\n---\n\n## Description\n\nrich\n\n## Notes\n\n- 2026-01-02 [history]: opened\n- 2026-01-03: a decision\n- 2026-01-04 [open]: what about this?\n- 2026-01-05 [open]: and that?\n- 2026-01-06 [bogus]: odd marker\n\n## Snapshots\n\n### 2026-01-02 — session s0\n\ntext\n"
    );
    put(w.root.join("work-items/rich-item.md"), item);
    // a linked worktree with a checked-out branch
    git(&w.repo, &["branch", "wt-branch"]);
    let wt = base.join("wt-checkout");
    git(&w.repo, &["worktree", "add", wt.to_str().unwrap(), "wt-branch"]);
    let wt_item = "---\nv: 1\ntitle: In a worktree\nstate: in_progress\nproject: demo\ncreated: '2026-02-03'\nbranches:\n- wt-branch\n- main\n---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n";
    put(w.root.join("work-items/in-worktree.md"), wt_item.to_string());
    // drafts and issues
    let entries = serde_json::json!([
        {"id": "d1", "kind": "diff-comment", "comment": "first", "rev": 1, "path": "a.txt", "side": "new", "line": 3},
        {"id": "d2", "kind": "page-annotation", "comment": "second", "rev": 2}
    ]);
    put(w.root.join("drafts/rich-item.json"), serde_json::to_string_pretty(&serde_json::json!({"v": 1, "entries": entries})).unwrap());
    put(w.root.join("drafts/degrade.json"), "{\"v\":1,\"entries\":[]}".to_string());
    put(w.root.join("issues/rich-item/01-bug.md"), "---\nv: 1\ntitle: A bug\nkind: bug\n---\n\nbody\n".to_string());
    put(w.root.join("issues/rich-item/02-feature.md"), "---\nv: 1\ntitle: A feature\nkind: feature\n---\n\nbody two\n".to_string());
    put(w.root.join("issues/stale/.hidden.md"), "---\nv: 1\ntitle: Hidden\nkind: bug\n---\n".to_string());
    // the status line's snapshot
    put(w.root.join("rate-limits.json"), format!("{{\"captured_at\":{},\"five_hour\":{{\"used_percentage\":41.5,\"resets_at\":{}}},\"seven_day\":{{\"used_percentage\":12,\"resets_at\":\"2026-12-01T00:00:00Z\"}}}}", now.duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() - 30, now.duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 3600));
}

#[test]
fn the_state_matches_ruby_over_a_richer_world() {
    let base = tempfile::tempdir().unwrap();
    let w = attention_world(base.path(), std::time::SystemTime::now(), None);
    richer_state_world(&w, base.path());
    let env: Vec<(&str, String)> = vec![
        ("HOME", w.home.display().to_string()),
        ("QM_TRANSCRIPTS_DIR", w.transcripts.display().to_string()),
        ("PATH", format!("{}:{}", w.bin.display(), std::env::var("PATH").unwrap())),
        ("FAKE_GH_DATA", w.gh_data.display().to_string()),
        ("FAKE_GH_LOG", base.path().join("gh.log").display().to_string()),
    ];
    let root2 = base.path().join("root2");
    copy_dir(&w.root, &root2);
    let mut env_rust = env.clone();
    env_rust[4].1 = base.path().join("gh-rust.log").display().to_string();
    let ruby = start_env(false, &w.root, &w.home, &env);
    let rust = start_env(true, &root2, &w.home, &env_rust);
    for s in [&ruby, &rust] {
        request(s.port, "GET", "/api/state", &[], "", true);
    }
    std::thread::sleep(std::time::Duration::from_millis(800));
    let first = compare_state(&ruby, &rust, "first build");
    for needle in ["\"rich-item\"", "\"asideCount\":2", "\"rateLimits\":{", "\"wt-branch\"", "\"claude-haiku-5-5\":68", "inbox prompt one", "\"state\":\"working\"", "\"lowerBound\":true", "\"snoozed\":true", "23h ago", "10d ago", "3d ago", "just now", "10m ago", "5h ago"] {
        assert!(first.contains(needle), "the world should reach {needle}");
    }
    compare_state(&ruby, &rust, "second build");
}

/// What the data actions leave behind: the item files and the error log, without its stamps.
fn action_traces(root: &Path, other: &Path) -> String {
    let mut out = String::new();
    let mut names: Vec<_> = fs::read_dir(root.join("work-items")).unwrap().map(|e| e.unwrap().path()).collect();
    names.sort();
    for p in names {
        out += &format!("== {}\n{}\n", p.file_name().unwrap().to_string_lossy(), fs::read_to_string(&p).unwrap());
    }
    let log = fs::read_to_string(root.join("qm.log")).unwrap_or_default();
    let log = regex::Regex::new(r"(?m)^\S+ \[").unwrap().replace_all(&log, "[").into_owned();
    out += &format!("== qm.log\n{}", log.replace(&other.display().to_string(), &root.display().to_string()));
    out
}

#[test]
fn the_data_actions_match_ruby() {
    let base = tempfile::tempdir().unwrap();
    let w = attention_world(base.path(), std::time::SystemTime::now(), None);
    let env: Vec<(&str, String)> = vec![("HOME", w.home.display().to_string()), ("QM_TRANSCRIPTS_DIR", w.transcripts.display().to_string())];
    let root2 = base.path().join("root2");
    copy_dir(&w.root, &root2);
    let ruby = start_env(false, &w.root, &w.home, &env);
    let rust = start_env(true, &root2, &w.home, &env);
    let origin = [("Origin", "http://127.0.0.1:PORT".to_string()), ("Content-Type", "application/json".to_string())];
    let mut step = |label: &str, body: &str| {
        let (a, b) = (request(ruby.port, "POST", "/api/action", &origin, body, true), request(rust.port, "POST", "/api/action", &origin, body, true));
        assert_eq!(shown(&a, ruby.port), shown(&b, rust.port), "{label}: reply to {body}");
        assert_eq!(action_traces(&w.root, &root2), action_traces(&root2, &w.root), "{label}: files after {body}");
        shown(&a, ruby.port)
    };
    let act = |cmd: &str, slug: &str, args: &str| format!("{{\"cmd\":\"{cmd}\",\"slug\":\"{slug}\",\"args\":{args}}}");
    let cases: Vec<(&str, String)> = vec![
        ("note", act("note", "stale", r#"{"text":"first note"}"#)),
        ("note kind", act("note", "stale", r#"{"text":"an open question","kind":"open"}"#)),
        ("note empty kind", act("note", "stale", r#"{"text":"  padded  ","kind":""}"#)),
        ("note history", act("note", "stale", r#"{"text":"it happened","kind":"history"}"#)),
        ("note stamped", act("note", "stale", r#"{"text":"2026-01-01 stamped text"}"#)),
        ("note numeric", act("note", "stale", r#"{"text":5}"#)),
        ("note multi-line", act("note", "stale", r#"{"text":"line one\nline two: colon"}"#)),
        ("note bad kind", act("note", "stale", r#"{"text":"x","kind":"bogus"}"#)),
        ("note blank", act("note", "stale", r#"{"text":"   "}"#)),
        ("note blank missing item", act("note", "nowhere", r#"{"text":" "}"#)),
        ("retitle blank missing item", act("retitle", "nowhere", r#"{"title":" "}"#)),
        ("note no args", r#"{"cmd":"note","slug":"stale"}"#.into()),
        ("note missing item", act("note", "nowhere", r#"{"text":"x"}"#)),
        ("note null slug", r#"{"cmd":"note","slug":null,"args":{"text":"x"}}"#.into()),
        ("note traversal", act("note", "../x", r#"{"text":"x"}"#)),
        ("retag", act("retag", "stale", r#"{"position":2,"kind":"decision"}"#)),
        ("retag string", act("retag", "stale", r#"{"position":"3","kind":"history"}"#)),
        ("retag past the end", act("retag", "stale", r#"{"position":99,"kind":"open"}"#)),
        ("retag null position", act("retag", "stale", r#"{"position":null,"kind":"open"}"#)),
        ("retag zero", act("retag", "stale", r#"{"position":0,"kind":"open"}"#)),
        ("retag bad kind", act("retag", "stale", r#"{"position":1,"kind":"nope"}"#)),
        ("retag missing item", act("retag", "nowhere", r#"{"position":1,"kind":"open"}"#)),
        ("describe", act("describe", "stale", r#"{"text":"  A new description.\n\nTwo paragraphs.  "}"#)),
        ("describe empty", act("describe", "stale", r#"{"text":""}"#)),
        ("describe numeric", act("describe", "stale", r#"{"text":42}"#)),
        ("describe missing", act("describe", "nowhere", r#"{"text":"x"}"#)),
        ("retitle", act("retitle", "stale", r#"{"title":"  A better title  "}"#)),
        ("retitle colon", act("retitle", "stale", r#"{"title":"Fix: the thing # not a comment"}"#)),
        ("retitle empty", act("retitle", "stale", r#"{"title":"  "}"#)),
        ("retitle missing", act("retitle", "nowhere", r#"{"title":"x"}"#)),
        ("move", act("move", "stale", r#"{"project":"elsewhere"}"#)),
        ("move quoted", act("move", "stale", r#"{"project":"a: b"}"#)),
        ("move back", act("move", "stale", r#"{"project":"demo"}"#)),
        ("move missing", act("move", "nowhere", r#"{"project":"demo"}"#)),
        ("state fridge", act("state", "stale", r#"{"state":"fridge"}"#)),
        ("state back", act("state", "stale", r#"{"state":"in_progress"}"#)),
        ("state bogus", act("state", "stale", r#"{"state":"bogus"}"#)),
        ("state number", act("state", "stale", r#"{"state":5}"#)),
        ("state missing", act("state", "nowhere", r#"{"state":"fridge"}"#)),
        ("snooze days", act("snooze", "stale", r#"{"duration":"3d"}"#)),
        ("snooze zero", act("snooze", "stale", r#"{"duration":"0d"}"#)),
        ("snooze turn", act("snooze", "stale", r#"{"duration":"turn"}"#)),
        ("snooze clear", act("snooze", "stale", r#"{"duration":"clear"}"#)),
        ("snooze bogus", act("snooze", "stale", r#"{"duration":"soon"}"#)),
        ("snooze number", act("snooze", "stale", r#"{"duration":5}"#)),
        ("snooze null", act("snooze", "stale", r#"{"duration":null}"#)),
        ("snooze missing", act("snooze", "nowhere", r#"{"duration":"1d"}"#)),
        ("ack", act("ack", "degrade", "{}")),
        ("ack again", act("ack", "degrade", "{}")),
        ("ack none", act("ack", "stale", "{}")),
        ("ack missing", act("ack", "nowhere", "{}")),
        ("detach", act("detach", "degrade", r#"{"session":"d-soon"}"#)),
        ("detach again", act("detach", "degrade", r#"{"session":"d-soon"}"#)),
        ("detach null", act("detach", "degrade", r#"{"session":null}"#)),
        ("detach unattached", act("detach", "degrade", r#"{"session":"zzz"}"#)),
        ("detach missing", act("detach", "nowhere", r#"{"session":"d-soon"}"#)),
        ("unknown", act("frobnicate", "stale", "{}")),
        ("unknown empty", act("", "stale", "{}")),
        ("no cmd", r#"{"slug":"stale"}"#.into()),
        ("number cmd", r#"{"cmd":5}"#.into()),
        ("null cmd", r#"{"cmd":null}"#.into()),
        ("string payload", r#""note""#.into()),
        ("array payload", "[1]".into()),
        ("empty array payload", "[]".into()),
        ("number payload", "7".into()),
        ("junk payload", "not json".into()),
        ("empty payload", "".into()),
    ];
    for (label, body) in &cases {
        step(label, body);
    }
    // what is not ported answers 501 before anything happens, with the files untouched
    let before = action_traces(&root2, &w.root);
    for body in [act("state", "stale", r#"{"state":"resolved"}"#), act("start", "stale", "{}"), act("draft-put", "stale", "{}")] {
        let a = request(rust.port, "POST", "/api/action", &origin, &body, true);
        assert!(a.status.starts_with("501"), "{body}: {}", a.status);
    }
    assert_eq!(before, action_traces(&root2, &w.root));
}
