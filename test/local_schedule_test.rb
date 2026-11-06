# frozen_string_literal: true

require_relative "test_helper"

# Expected values are worked by hand: Amsterdam is UTC+1 in winter and UTC+2 from the last Sunday
# of March 01:00 UTC to the last Sunday of October 01:00 UTC (in 2026: March 29 and October 25).
class LocalScheduleTest < Minitest::Test
  WINTER = Date.new(2026, 1, 15)
  SUMMER = Date.new(2026, 7, 15)

  def schedule(cron, on) = Quartermaster::LocalSchedule.from_cron(cron, on: on)

  def test_winter_shows_the_utc_cron_one_hour_later
    s = schedule("0 7 * * 1,4", WINTER)
    refute s.raw?
    assert_equal [1, 4], s.days
    assert_equal "08:00", s.time
    assert_equal "Mon, Thu 08:00", s.label
  end

  def test_summer_shows_the_same_cron_two_hours_later
    s = schedule("0 7 * * 1,4", SUMMER)
    assert_equal [1, 4], s.days
    assert_equal "09:00", s.time
    assert_equal "Mon, Thu 09:00", s.label
  end

  def test_every_day_reads_as_every_day
    assert_equal "every day 08:00", schedule("0 7 * * *", WINTER).label
    assert_equal "every day 08:05", schedule("5 7 * * 0-6", WINTER).label
    assert_equal "0 7 * * *", Quartermaster::LocalSchedule.to_cron(days: [0, 1, 2, 3, 4, 5, 6], time: "08:00", on: WINTER)
  end

  def test_a_late_utc_time_lands_on_the_next_local_day
    s = schedule("30 23 * * 0,6", WINTER)
    assert_equal [0, 1], s.days
    assert_equal "00:30", s.time
    assert_equal "Mon, Sun 00:30", s.label
    assert_equal [0, 1], schedule("30 22 * * 0,6", SUMMER).days
    assert_equal [6], schedule("30 22 * * 6", WINTER).days
  end

  def test_sunday_may_be_written_as_seven_and_ranges_expand
    assert_equal [1, 2, 3, 4, 5], schedule("0 7 * * 1-5", WINTER).days
    assert_equal [0], schedule("0 7 * * 7", WINTER).days
  end

  def test_local_time_becomes_a_utc_cron_for_the_current_offset
    assert_equal "0 7 * * 1,4", Quartermaster::LocalSchedule.to_cron(days: [1, 4], time: "08:00", on: WINTER)
    assert_equal "0 6 * * 1,4", Quartermaster::LocalSchedule.to_cron(days: [4, 1], time: "08:00", on: SUMMER)
  end

  def test_a_local_time_near_midnight_shifts_the_utc_weekday_back
    assert_equal "30 23 * * 0", Quartermaster::LocalSchedule.to_cron(days: [1], time: "00:30", on: WINTER)
    assert_equal "30 23 * * 0", Quartermaster::LocalSchedule.to_cron(days: [1], time: "01:30", on: SUMMER)
    assert_equal "0 22 * * 0,6", Quartermaster::LocalSchedule.to_cron(days: [0, 1], time: "00:00", on: SUMMER)
  end

  def test_round_trip_keeps_the_cron
    ["0 7 * * 1,4", "30 23 * * 0", "15 22 * * 6", "0 0 * * 1-5", "59 23 * * *"].each do |cron|
      [WINTER, SUMMER].each do |on|
        s = schedule(cron, on)
        back = Quartermaster::LocalSchedule.to_cron(days: s.days, time: s.time, on: on)
        assert_equal schedule(back, on).days, s.days, "#{cron} on #{on}"
        assert_equal schedule(back, on).time, s.time, "#{cron} on #{on}"
      end
    end
  end

  def test_the_offset_switches_at_one_utc_on_the_last_sundays
    before = Time.utc(2026, 3, 29, 0, 59)
    after = Time.utc(2026, 3, 29, 1, 0)
    assert_equal "08:00", schedule("0 7 * * 1", before).time
    assert_equal "09:00", schedule("0 7 * * 1", after).time
    assert_equal "09:00", schedule("0 7 * * 1", Time.utc(2026, 10, 25, 0, 59)).time
    assert_equal "08:00", schedule("0 7 * * 1", Time.utc(2026, 10, 25, 1, 0)).time
  end

  def test_crons_the_picker_cannot_express_stay_raw
    ["*/15 * * * *", "0 7 1 * *", "0 7 * 6 *", "0 7,19 * * *", "0 */2 * * 1", "0 7 * * MON",
     "0 7 * * 8", "60 7 * * *", "0 24 * * *", "0 7 * *", "nope", ""].each do |cron|
      s = schedule(cron, WINTER)
      assert s.raw?, cron
      assert_nil s.days, cron
      assert_nil s.time, cron
      assert_equal "#{cron} UTC".strip, s.label, cron
    end
  end

  def test_the_cron_stays_as_given
    assert_equal "0 7 * * 1,4", schedule("0 7 * * 1,4", SUMMER).cron
  end

  def test_rejects_a_picker_value_it_cannot_turn_into_a_cron
    assert_raises(ArgumentError) { Quartermaster::LocalSchedule.to_cron(days: [], time: "08:00", on: WINTER) }
    assert_raises(ArgumentError) { Quartermaster::LocalSchedule.to_cron(days: [1], time: "8am", on: WINTER) }
    assert_raises(ArgumentError) { Quartermaster::LocalSchedule.to_cron(days: [1], time: "24:00", on: WINTER) }
    assert_raises(ArgumentError) { Quartermaster::LocalSchedule.to_cron(days: [7], time: "08:00", on: WINTER) }
  end
end
