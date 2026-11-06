# frozen_string_literal: true

require_relative "test_helper"

# Expected values are worked by hand: Amsterdam is UTC+1 in winter and UTC+2 from the last Sunday
# of March 01:00 UTC to the last Sunday of October 01:00 UTC (in 2026: March 29 and October 25).
# 2026-01-15 is a Thursday; 2026-02-01 a Sunday.
class LocalCronTest < Minitest::Test
  LocalCron = Quartermaster::LocalCron

  def utc(*parts) = Time.utc(2026, *parts)

  def test_a_winter_cron_fires_at_local_time_one_hour_after_utc
    assert LocalCron.due?("0 8 * * *", since: utc(1, 15, 6), now: utc(1, 15, 7))
    refute LocalCron.due?("0 8 * * *", since: utc(1, 15, 6), now: utc(1, 15, 6, 59))
    assert_equal utc(1, 15, 7), LocalCron.new("0 8 * * *").last_due(since: utc(1, 15, 6), now: utc(1, 15, 7, 3))
  end

  def test_a_summer_cron_fires_two_hours_after_utc
    assert_equal utc(7, 15, 6), LocalCron.new("0 8 * * *").last_due(since: utc(7, 15, 5), now: utc(7, 15, 6, 30))
    refute LocalCron.due?("0 8 * * *", since: utc(7, 15, 6), now: utc(7, 15, 6, 59))
  end

  def test_missed_minutes_coalesce_into_one_and_since_is_exclusive
    cron = LocalCron.new("*/15 * * * *")
    assert_equal utc(1, 15, 8), cron.last_due(since: utc(1, 15, 7, 1), now: utc(1, 15, 8, 0, 30))
    refute cron.last_due(since: utc(1, 15, 7), now: utc(1, 15, 7, 14))
    assert_equal utc(1, 15, 7, 15), cron.last_due(since: utc(1, 15, 7), now: utc(1, 15, 7, 15))
  end

  def test_times_in_another_zone_mean_the_same_instant
    assert LocalCron.due?("0 8 * * *", since: Time.new(2026, 1, 15, 7, 30, 0, "+01:00"), now: Time.new(2026, 1, 15, 8, 0, 0, "+01:00"))
  end

  def test_range_with_step
    cron = LocalCron.new("10-20/5 9 * * *")
    assert_equal utc(1, 15, 8, 15), cron.next_after(utc(1, 15, 8, 10))
    assert_equal utc(1, 15, 8, 20), cron.next_after(utc(1, 15, 8, 15))
    assert_equal utc(1, 16, 8, 10), cron.next_after(utc(1, 15, 8, 20))
  end

  def test_start_with_step_runs_to_the_end_of_the_field
    assert_equal utc(1, 15, 8, 50), LocalCron.next_after("50/5 9 * * *", utc(1, 15, 8, 30))
    assert_equal utc(1, 15, 8, 55), LocalCron.next_after("50/5 9 * * *", utc(1, 15, 8, 50))
  end

  def test_lists_and_weekday_ranges
    cron = LocalCron.new("0 9,17 * * 1-5")
    assert_equal utc(1, 15, 16), cron.next_after(utc(1, 15, 8))
    assert_equal utc(1, 19, 8), cron.next_after(utc(1, 16, 16)), "Friday 17:00 is followed by Monday 09:00"
  end

  def test_weekday_seven_is_sunday
    assert_equal utc(1, 18, 8), LocalCron.next_after("0 9 * * 7", utc(1, 15))
    assert_equal utc(1, 18, 8), LocalCron.next_after("0 9 * * 0", utc(1, 15))
    assert_equal utc(1, 17, 8), LocalCron.next_after("0 9 * * 6-7", utc(1, 15))
  end

  def test_day_of_month_or_weekday_when_both_are_restricted
    cron = LocalCron.new("0 9 1 * 1")
    assert_equal utc(1, 19, 8), cron.next_after(utc(1, 15)), "a Monday"
    assert_equal utc(2, 1, 8), cron.next_after(utc(1, 26, 9)), "the 1st, a Sunday"
  end

  def test_day_of_month_and_weekday_when_one_starts_with_a_star
    cron = LocalCron.new("0 9 */2 * 1")
    assert_equal utc(1, 19, 8), cron.next_after(utc(1, 15)), "Monday the 19th is odd"
    assert_equal utc(2, 9, 8), cron.next_after(utc(1, 20)), "the 26th and 2nd are even"
  end

  def test_months
    assert_equal utc(3, 1, 8), LocalCron.next_after("0 9 1 3,9 *", utc(1, 15))
  end

  def test_a_minute_in_the_spring_forward_gap_never_happens
    cron = LocalCron.new("30 2 * * *")
    assert_equal utc(3, 28, 1, 30), cron.next_after(utc(3, 28))
    assert_equal utc(3, 30, 0, 30), cron.next_after(utc(3, 28, 1, 30)), "March 29 has no 02:30"
    refute cron.last_due(since: utc(3, 28, 23), now: utc(3, 29, 23))
    assert_equal utc(3, 29, 1), LocalCron.next_after("0 3 * * *", utc(3, 28, 23)), "03:00 CEST"
  end

  def test_a_minute_in_the_fall_back_hour_happens_twice
    cron = LocalCron.new("30 2 * * *")
    assert_equal utc(10, 25, 0, 30), cron.next_after(utc(10, 25)), "02:30 CEST"
    assert_equal utc(10, 25, 1, 30), cron.next_after(utc(10, 25, 0, 30)), "02:30 CET"
    assert_equal utc(10, 26, 1, 30), cron.next_after(utc(10, 25, 1, 30))
    assert_equal utc(10, 25, 1, 30), cron.last_due(since: utc(10, 25), now: utc(10, 25, 2))
    assert cron.last_due(since: utc(10, 25), now: utc(10, 25, 0, 45))
    assert cron.last_due(since: utc(10, 25, 0, 45), now: utc(10, 25, 1, 45))
  end

  def test_fall_back_minutes_of_both_passes_keep_time_order
    cron = LocalCron.new("0,30 2 * * *")
    assert_equal utc(10, 25, 0, 30), cron.next_after(utc(10, 25, 0, 10)), "02:30 CEST comes before 02:00 CET"
    assert_equal utc(10, 25, 1), cron.last_due(since: utc(10, 25, 0, 45), now: utc(10, 25, 1, 10)), "02:00 CET"
  end

  def test_lookback_is_capped_at_eight_days
    refute LocalCron.due?("0 9 1 1 *", since: utc(1, 1, 7), now: utc(1, 15)), "Jan 1 is more than 8 days back"
    assert LocalCron.due?("0 9 1 1 *", since: utc(1, 1, 7), now: utc(1, 5))
  end

  def test_rare_and_impossible_dates
    assert_equal Time.utc(2028, 2, 28, 23), LocalCron.next_after("0 0 29 2 *", utc(1, 15))
    assert_nil LocalCron.next_after("0 0 31 2 *", utc(1, 15))
  end

  def test_errors_name_the_problem
    assert_nil LocalCron.error("*/15 9-17 1,15 * 1-5")
    assert_equal 'a cron has five fields (minute hour day month weekday), got "* * * *"', LocalCron.error("* * * *")
    assert_equal 'minute: "60" is outside 0-59', LocalCron.error("60 * * * *")
    assert_equal 'weekday: "8" is outside 0-7', LocalCron.error("0 9 * * 8")
    assert_equal 'day: "0" is outside 1-31', LocalCron.error("0 9 0 * *")
    assert_equal 'hour: "*/0" has a zero step', LocalCron.error("0 */0 * * *")
    assert_equal 'hour: "17-9" runs backwards', LocalCron.error("0 17-9 * * *")
    assert_equal %(weekday: "MON" isn't a number, range, list or step), LocalCron.error("0 9 * * MON")
    assert_equal %(minute: "" isn't a number, range, list or step), LocalCron.error("1, 9 * * *")
    assert_raises(ArgumentError) { LocalCron.due?("bad", since: utc(1, 1), now: utc(1, 2)) }
  end

  def test_label_and_picker_fields
    assert_equal "Mon, Thu 08:00", LocalCron.label("0 8 * * 1,4")
    assert_equal "Sun 08:05", LocalCron.label("5 8 * * 7")
    assert_equal "every day 08:00", LocalCron.label("0 8 * * *")
    assert_equal "every day 08:00", LocalCron.label("0 8 * * 0-7")
    assert_equal "*/15 * * * * Amsterdam time", LocalCron.label("*/15 * * * *")
    simple = LocalCron.new("5 8 * * 1,4")
    assert_equal [[1, 4], "08:05"], [simple.days, simple.time]
    assert_nil LocalCron.new("0 8 1 * *").time
  end

  def test_to_cron_writes_local_time_unshifted
    assert_equal "5 8 * * 1,4", LocalCron.to_cron(days: %w[4 1], time: "08:05")
    assert_equal "0 23 * * *", LocalCron.to_cron(days: (0..6).to_a, time: "23:00")
    assert_raises(ArgumentError) { LocalCron.to_cron(days: [], time: "08:00") }
  end
end
