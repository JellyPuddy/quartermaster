use chrono::{DateTime, FixedOffset, Local, SecondsFormat, Utc};

/// `Time.now.iso8601`: local offset, whole seconds.
pub fn now_iso() -> String {
    Local::now().to_rfc3339_opts(SecondsFormat::Secs, false)
}

/// `Time.now.utc.iso8601`.
pub fn now_utc_iso() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub fn parse(ts: &str) -> Option<DateTime<FixedOffset>> {
    DateTime::parse_from_rfc3339(ts).ok()
}

/// Seconds from `ts` to now, rounded like Ruby's `(Time.now - Time.parse(ts)).round`.
pub fn seconds_since(ts: &str) -> Option<i64> {
    let then = parse(ts)?;
    let delta = Local::now().signed_duration_since(then);
    Some((delta.num_milliseconds() as f64 / 1000.0).round() as i64)
}
