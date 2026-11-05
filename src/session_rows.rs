use crate::data_root::home;
use crate::ruby_text::prefix;
use crate::session_log::Session;

fn format_duration(seconds: Option<i64>) -> String {
    match seconds {
        None => "-".into(),
        Some(s) if s < 60 => format!("{s}s"),
        Some(s) if s < 3600 => format!("{}m", s / 60),
        Some(s) => format!("{}h{:02}m", s / 3600, (s % 3600) / 60),
    }
}

/// The `qm sessions` / `qm inbox` table: newest first, at most `limit` rows.
pub fn print(mut sessions: Vec<Session>, limit: usize) -> String {
    sessions.sort_by_key(|s| s.last_ts());
    sessions.reverse();
    let mut out = String::new();
    for s in sessions.iter().take(limit) {
        let status = if s.live { "● live " } else { "  ended" };
        let duration = if s.ended() { format_duration(s.duration_s()) } else { "-".into() };
        let cwd = s.cwd().unwrap_or_else(|| "?".into()).replacen(&home(), "~", 1);
        let cols = [
            status.to_string(),
            prefix(&s.id, 8),
            s.item_label().unwrap_or_else(|| "-".into()),
            cwd,
            s.branch().unwrap_or_else(|| "-".into()),
            prefix(&s.started_ts(), 16),
            duration,
        ];
        out.push_str(&cols.join("  "));
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::format_duration;

    #[test]
    fn durations_use_seconds_minutes_then_hours() {
        assert_eq!(format_duration(None), "-");
        assert_eq!(format_duration(Some(59)), "59s");
        assert_eq!(format_duration(Some(60)), "1m");
        assert_eq!(format_duration(Some(3599)), "59m");
        assert_eq!(format_duration(Some(3600 + 125)), "1h02m");
    }
}
