# frozen_string_literal: true

module Quartermaster
  # A routine's UTC cron read as weekdays plus a local time in Europe/Amsterdam, and back. Only
  # "M H * * <weekdays or *>" with one minute and one hour converts; any other cron is `raw?` and
  # shows and edits as itself. The offset is the one in force at the reference moment `on:`, so a
  # stored cron keeps its UTC time across a DST change (no rewrites): 0 7 UTC reads 08:00 in winter
  # and 09:00 in summer. The EU DST rule is built in.
  class LocalSchedule
    DAY_NAMES = %w[Sun Mon Tue Wed Thu Fri Sat].freeze
    LABEL_ORDER = [1, 2, 3, 4, 5, 6, 0].freeze
    ALL_DAYS = (0..6).to_a.freeze
    DAY_MINUTES = 24 * 60
    TIME = /\A([01]\d|2[0-3]):([0-5]\d)\z/

    attr_reader :cron, :days, :time

    def self.from_cron(cron, on: Time.now) = new(cron.to_s, on)

    # Weekdays (0 = Sunday) and a local "HH:MM" as the UTC cron for the offset at `on:`; a local
    # time the offset pushes past midnight moves its weekdays back a day.
    def self.to_cron(days:, time:, on: Time.now)
      match = TIME.match(time.to_s) or raise ArgumentError, "time must be HH:MM, got #{time.inspect}"
      days = days.map { Integer(_1) }.uniq.sort
      raise ArgumentError, "pick at least one weekday" if days.empty?
      raise ArgumentError, "weekdays are 0 (Sunday) to 6" unless days.all? { ALL_DAYS.include?(_1) }

      shift, minutes = (match[1].to_i * 60 + match[2].to_i - offset_minutes(on)).divmod(DAY_MINUTES)
      dow = days.size == 7 ? "*" : days.map { (_1 + shift) % 7 }.sort.join(",")
      "#{minutes % 60} #{minutes / 60} * * #{dow}"
    end

    # Minutes east of UTC in Amsterdam at `on` (a Time, or a Date read at noon UTC): CEST from the
    # last Sunday of March 01:00 UTC to the last Sunday of October 01:00 UTC, else CET.
    def self.offset_minutes(on)
      at = on.is_a?(Time) ? on.getutc : Time.utc(on.year, on.month, on.day, 12)
      summer = switch_moment(at.year, 3) <= at && at < switch_moment(at.year, 10)
      summer ? 120 : 60
    end

    def self.switch_moment(year, month)
      last = Date.new(year, month, -1)
      sunday = last - last.wday
      Time.utc(sunday.year, sunday.month, sunday.day, 1)
    end

    def initialize(cron, on)
      @cron = cron.strip
      fields = @cron.split
      return unless fields.size == 5 && fields[2] == "*" && fields[3] == "*"

      minute = single(fields[0], 59)
      hour = single(fields[1], 23)
      utc_days = weekdays(fields[4])
      return unless minute && hour && utc_days

      shift, local = (hour * 60 + minute + self.class.offset_minutes(on)).divmod(DAY_MINUTES)
      @days = utc_days.map { (_1 + shift) % 7 }.uniq.sort
      @time = format("%02d:%02d", local / 60, local % 60)
    end

    def raw? = @days.nil?

    def every_day? = !raw? && @days.size == 7

    # "Mon, Thu 08:00", "every day 08:00", or the raw cron marked as UTC.
    def label
      return "#{@cron} UTC".strip if raw?
      return "every day #{@time}" if every_day?

      "#{LABEL_ORDER.select { @days.include?(_1) }.map { DAY_NAMES[_1] }.join(', ')} #{@time}"
    end

    private

    def single(field, max)
      return unless field.match?(/\A\d{1,2}\z/)

      value = field.to_i
      value if value <= max
    end

    def weekdays(field)
      return ALL_DAYS if field == "*"

      days = field.split(",", -1).map do |part|
        bounds = part.match(/\A([0-7])(?:-([0-7]))?\z/) or return nil
        from, to = bounds[1].to_i, (bounds[2] || bounds[1]).to_i
        return nil if from > to

        (from..to).to_a
      end
      days.flatten.map { _1 % 7 }.uniq.sort
    end
  end
end
