//! A local automation's 5-field cron, read as wall-clock time in Europe/Amsterdam (`local_schedule`'s built-in
//! EU DST rule, no TZ switching). Each field takes `*`, numbers, lists, ranges and steps (`*/n`, `a-b/n`,
//! `a/n`); weekday is 0-7 with 7 = Sunday. When day-of-month and weekday both start with something other than
//! `*`, a day matches either; otherwise both must match. A wall-clock minute in the spring-forward gap never
//! happens; one in the fall-back hour happens twice (two UTC instants).

use chrono::{DateTime, Datelike, Duration, NaiveDate, TimeZone, Timelike, Utc};
use regex::Regex;

use crate::local_schedule::{offset_minutes, picked, DAY_NAMES, LABEL_ORDER};

const FIELDS: [(&str, u32, u32); 5] = [("minute", 0, 59), ("hour", 0, 23), ("day", 1, 31), ("month", 1, 12), ("weekday", 0, 7)];
const LOOKBACK_DAYS: i64 = 8;
const LOOKAHEAD_DAYS: i64 = 366 * 9;

pub struct LocalCron {
    pub cron: String,
    minutes: Vec<u32>,
    hours: Vec<u32>,
    days_of_month: Vec<u32>,
    months: Vec<u32>,
    weekdays: Vec<u32>,
    either_day: bool,
    simple: bool,
}

fn quote(part: &str) -> String {
    crate::ruby_text::inspect_ascii(part).unwrap_or_else(|| format!("{part:?}"))
}

fn values(name: &str, text: &str, min: u32, max: u32) -> Result<Vec<u32>, String> {
    let part_re = Regex::new(r"^(?:(\*)|([0-9]+)(?:-([0-9]+))?)(?:/([0-9]+))?$").unwrap();
    let mut out: Vec<u32> = vec![];
    for part in text.split(',') {
        let caps = part_re.captures(part).ok_or_else(|| format!("{name}: {} isn't a number, range, list or step", quote(part)))?;
        let number = |m: Option<regex::Match>| m.map(|m| m.as_str().parse::<u32>().unwrap_or(u32::MAX));
        let star = caps.get(1).is_some();
        let from = number(caps.get(2)).unwrap_or(min);
        let step = number(caps.get(4));
        let star_max = if name == "weekday" { 6 } else { max };
        let to = number(caps.get(3)).unwrap_or(if star || step.is_some() { star_max } else { from });
        let step = step.unwrap_or(1);
        if !((min..=max).contains(&from) && (min..=max).contains(&to)) {
            return Err(format!("{name}: {} is outside {min}-{max}", quote(part)));
        }
        if from > to {
            return Err(format!("{name}: {} runs backwards", quote(part)));
        }
        if step == 0 {
            return Err(format!("{name}: {} has a zero step", quote(part)));
        }
        out.extend((from..=to).step_by(step as usize));
    }
    out.sort();
    out.dedup();
    Ok(out)
}

fn local(utc: DateTime<Utc>) -> DateTime<Utc> {
    utc + Duration::minutes(offset_minutes(utc))
}

fn minute_floor(time: DateTime<Utc>) -> DateTime<Utc> {
    time.with_second(0).and_then(|t| t.with_nanosecond(0)).unwrap_or(time)
}

/// Weekdays (0 = Sunday) and a local "HH:MM" as a local cron: no UTC shift.
pub fn to_cron(days: &[i64], time: &str) -> Result<String, String> {
    let (days, minutes) = picked(days, time)?;
    let dow = if days.len() == 7 { "*".to_string() } else { days.iter().map(u32::to_string).collect::<Vec<_>>().join(",") };
    Ok(format!("{} {} * * {dow}", minutes % 60, minutes / 60))
}

/// None for a valid cron, else what is wrong with it.
pub fn error(cron: &str) -> Option<String> {
    LocalCron::new(cron).err()
}

/// True when a scheduled minute lies in (since, now]; any number of them counts as one.
pub fn due(cron: &str, since: DateTime<Utc>, now: DateTime<Utc>) -> Result<bool, String> {
    Ok(LocalCron::new(cron)?.last_due(since, now).is_some())
}

pub fn next_after(cron: &str, time: DateTime<Utc>) -> Result<Option<DateTime<Utc>>, String> {
    Ok(LocalCron::new(cron)?.next_after(time))
}

pub fn label(cron: &str) -> Result<String, String> {
    Ok(LocalCron::new(cron)?.label())
}

impl LocalCron {
    pub fn new(cron: &str) -> Result<LocalCron, String> {
        let cron = cron.trim().to_string();
        let parts: Vec<&str> = cron.split_whitespace().collect();
        if parts.len() != 5 {
            return Err(format!("a cron has five fields (minute hour day month weekday), got {}", quote(&cron)));
        }
        let mut found = vec![];
        for ((name, min, max), text) in FIELDS.iter().zip(&parts) {
            found.push(values(name, text, *min, *max)?);
        }
        let mut weekdays: Vec<u32> = found[4].iter().map(|d| d % 7).collect();
        weekdays.sort();
        weekdays.dedup();
        let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
        Ok(LocalCron {
            either_day: !parts[2].starts_with('*') && !parts[4].starts_with('*'),
            simple: digits(parts[0]) && digits(parts[1]) && parts[2] == "*" && parts[3] == "*",
            minutes: found[0].clone(),
            hours: found[1].clone(),
            days_of_month: found[2].clone(),
            months: found[3].clone(),
            weekdays,
            cron,
        })
    }

    /// The latest scheduled minute (UTC) in (since, now], or None. A `since` older than LOOKBACK_DAYS before
    /// `now` counts from then.
    pub fn last_due(&self, since: DateTime<Utc>, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        let now = minute_floor(now);
        let since = since.max(now - Duration::days(LOOKBACK_DAYS));
        if since >= now {
            return None;
        }
        let mut day = local(now).date_naive();
        let first = local(since).date_naive();
        while day >= first {
            for at in self.instants(day).into_iter().rev() {
                if at <= now && at > since {
                    return Some(at);
                }
                if at <= since {
                    break;
                }
            }
            day = day.pred_opt()?;
        }
        None
    }

    /// The first scheduled minute (UTC) after `time`, or None when none comes in nine years.
    pub fn next_after(&self, time: DateTime<Utc>) -> Option<DateTime<Utc>> {
        let mut day = local(time).date_naive();
        for _ in 0..LOOKAHEAD_DAYS {
            if let Some(found) = self.instants(day).into_iter().find(|at| *at > time) {
                return Some(found);
            }
            day = day.succ_opt()?;
        }
        None
    }

    pub fn simple(&self) -> bool {
        self.simple
    }

    /// Local weekdays (0 = Sunday) of a simple cron ("M H * * <weekdays>"), else None.
    pub fn days(&self) -> Option<Vec<u32>> {
        self.simple.then(|| self.weekdays.clone())
    }

    pub fn time(&self) -> Option<String> {
        self.simple.then(|| format!("{:02}:{:02}", self.hours[0], self.minutes[0]))
    }

    /// "Mon, Thu 08:00", "every day 08:00", or the cron itself marked as Amsterdam time.
    pub fn label(&self) -> String {
        let Some(time) = self.time() else { return format!("{} Amsterdam time", self.cron) };
        if self.weekdays.len() == 7 {
            return format!("every day {time}");
        }
        let names: Vec<&str> = LABEL_ORDER.iter().filter(|d| self.weekdays.contains(d)).map(|d| DAY_NAMES[*d as usize]).collect();
        format!("{} {time}", names.join(", "))
    }

    fn day_matches(&self, date: NaiveDate) -> bool {
        if !self.months.contains(&date.month()) {
            return false;
        }
        let by_dom = self.days_of_month.contains(&date.day());
        let by_dow = self.weekdays.contains(&date.weekday().num_days_from_sunday());
        if self.either_day { by_dom || by_dow } else { by_dom && by_dow }
    }

    /// Every UTC instant on local `date` that the cron schedules, oldest first.
    fn instants(&self, date: NaiveDate) -> Vec<DateTime<Utc>> {
        if !self.day_matches(date) {
            return vec![];
        }
        let mut out = vec![];
        for hour in &self.hours {
            for minute in &self.minutes {
                let Some(wall) = date.and_hms_opt(*hour, *minute, 0).map(|w| Utc.from_utc_datetime(&w)) else { continue };
                // the UTC instants whose Amsterdam wall clock reads `wall`: none in the spring-forward gap, two
                // in the fall-back hour
                out.extend([wall - Duration::hours(2), wall - Duration::hours(1)].into_iter().filter(|c| local(*c) == wall));
            }
        }
        out.sort();
        out
    }
}
