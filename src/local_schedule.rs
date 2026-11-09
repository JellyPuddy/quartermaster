//! A routine's UTC cron read as weekdays plus a local time in Europe/Amsterdam, and back. Only
//! "M H * * <weekdays or *>" with one minute and one hour converts; any other cron is `raw` and shows and edits
//! as itself. The offset is the one in force at the reference moment `on`, so a stored cron keeps its UTC time
//! across a DST change (no rewrites): 0 7 UTC reads 08:00 in winter and 09:00 in summer. The EU DST rule is
//! built in.

use chrono::{DateTime, Datelike, Duration, NaiveDate, TimeZone, Utc};
use regex::Regex;

pub const DAY_NAMES: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
pub const LABEL_ORDER: [u32; 7] = [1, 2, 3, 4, 5, 6, 0];
const DAY_MINUTES: i64 = 24 * 60;

pub struct LocalSchedule {
    pub cron: String,
    /// Local weekdays (0 = Sunday); None for a raw cron.
    pub days: Option<Vec<u32>>,
    pub time: Option<String>,
}

/// A Date read at noon UTC, the moment `on` stands for when only a day is known.
pub fn noon(date: NaiveDate) -> DateTime<Utc> {
    Utc.from_utc_datetime(&date.and_hms_opt(12, 0, 0).unwrap())
}

/// Minutes east of UTC in Amsterdam at `on`: CEST from the last Sunday of March 01:00 UTC to the last Sunday of
/// October 01:00 UTC, else CET.
pub fn offset_minutes(on: DateTime<Utc>) -> i64 {
    let year = on.year();
    if switch_moment(year, 3) <= on && on < switch_moment(year, 10) { 120 } else { 60 }
}

fn switch_moment(year: i32, month: u32) -> DateTime<Utc> {
    let first_of_next = if month == 12 { NaiveDate::from_ymd_opt(year + 1, 1, 1) } else { NaiveDate::from_ymd_opt(year, month + 1, 1) }.unwrap();
    let last = first_of_next - Duration::days(1);
    let sunday = last - Duration::days(last.weekday().num_days_from_sunday() as i64);
    Utc.from_utc_datetime(&sunday.and_hms_opt(1, 0, 0).unwrap())
}

fn time_pattern() -> Regex {
    Regex::new(r"^([01][0-9]|2[0-3]):([0-5][0-9])$").unwrap()
}

/// The weekdays and "HH:MM" a picker holds, checked: sorted unique days and the minutes of the day.
pub(crate) fn picked(days: &[i64], time: &str) -> Result<(Vec<u32>, i64), String> {
    let caps = time_pattern().captures(time).ok_or_else(|| format!("time must be HH:MM, got {time:?}"))?;
    let mut days: Vec<i64> = days.to_vec();
    days.sort();
    days.dedup();
    if days.is_empty() {
        return Err("pick at least one weekday".into());
    }
    if !days.iter().all(|d| (0..=6).contains(d)) {
        return Err("weekdays are 0 (Sunday) to 6".into());
    }
    let minutes = caps[1].parse::<i64>().unwrap() * 60 + caps[2].parse::<i64>().unwrap();
    Ok((days.into_iter().map(|d| d as u32).collect(), minutes))
}

/// Weekdays (0 = Sunday) and a local "HH:MM" as the UTC cron for the offset at `on`; a local time the offset
/// pushes past midnight moves its weekdays back a day.
pub fn to_cron(days: &[i64], time: &str, on: DateTime<Utc>) -> Result<String, String> {
    let (days, local) = picked(days, time)?;
    let total = local - offset_minutes(on);
    let (shift, minutes) = (total.div_euclid(DAY_MINUTES), total.rem_euclid(DAY_MINUTES));
    let dow = if days.len() == 7 {
        "*".to_string()
    } else {
        let mut shifted: Vec<i64> = days.iter().map(|d| (*d as i64 + shift).rem_euclid(7)).collect();
        shifted.sort();
        shifted.iter().map(i64::to_string).collect::<Vec<_>>().join(",")
    };
    Ok(format!("{} {} * * {dow}", minutes % 60, minutes / 60))
}

fn single(field: &str, max: i64) -> Option<i64> {
    if field.is_empty() || field.len() > 2 || !field.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    field.parse::<i64>().ok().filter(|v| *v <= max)
}

fn weekdays(field: &str) -> Option<Vec<i64>> {
    if field == "*" {
        return Some((0..7).collect());
    }
    let part = Regex::new(r"^([0-7])(?:-([0-7]))?$").unwrap();
    let mut days: Vec<i64> = vec![];
    for piece in field.split(',') {
        let caps = part.captures(piece)?;
        let from: i64 = caps[1].parse().unwrap();
        let to: i64 = caps.get(2).map_or(from, |m| m.as_str().parse().unwrap());
        if from > to {
            return None;
        }
        days.extend((from..=to).map(|d| d % 7));
    }
    days.sort();
    days.dedup();
    Some(days)
}

impl LocalSchedule {
    pub fn from_cron(cron: &str, on: DateTime<Utc>) -> LocalSchedule {
        let cron = cron.trim().to_string();
        let raw = LocalSchedule { cron: cron.clone(), days: None, time: None };
        let fields: Vec<&str> = cron.split_whitespace().collect();
        if fields.len() != 5 || fields[2] != "*" || fields[3] != "*" {
            return raw;
        }
        let (Some(minute), Some(hour), Some(utc_days)) = (single(fields[0], 59), single(fields[1], 23), weekdays(fields[4])) else { return raw };
        let total = hour * 60 + minute + offset_minutes(on);
        let (shift, local) = (total.div_euclid(DAY_MINUTES), total.rem_euclid(DAY_MINUTES));
        let mut days: Vec<u32> = utc_days.iter().map(|d| (*d + shift).rem_euclid(7) as u32).collect();
        days.sort();
        days.dedup();
        LocalSchedule { cron, days: Some(days), time: Some(format!("{:02}:{:02}", local / 60, local % 60)) }
    }

    pub fn raw(&self) -> bool {
        self.days.is_none()
    }

    pub fn every_day(&self) -> bool {
        self.days.as_ref().is_some_and(|d| d.len() == 7)
    }

    /// "Mon, Thu 08:00", "every day 08:00", or the raw cron marked as UTC.
    pub fn label(&self) -> String {
        let (Some(days), Some(time)) = (&self.days, &self.time) else { return format!("{} UTC", self.cron).trim().to_string() };
        if self.every_day() {
            return format!("every day {time}");
        }
        let names: Vec<&str> = LABEL_ORDER.iter().filter(|d| days.contains(d)).map(|d| DAY_NAMES[*d as usize]).collect();
        format!("{} {time}", names.join(", "))
    }
}
