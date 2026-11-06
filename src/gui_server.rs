//! The loopback web UI, ported route by route. `qm gui` stays Ruby until this serves every route the
//! page uses; meanwhile `QM_RUST_GUI=1 qm gui` runs this server, which answers what is ported — the
//! page, its assets, `/api/pulse`, `/api/diff-file` — and says `501` for the rest, so it can be put
//! next to Ruby's GUI on the same data root and compared route by route. The server binds only
//! 127.0.0.1, never shuts itself down (no liveness timer), and refuses foreign `Host`s and `Origin`s
//! exactly as `LoopbackGuard` does. Not ported yet: the state build, actions, the terminal bridge,
//! turn notifications and caffeinate.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;

use serde_json::{json, Map, Value};

use crate::data_root;
use crate::delegate;
use crate::gui_action::{port, Failed};
use crate::outcome::{done, Outcome};
use crate::work_item::WorkItem;

const LOCAL_ACTIONS: [&str; 7] = ["caffeinate", "pane-start", "pane-resume", "rotate", "issue-start", "loose-start", "page-annotations"];
const POLLS: [&str; 2] = ["/api/state", "/api/pulse"];
const MAX_BYTES: usize = 1_000_000;
const MAX_LINES: usize = 20_000;

type Reply = (&'static str, &'static str, Vec<u8>);

fn gui_dir() -> PathBuf {
    delegate::checkout_launcher().parent().map(|p| p.join("lib/quartermaster/gui")).unwrap_or_default()
}

/// `URI.decode_www_form_component`.
fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = vec![];
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() + 0 && b.get(i + 1).zip(b.get(i + 2)).is_some_and(|(x, y)| x.is_ascii_hexdigit() && y.is_ascii_hexdigit()) => {
                out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
                i += 2;
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `URI.decode_www_form(query).to_h`: the last value of a repeated key wins.
fn params(query: Option<&str>) -> Map<String, Value> {
    let mut map = Map::new();
    for pair in query.unwrap_or("").split('&').filter(|p| !p.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        map.insert(decode(k), Value::String(decode(v)));
    }
    map
}

fn taxonomies() -> Value {
    json!({
        "states": [{"key": "in_progress", "label": "In progress"}, {"key": "fridge", "label": "Fridge"}, {"key": "resolved", "label": "Resolved"}],
        "noteKinds": [
            {"key": "open", "hint": "unresolved, always re-injected"},
            {"key": "decision", "hint": "a choice or finding"},
            {"key": "history", "hint": "mechanics, never re-injected"}
        ],
        "defaultNoteKind": "decision",
        "tierFallbacks": {
            "expired": "Transcript pruned by Claude Code — only capture metadata and snapshots remain.",
            "uncaptured": "Session was never captured (it predates qm's hooks)."
        }
    })
}

/// The page with the model's taxonomies and this start's terminal token injected.
fn page(token: &str) -> Option<Vec<u8>> {
    let text = std::fs::read_to_string(gui_dir().join("page.html")).ok()?;
    Some(text.replacen("/*__TAXONOMIES__*/ null", &taxonomies().to_string(), 1).replacen("/*__TERMINAL_TOKEN__*/ null", &Value::String(token.into()).to_string(), 1).into_bytes())
}

fn json_reply(v: Value) -> Reply {
    ("200 OK", "application/json; charset=utf-8", v.to_string().into_bytes())
}

fn text_reply(status: &'static str, body: &str) -> Reply {
    (status, "text/plain; charset=utf-8", body.as_bytes().to_vec())
}

/// `String#inspect`, for the messages that quote what the page sent.
pub fn inspect(s: &str) -> String {
    let mut out = String::from("\"");
    let cs: Vec<char> = s.chars().collect();
    for (i, c) in cs.iter().enumerate() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\x1b' => out.push_str("\\e"),
            '\x07' => out.push_str("\\a"),
            '\x08' => out.push_str("\\b"),
            '\x0b' => out.push_str("\\v"),
            '\x0c' => out.push_str("\\f"),
            '#' if matches!(cs.get(i + 1), Some('{' | '$' | '@')) => out.push_str("\\#"),
            c if (*c as u32) < 0x20 || *c as u32 == 0x7f => out.push_str(&format!("\\x{:02X}", *c as u32)),
            c => out.push(*c),
        }
    }
    out.push('"');
    out
}

/// `FileAtRevision#call`: one file at a revision, as lines; `Err` is the `ArgumentError` message.
fn file_at_revision(root: &str, rev: &str, path: &str) -> Result<(Vec<String>, bool), String> {
    if !(4..=64).contains(&rev.len()) || !rev.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(format!("{} is not a sha", inspect(rev)));
    }
    if path.is_empty() || path.contains('\0') {
        return Err("no path given".into());
    }
    let object = format!("{rev}:{path}");
    let mut child = std::process::Command::new("git")
        .args(["-C", root, "cat-file", "blob", &object])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let mut data = vec![];
    child.stdout.take().unwrap().take(MAX_BYTES as u64 + 1).read_to_end(&mut data).ok();
    let more = data.len() > MAX_BYTES;
    drop(child.stdout.take());
    let mut error = String::new();
    child.stderr.take().unwrap().read_to_string(&mut error).ok();
    let status = child.wait().map_err(|e| e.to_string())?;
    if !more && !status.success() {
        let why = crate::ruby_text::strip(&error);
        return Err(format!("{object} is not a file in git here{}", if why.is_empty() { String::new() } else { format!(": {why}") }));
    }
    let mut truncated = false;
    if more {
        data.truncate(MAX_BYTES);
        let cut = data.iter().rposition(|b| *b == b'\n').map(|i| i + 1).unwrap_or(0);
        data.truncate(cut);
        truncated = true;
    }
    let mut text = String::new();
    for chunk in data.utf8_chunks() {
        text.push_str(chunk.valid());
        if !chunk.invalid().is_empty() {
            text.push('?');
        }
    }
    let mut lines: Vec<String> = text.split_inclusive('\n').map(|l| l.strip_suffix("\r\n").or_else(|| l.strip_suffix('\n')).unwrap_or(l).to_string()).collect();
    truncated = truncated || lines.len() > MAX_LINES;
    lines.truncate(MAX_LINES);
    Ok((lines, truncated))
}

fn diff_file_payload(slug: &str, query: Option<&str>) -> Value {
    let p = params(query);
    let get = |k: &str| p.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let fail = |e: String| json!({"ok": false, "error": e});
    let item = match WorkItem::find(&decode(slug)) {
        Ok(i) => i,
        Err(e) => {
            if e.class != "ArgumentError" {
                data_root::log_error("gui-diff-file", e.class, &e.message);
            }
            return fail(e.message);
        }
    };
    let project = item.project();
    let root = crate::project_map::root_for(project.as_deref()).filter(|r| std::path::Path::new(r).is_dir());
    let Some(root) = root else { return fail(format!("no repo root configured for project '{}'", project.unwrap_or_default())) };
    match file_at_revision(&root, &get("rev"), &get("path")) {
        Ok((lines, truncated)) => json!({"ok": true, "lines": lines, "truncated": truncated}),
        Err(e) => fail(e),
    }
}

/// `Gui#diff_payload` for the scopes ported; `None` for the rest.
fn diff_payload(slug: &str, query: Option<&str>) -> Option<Value> {
    use crate::branch_diff::{call, Failure, Params};
    let p = params(query);
    let get = |k: &str| p.get(k).and_then(Value::as_str).map(String::from);
    let fail = |e: String| Some(json!({"ok": false, "error": e}));
    let mut item = match WorkItem::find(&decode(slug)) {
        Ok(i) => i,
        Err(e) => {
            if e.class != "ArgumentError" {
                data_root::log_error("gui-diff", e.class, &e.message);
            }
            return fail(e.message);
        }
    };
    if get("scope").as_deref() == Some("prompt") {
        use crate::branch_diff::require_checkout;
        let step = require_checkout(&item, get("branch").as_deref()).and_then(|_| crate::prompt_diff::call(&item, &crate::prompt_diff::Params { prompt: get("prompt"), moved: get("moved"), rebase: get("rebase").as_deref() != Some("show") }));
        return match step {
            Ok(mut result) => {
                if let Some(Value::Array(files)) = result.get_mut("files") {
                    crate::viewed_marks::apply(&item.slug, files);
                }
                let mut out = Map::new();
                out.insert("ok".into(), json!(true));
                out.extend(result);
                Some(Value::Object(out))
            }
            Err(Failure::Arg(m)) => fail(m),
            Err(Failure::Unported) => None,
        };
    }
    let params = Params { branch: get("branch"), scope: get("scope"), from: get("from"), to: get("to"), base: get("base") };
    match call(&mut item, &params) {
        Ok(mut result) => {
            if let Some(Value::Array(files)) = result.get_mut("files") {
                crate::viewed_marks::apply(&item.slug, files);
            }
            let mut out = Map::new();
            out.insert("ok".into(), json!(true));
            out.extend(result);
            Some(Value::Object(out))
        }
        Err(Failure::Arg(m)) => fail(m),
        Err(Failure::Unported) => None,
    }
}

fn pulse() -> String {
    let size = |p: PathBuf| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
    let events = size(data_root::root().join("events.jsonl"));
    let sessions = size(crate::session_log::SessionLog::path());
    // no caffeinate child and no notifier here: both are the Ruby GUI's
    format!("{events}:{sessions}:0:{}:{}:0", crate::drafts::signature(), crate::issue_drafts::signature())
}

struct Guard {
    hosts: [String; 2],
}

impl Guard {
    fn new(port: u16) -> Guard {
        Guard { hosts: [format!("127.0.0.1:{port}"), format!("localhost:{port}")] }
    }
    fn allowed_host(&self, host: Option<&String>) -> bool {
        host.is_some_and(|h| self.hosts.contains(h))
    }
    fn foreign_origin(&self, origin: Option<&String>) -> bool {
        origin.is_some_and(|o| !self.hosts.iter().any(|h| h == o.strip_prefix("http://").unwrap_or(o)))
    }
    fn local_action(&self, route: &str, body: &[u8]) -> bool {
        route == "/api/action" && matches!(serde_json::from_slice::<Value>(body), Ok(Value::Object(o)) if o.get("cmd").and_then(Value::as_str).is_some_and(|c| LOCAL_ACTIONS.contains(&c)))
    }
}

/// `FeatureUse#request`: a use of an API route, by kind and name only.
fn record_use(method: &str, route: &str, body: &[u8]) {
    if !route.starts_with("/api/") {
        return;
    }
    if method == "POST" {
        let name = if route == "/api/action" {
            match serde_json::from_slice::<Value>(body) {
                Ok(Value::Object(o)) => match o.get("cmd") {
                    None | Some(Value::Null) => String::new(),
                    Some(Value::String(s)) => s.clone(),
                    Some(other) => other.to_string(),
                },
                _ => String::new(),
            }
        } else {
            route.to_string()
        };
        crate::feature_use::record("action", &name);
    } else if method == "GET" && !POLLS.contains(&route) {
        let word: String = route.chars().take_while(|c| *c != '\0').collect();
        let end = word[5..].find('/').map(|i| i + 5).unwrap_or(word.len());
        crate::feature_use::record("get", &word[..end]);
    }
}

fn respond(guard: &Guard, token: &str, method: &str, path: &str, headers: &Map<String, Value>, body: &[u8]) -> Reply {
    let header = |k: &str| headers.get(k).and_then(Value::as_str).map(String::from);
    if !guard.allowed_host(header("host").as_ref()) {
        return text_reply("403 Forbidden", "bad host");
    }
    if method == "POST" && guard.foreign_origin(header("origin").as_ref()) {
        return text_reply("403 Forbidden", "bad origin");
    }
    let (route, query) = match path.split_once('?') {
        Some((r, q)) => (r, Some(q)),
        None => (path, None),
    };
    if method == "POST" && header("origin").is_none() && !guard.local_action(route, body) {
        return text_reply("403 Forbidden", "no origin");
    }
    record_use(method, route, body);
    if method == "GET" && route == "/" {
        return match page(token) {
            Some(p) => ("200 OK", "text/html; charset=utf-8", p),
            None => text_reply("404 Not Found", "not found"),
        };
    }
    if method == "GET" {
        if let Some(asset) = route.strip_prefix("/assets/") {
            let ok = regex::Regex::new(r"\A(css/[a-z0-9-]+\.css|js/[a-z0-9-]+\.js)\z").unwrap().is_match(asset);
            let file = gui_dir().join(asset);
            if ok && file.is_file() {
                let kind = if asset.ends_with(".css") { "text/css; charset=utf-8" } else { "text/javascript; charset=utf-8" };
                return ("200 OK", kind, std::fs::read(file).unwrap_or_default());
            }
            return text_reply("404 Not Found", "not found");
        }
        if route == "/api/pulse" {
            return json_reply(json!({"pulse": pulse(), "events": events_pulse(), "issues": crate::issue_drafts::signature()}));
        }
        if let Some(slug) = route.strip_prefix("/api/diff/") {
            return match diff_payload(slug, query) {
                Some(v) => json_reply(v),
                None => text_reply("501 Not Implemented", "not ported yet: this diff scope (pr, prompt) or a Review item"),
            };
        }
        if let Some(slug) = route.strip_prefix("/api/diff-file/") {
            return json_reply(diff_file_payload(slug, query));
        }
    }
    text_reply("501 Not Implemented", &format!("not ported yet: {method} {route}"))
}

fn events_pulse() -> String {
    let size = std::fs::metadata(data_root::root().join("events.jsonl")).map(|m| m.len()).unwrap_or(0);
    format!("{size}:{}:{}:0", crate::drafts::signature(), crate::issue_drafts::signature())
}

fn handle(mut stream: TcpStream, guard: &Guard, token: &str) {
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(60)));
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    if reader.read_line(&mut line).unwrap_or(0) == 0 {
        return;
    }
    let mut parts = line.split_whitespace();
    let (method, path) = (parts.next().unwrap_or("").to_string(), parts.next().unwrap_or("").to_string());
    let mut headers = Map::new();
    loop {
        let mut l = String::new();
        if reader.read_line(&mut l).unwrap_or(0) == 0 || l == "\r\n" || l == "\n" {
            break;
        }
        if let Some((k, v)) = l.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), Value::String(crate::ruby_text::strip(v).to_string()));
        }
    }
    let reply = if headers.get("upgrade").and_then(Value::as_str).is_some_and(|u| u.eq_ignore_ascii_case("websocket")) {
        text_reply("501 Not Implemented", "not ported yet: the terminal bridge")
    } else {
        let length = headers.get("content-length").and_then(Value::as_str).and_then(|v| v.trim().parse::<usize>().ok()).unwrap_or(0).min(MAX_BYTES * 50);
        let mut body = vec![0u8; length];
        let _ = reader.read_exact(&mut body);
        respond(guard, token, &method, &path, &headers, &body)
    };
    let (status, kind, payload) = reply;
    let head = format!("HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", payload.len());
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(&payload);
}

fn open_browser(url: &str) {
    if std::env::var_os("QM_GUI_NO_OPEN").is_none() {
        let _ = std::process::Command::new("open").arg(url).status();
    }
}

fn random_token() -> String {
    let mut bytes = [0u8; 24];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut bytes);
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `qm gui` with `QM_RUST_GUI` set: serves until interrupted.
pub fn run() -> Outcome {
    let port = match port() {
        Ok(p) => p,
        Err(Failed::Ruby) | Err(Failed::Abort(_)) => return Outcome::Delegate,
    };
    let url = format!("http://127.0.0.1:{port}");
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
            println!("qm gui already running → {url}   (opening the existing tab)");
            open_browser(&url);
            return done(String::new());
        }
        Err(_) => return Outcome::Delegate,
    };
    println!("qm gui → {url}   (Ctrl-C to stop)");
    open_browser(&url);
    extern "C" fn stop(_: libc::c_int) {
        unsafe { libc::_exit(0) }
    }
    unsafe { libc::signal(libc::SIGINT, stop as extern "C" fn(libc::c_int) as libc::sighandler_t) };
    let token = random_token();
    let guard = std::sync::Arc::new(Guard::new(port));
    for stream in listener.incoming().flatten() {
        let (guard, token) = (guard.clone(), token.clone());
        std::thread::spawn(move || handle(stream, &guard, &token));
    }
    done(String::new())
}
