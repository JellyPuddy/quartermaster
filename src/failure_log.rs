use std::collections::HashMap;
use std::io::Write;
use std::sync::{LazyLock, Mutex};

use crate::{clock, data_root};

pub const TRANSIENT: &str = "transient";
/// The contexts with a `failure_log::success` call site.
pub const SUCCESS_REPORTING: [&str; 4] = ["pr-inbox", "pr-deployment", "pr-refresh", "gui-client"];
/// Messages gh prints when it can't reach GitHub at all.
const NETWORK_MESSAGES: [&str; 7] = ["error connecting to api.github.com", "githubstatus.com", "connection reset", "dial tcp", "read tcp", "i/o timeout", "tls handshake timeout"];
/// A client that hung up mid-response: the browser's doing, not qm's.
const DISCONNECTS: [&str; 2] = ["Errno::EPIPE", "Errno::ECONNRESET"];

static OUTAGES: LazyLock<Mutex<HashMap<String, usize>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn outages() -> std::sync::MutexGuard<'static, HashMap<String, usize>> {
    OUTAGES.lock().unwrap_or_else(|p| p.into_inner())
}

pub fn transient(class: &str, message: &str) -> bool {
    let lower = message.to_lowercase();
    DISCONNECTS.contains(&class) || NETWORK_MESSAGES.iter().any(|m| lower.contains(m)) || (message.starts_with("gh ") && message.ends_with(": EOF"))
}

/// One header line, `<iso8601> [<context>] <Class>: <message>`; a transient failure carries `transient` after its
/// context and, in a success-reporting context, is written only for the first failure of an outage.
pub fn failure(context: &str, class: &str, message: &str) {
    let mut tag = "";
    if transient(class, message) {
        if SUCCESS_REPORTING.contains(&context) && !first_of_outage(context) {
            return;
        }
        tag = "transient ";
    }
    let folded = message.split('\n').map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ");
    append(&format!("{} [{context}] {tag}{class}: {folded}\n", clock::now_iso()));
}

fn first_of_outage(context: &str) -> bool {
    let mut outages = outages();
    let count = outages.entry(context.to_string()).or_insert(0);
    *count += 1;
    *count == 1
}

/// The context's next success ends its outage with one `recovered after <n> failure(s)` header.
pub fn success(context: &str) {
    let Some(failures) = outages().remove(context) else { return };
    append(&format!("{} [{context}] recovered after {failures} failure{}\n", clock::now_iso(), if failures == 1 { "" } else { "s" }));
}

/// What a GUI response write did: a hung-up client is a transient failure, any other error is logged as is.
pub fn client_write(sent: std::io::Result<()>) {
    match sent {
        Ok(()) => success("gui-client"),
        Err(e) => {
            let class = match e.kind() {
                std::io::ErrorKind::BrokenPipe => "Errno::EPIPE",
                std::io::ErrorKind::ConnectionReset => "Errno::ECONNRESET",
                _ => "IOError",
            };
            failure("gui-client", class, &e.to_string());
        }
    }
}

fn append(text: &str) {
    let _ = data_root::ensure_setup();
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(data_root::root().join("qm.log")) {
        let _ = f.write_all(text.as_bytes());
    }
}

/// Forgets every open outage (tests).
pub fn reset() {
    outages().clear();
}
