//! A local automation's cron in Amsterdam wall-clock time. Expected values are worked by hand: Amsterdam is
//! UTC+1 in winter and UTC+2 from the last Sunday of March 01:00 UTC to the last Sunday of October 01:00 UTC
//! (in 2026: March 29 and October 25). 2026-01-15 is a Thursday; 2026-02-01 a Sunday.

use chrono::{DateTime, FixedOffset, TimeZone, Utc};
use quartermaster::local_cron::{self, LocalCron};

fn utc(month: u32, day: u32, hour: u32, minute: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, month, day, hour, minute, 0).unwrap()
}

fn cron(text: &str) -> LocalCron {
    LocalCron::new(text).unwrap()
}

fn next(text: &str, after: DateTime<Utc>) -> Option<DateTime<Utc>> {
    local_cron::next_after(text, after).unwrap()
}

#[test]
fn a_winter_cron_fires_at_local_time_one_hour_after_utc() {
    assert!(local_cron::due("0 8 * * *", utc(1, 15, 6, 0), utc(1, 15, 7, 0)).unwrap());
    assert!(!local_cron::due("0 8 * * *", utc(1, 15, 6, 0), utc(1, 15, 6, 59)).unwrap());
    assert_eq!(cron("0 8 * * *").last_due(utc(1, 15, 6, 0), utc(1, 15, 7, 3)), Some(utc(1, 15, 7, 0)));
}

#[test]
fn a_summer_cron_fires_two_hours_after_utc() {
    assert_eq!(cron("0 8 * * *").last_due(utc(7, 15, 5, 0), utc(7, 15, 6, 30)), Some(utc(7, 15, 6, 0)));
    assert!(!local_cron::due("0 8 * * *", utc(7, 15, 6, 0), utc(7, 15, 6, 59)).unwrap());
}

#[test]
fn missed_minutes_coalesce_into_one_and_since_is_exclusive() {
    let c = cron("*/15 * * * *");
    assert_eq!(c.last_due(utc(1, 15, 7, 1), utc(1, 15, 8, 0) + chrono::Duration::seconds(30)), Some(utc(1, 15, 8, 0)));
    assert_eq!(c.last_due(utc(1, 15, 7, 0), utc(1, 15, 7, 14)), None);
    assert_eq!(c.last_due(utc(1, 15, 7, 0), utc(1, 15, 7, 15)), Some(utc(1, 15, 7, 15)));
}

#[test]
fn times_in_another_zone_mean_the_same_instant() {
    let plus_one = FixedOffset::east_opt(3600).unwrap();
    let at = |h, m| plus_one.with_ymd_and_hms(2026, 1, 15, h, m, 0).unwrap().with_timezone(&Utc);
    assert!(local_cron::due("0 8 * * *", at(7, 30), at(8, 0)).unwrap());
}

#[test]
fn range_with_step() {
    let c = cron("10-20/5 9 * * *");
    assert_eq!(c.next_after(utc(1, 15, 8, 10)), Some(utc(1, 15, 8, 15)));
    assert_eq!(c.next_after(utc(1, 15, 8, 15)), Some(utc(1, 15, 8, 20)));
    assert_eq!(c.next_after(utc(1, 15, 8, 20)), Some(utc(1, 16, 8, 10)));
}

#[test]
fn start_with_step_runs_to_the_end_of_the_field() {
    assert_eq!(next("50/5 9 * * *", utc(1, 15, 8, 30)), Some(utc(1, 15, 8, 50)));
    assert_eq!(next("50/5 9 * * *", utc(1, 15, 8, 50)), Some(utc(1, 15, 8, 55)));
}

#[test]
fn lists_and_weekday_ranges() {
    let c = cron("0 9,17 * * 1-5");
    assert_eq!(c.next_after(utc(1, 15, 8, 0)), Some(utc(1, 15, 16, 0)));
    assert_eq!(c.next_after(utc(1, 16, 16, 0)), Some(utc(1, 19, 8, 0)), "Friday 17:00 is followed by Monday 09:00");
}

#[test]
fn weekday_seven_is_sunday() {
    assert_eq!(next("0 9 * * 7", utc(1, 15, 0, 0)), Some(utc(1, 18, 8, 0)));
    assert_eq!(next("0 9 * * 0", utc(1, 15, 0, 0)), Some(utc(1, 18, 8, 0)));
    assert_eq!(next("0 9 * * 6-7", utc(1, 15, 0, 0)), Some(utc(1, 17, 8, 0)));
}

#[test]
fn day_of_month_or_weekday_when_both_are_restricted() {
    let c = cron("0 9 1 * 1");
    assert_eq!(c.next_after(utc(1, 15, 0, 0)), Some(utc(1, 19, 8, 0)), "a Monday");
    assert_eq!(c.next_after(utc(1, 26, 9, 0)), Some(utc(2, 1, 8, 0)), "the 1st, a Sunday");
}

#[test]
fn day_of_month_and_weekday_when_one_starts_with_a_star() {
    let c = cron("0 9 */2 * 1");
    assert_eq!(c.next_after(utc(1, 15, 0, 0)), Some(utc(1, 19, 8, 0)), "Monday the 19th is odd");
    assert_eq!(c.next_after(utc(1, 20, 0, 0)), Some(utc(2, 9, 8, 0)), "the 26th and 2nd are even");
}

#[test]
fn months() {
    assert_eq!(next("0 9 1 3,9 *", utc(1, 15, 0, 0)), Some(utc(3, 1, 8, 0)));
}

#[test]
fn a_minute_in_the_spring_forward_gap_never_happens() {
    let c = cron("30 2 * * *");
    assert_eq!(c.next_after(utc(3, 28, 0, 0)), Some(utc(3, 28, 1, 30)));
    assert_eq!(c.next_after(utc(3, 28, 1, 30)), Some(utc(3, 30, 0, 30)), "March 29 has no 02:30");
    assert_eq!(c.last_due(utc(3, 28, 23, 0), utc(3, 29, 23, 0)), None);
    assert_eq!(next("0 3 * * *", utc(3, 28, 23, 0)), Some(utc(3, 29, 1, 0)), "03:00 CEST");
}

#[test]
fn a_minute_in_the_fall_back_hour_happens_twice() {
    let c = cron("30 2 * * *");
    assert_eq!(c.next_after(utc(10, 25, 0, 0)), Some(utc(10, 25, 0, 30)), "02:30 CEST");
    assert_eq!(c.next_after(utc(10, 25, 0, 30)), Some(utc(10, 25, 1, 30)), "02:30 CET");
    assert_eq!(c.next_after(utc(10, 25, 1, 30)), Some(utc(10, 26, 1, 30)));
    assert_eq!(c.last_due(utc(10, 25, 0, 0), utc(10, 25, 2, 0)), Some(utc(10, 25, 1, 30)));
    assert!(c.last_due(utc(10, 25, 0, 0), utc(10, 25, 0, 45)).is_some());
    assert!(c.last_due(utc(10, 25, 0, 45), utc(10, 25, 1, 45)).is_some());
}

#[test]
fn fall_back_minutes_of_both_passes_keep_time_order() {
    let c = cron("0,30 2 * * *");
    assert_eq!(c.next_after(utc(10, 25, 0, 10)), Some(utc(10, 25, 0, 30)), "02:30 CEST comes before 02:00 CET");
    assert_eq!(c.last_due(utc(10, 25, 0, 45), utc(10, 25, 1, 10)), Some(utc(10, 25, 1, 0)), "02:00 CET");
}

#[test]
fn lookback_is_capped_at_eight_days() {
    assert!(!local_cron::due("0 9 1 1 *", utc(1, 1, 7, 0), utc(1, 15, 0, 0)).unwrap(), "Jan 1 is more than 8 days back");
    assert!(local_cron::due("0 9 1 1 *", utc(1, 1, 7, 0), utc(1, 5, 0, 0)).unwrap());
}

#[test]
fn rare_and_impossible_dates() {
    assert_eq!(next("0 0 29 2 *", utc(1, 15, 0, 0)), Some(Utc.with_ymd_and_hms(2028, 2, 28, 23, 0, 0).unwrap()));
    assert_eq!(next("0 0 31 2 *", utc(1, 15, 0, 0)), None);
}

#[test]
fn errors_name_the_problem() {
    assert_eq!(local_cron::error("*/15 9-17 1,15 * 1-5"), None);
    let cases = [
        ("* * * *", "a cron has five fields (minute hour day month weekday), got \"* * * *\""),
        ("60 * * * *", "minute: \"60\" is outside 0-59"),
        ("0 9 * * 8", "weekday: \"8\" is outside 0-7"),
        ("0 9 0 * *", "day: \"0\" is outside 1-31"),
        ("0 */0 * * *", "hour: \"*/0\" has a zero step"),
        ("0 17-9 * * *", "hour: \"17-9\" runs backwards"),
        ("0 9 * * MON", "weekday: \"MON\" isn't a number, range, list or step"),
        ("1, 9 * * *", "minute: \"\" isn't a number, range, list or step"),
    ];
    for (text, message) in cases {
        assert_eq!(local_cron::error(text).as_deref(), Some(message), "{text}");
    }
    assert!(local_cron::due("bad", utc(1, 1, 0, 0), utc(1, 2, 0, 0)).is_err());
}

#[test]
fn label_and_picker_fields() {
    let label = |text| local_cron::label(text).unwrap();
    assert_eq!(label("0 8 * * 1,4"), "Mon, Thu 08:00");
    assert_eq!(label("5 8 * * 7"), "Sun 08:05");
    assert_eq!(label("0 8 * * *"), "every day 08:00");
    assert_eq!(label("0 8 * * 0-7"), "every day 08:00");
    assert_eq!(label("*/15 * * * *"), "*/15 * * * * Amsterdam time");
    let simple = cron("5 8 * * 1,4");
    assert_eq!((simple.days(), simple.time()), (Some(vec![1, 4]), Some("08:05".to_string())));
    assert_eq!(cron("0 8 1 * *").time(), None);
}

#[test]
fn to_cron_writes_local_time_unshifted() {
    assert_eq!(local_cron::to_cron(&[4, 1], "08:05").unwrap(), "5 8 * * 1,4");
    assert_eq!(local_cron::to_cron(&[0, 1, 2, 3, 4, 5, 6], "23:00").unwrap(), "0 23 * * *");
    assert!(local_cron::to_cron(&[], "08:00").is_err());
}
