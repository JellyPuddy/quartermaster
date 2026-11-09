//! What the GUI server needs at start: the browser tab, the per-start terminal token, the request timeout.

use std::io::Read;

/// How long a client may take to send its request: 60 s, or `QM_GUI_REQUEST_TIMEOUT_MS` (tests shorten it).
pub fn request_timeout() -> std::time::Duration {
    let ms = std::env::var("QM_GUI_REQUEST_TIMEOUT_MS").ok().and_then(|v| v.parse::<u64>().ok()).filter(|ms| *ms > 0).unwrap_or(60_000);
    std::time::Duration::from_millis(ms)
}

pub fn open_browser(url: &str) {
    if std::env::var_os("QM_GUI_NO_OPEN").is_none() {
        let _ = std::process::Command::new("open").arg(url).status();
    }
}

pub fn random_token() -> String {
    let mut bytes = [0u8; 24];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut bytes);
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
