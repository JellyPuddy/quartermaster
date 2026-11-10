//! A routine's UTC cron read as weekdays and an Amsterdam time, and back. Expected values are worked by hand:
//! Amsterdam is UTC+1 in winter and UTC+2 from the last Sunday of March 01:00 UTC to the last Sunday of
//! October 01:00 UTC (in 2026: March 29 and October 25).

use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use quartermaster::local_schedule::{noon, to_cron, LocalSchedule};

fn winter() -> DateTime<Utc> {
    noon(NaiveDate::from_ymd_opt(2026, 1, 15).unwrap())
}

fn summer() -> DateTime<Utc> {
    noon(NaiveDate::from_ymd_opt(2026, 7, 15).unwrap())
}

fn schedule(cron: &str, on: DateTime<Utc>) -> LocalSchedule {
    LocalSchedule::from_cron(cron, on)
}

fn days(s: &LocalSchedule) -> Vec<u32> {
    s.days.clone().unwrap()
}

#[test]
fn winter_shows_the_utc_cron_one_hour_later() {
    let s = schedule("0 7 * * 1,4", winter());
    assert!(!s.raw());
    assert_eq!((days(&s), s.time.as_deref(), s.label().as_str()), (vec![1, 4], Some("08:00"), "Mon, Thu 08:00"));
}

#[test]
fn summer_shows_the_same_cron_two_hours_later() {
    let s = schedule("0 7 * * 1,4", summer());
    assert_eq!((days(&s), s.time.as_deref(), s.label().as_str()), (vec![1, 4], Some("09:00"), "Mon, Thu 09:00"));
}

#[test]
fn every_day_reads_as_every_day() {
    assert_eq!(schedule("0 7 * * *", winter()).label(), "every day 08:00");
    assert_eq!(schedule("5 7 * * 0-6", winter()).label(), "every day 08:05");
    assert_eq!(to_cron(&[0, 1, 2, 3, 4, 5, 6], "08:00", winter()).unwrap(), "0 7 * * *");
}

#[test]
fn a_late_utc_time_lands_on_the_next_local_day() {
    let s = schedule("30 23 * * 0,6", winter());
    assert_eq!((days(&s), s.time.as_deref(), s.label().as_str()), (vec![0, 1], Some("00:30"), "Mon, Sun 00:30"));
    assert_eq!(days(&schedule("30 22 * * 0,6", summer())), [0, 1]);
    assert_eq!(days(&schedule("30 22 * * 6", winter())), [6]);
}

#[test]
fn sunday_may_be_written_as_seven_and_ranges_expand() {
    assert_eq!(days(&schedule("0 7 * * 1-5", winter())), [1, 2, 3, 4, 5]);
    assert_eq!(days(&schedule("0 7 * * 7", winter())), [0]);
}

#[test]
fn local_time_becomes_a_utc_cron_for_the_current_offset() {
    assert_eq!(to_cron(&[1, 4], "08:00", winter()).unwrap(), "0 7 * * 1,4");
    assert_eq!(to_cron(&[4, 1], "08:00", summer()).unwrap(), "0 6 * * 1,4");
}

#[test]
fn a_local_time_near_midnight_shifts_the_utc_weekday_back() {
    assert_eq!(to_cron(&[1], "00:30", winter()).unwrap(), "30 23 * * 0");
    assert_eq!(to_cron(&[1], "01:30", summer()).unwrap(), "30 23 * * 0");
    assert_eq!(to_cron(&[0, 1], "00:00", summer()).unwrap(), "0 22 * * 0,6");
}

#[test]
fn round_trip_keeps_the_cron() {
    for cron in ["0 7 * * 1,4", "30 23 * * 0", "15 22 * * 6", "0 0 * * 1-5", "59 23 * * *"] {
        for on in [winter(), summer()] {
            let s = schedule(cron, on);
            let ints: Vec<i64> = days(&s).iter().map(|d| *d as i64).collect();
            let back = to_cron(&ints, s.time.as_deref().unwrap(), on).unwrap();
            let again = schedule(&back, on);
            assert_eq!((days(&again), again.time), (days(&s), s.time), "{cron} on {on}");
        }
    }
}

#[test]
fn the_offset_switches_at_one_utc_on_the_last_sundays() {
    let at = |m, d, h, min| Utc.with_ymd_and_hms(2026, m, d, h, min, 0).unwrap();
    let time = |on| schedule("0 7 * * 1", on).time.unwrap();
    assert_eq!(time(at(3, 29, 0, 59)), "08:00");
    assert_eq!(time(at(3, 29, 1, 0)), "09:00");
    assert_eq!(time(at(10, 25, 0, 59)), "09:00");
    assert_eq!(time(at(10, 25, 1, 0)), "08:00");
}

#[test]
fn crons_the_picker_cannot_express_stay_raw() {
    for cron in ["*/15 * * * *", "0 7 1 * *", "0 7 * 6 *", "0 7,19 * * *", "0 */2 * * 1", "0 7 * * MON", "0 7 * * 8", "60 7 * * *", "0 24 * * *", "0 7 * *", "nope", ""] {
        let s = schedule(cron, winter());
        assert!(s.raw() && s.days.is_none() && s.time.is_none(), "{cron}");
        assert_eq!(s.label(), format!("{cron} UTC").trim(), "{cron}");
    }
}

#[test]
fn the_cron_stays_as_given() {
    assert_eq!(schedule("0 7 * * 1,4", summer()).cron, "0 7 * * 1,4");
}

#[test]
fn rejects_a_picker_value_it_cannot_turn_into_a_cron() {
    assert!(to_cron(&[], "08:00", winter()).is_err());
    assert!(to_cron(&[1], "8am", winter()).is_err());
    assert!(to_cron(&[1], "24:00", winter()).is_err());
    assert!(to_cron(&[7], "08:00", winter()).is_err());
}
