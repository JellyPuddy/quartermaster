# frozen_string_literal: true

module Quartermaster
  # A local automation's 5-field cron, read as wall-clock time in Europe/Amsterdam (LocalSchedule's
  # built-in EU DST rule, no ENV["TZ"]). Each field takes `*`, numbers, lists, ranges and steps
  # (`*/n`, `a-b/n`, `a/n`); weekday is 0-7 with 7 = Sunday. When day-of-month and weekday both
  # start with something other than `*`, a day matches either; otherwise both must match.
  # A wall-clock minute in the spring-forward gap never happens; one in the fall-back hour
  # happens twice (two UTC instants).
  class LocalCron
    FIELDS = [["minute", 0, 59], ["hour", 0, 23], ["day", 1, 31], ["month", 1, 12], ["weekday", 0, 7]].freeze
    STAR_MAX = { "weekday" => 6 }.freeze
    LOOKBACK_DAYS = 8
    LOOKAHEAD_DAYS = 366 * 9
    PART = %r{\A(?:(\*)|(\d+)(?:-(\d+))?)(?:/(\d+))?\z}

    attr_reader :cron

    # True when a scheduled minute lies in (since, now]; any number of them counts as one.
    def self.due?(cron, since:, now:) = !new(cron).last_due(since: since, now: now).nil?

    def self.next_after(cron, time) = new(cron).next_after(time)

    def self.label(cron) = new(cron).label

    # nil for a valid cron, else what is wrong with it.
    def self.error(cron)
      new(cron)
      nil
    rescue ArgumentError => e
      e.message
    end

    # Weekdays (0 = Sunday) and a local "HH:MM" as a local cron: no UTC shift.
    def self.to_cron(days:, time:)
      match = LocalSchedule::TIME.match(time.to_s) or raise ArgumentError, "time must be HH:MM, got #{time.inspect}"
      days = days.map { Integer(_1) }.uniq.sort
      raise ArgumentError, "pick at least one weekday" if days.empty?
      raise ArgumentError, "weekdays are 0 (Sunday) to 6" unless days.all? { LocalSchedule::ALL_DAYS.include?(_1) }

      "#{match[2].to_i} #{match[1].to_i} * * #{days.size == 7 ? '*' : days.join(',')}"
    end

    def initialize(cron)
      @cron = cron.to_s.strip
      parts = @cron.split
      unless parts.size == 5
        raise ArgumentError, "a cron has five fields (minute hour day month weekday), got #{@cron.inspect}"
      end

      @minutes, @hours, @days, @months, weekdays = FIELDS.zip(parts).map { |(name, min, max), text| values(name, text, min, max) }
      @weekdays = weekdays.map { _1 % 7 }.uniq.sort
      @either_day = !parts[2].start_with?("*") && !parts[4].start_with?("*")
      @simple = parts[0].match?(/\A\d+\z/) && parts[1].match?(/\A\d+\z/) && parts[2] == "*" && parts[3] == "*"
    end

    # The latest scheduled minute (a UTC Time) in (since, now], or nil. A `since` older than
    # LOOKBACK_DAYS before `now` counts from then.
    def last_due(since:, now:)
      now = minute_floor(now.getutc)
      since = [since.getutc, now - LOOKBACK_DAYS * 86_400].max
      return nil unless since < now

      day = local(now).to_date
      first = local(since).to_date
      while day >= first
        instants(day).reverse_each do |at|
          return at if at <= now && at > since
          break if at <= since
        end
        day -= 1
      end
      nil
    end

    # The first scheduled minute (a UTC Time) after `time`, or nil when none comes in nine years.
    def next_after(time)
      time = time.getutc
      day = local(time).to_date
      LOOKAHEAD_DAYS.times do
        found = instants(day).find { _1 > time }
        return found if found

        day += 1
      end
      nil
    end

    def simple? = @simple

    # Local weekdays (0 = Sunday) and "HH:MM" of a simple cron ("M H * * <weekdays>"), else nil.
    def days = (@weekdays if simple?)

    def time = (format("%02d:%02d", @hours.first, @minutes.first) if simple?)

    # "Mon, Thu 08:00", "every day 08:00", or the cron itself marked as Amsterdam time.
    def label
      return "#{@cron} Amsterdam time" unless simple?
      return "every day #{time}" if @weekdays.size == 7

      "#{LocalSchedule::LABEL_ORDER.select { @weekdays.include?(_1) }.map { LocalSchedule::DAY_NAMES[_1] }.join(', ')} #{time}"
    end

    private

    def values(name, text, min, max)
      text.split(",", -1).flat_map do |part|
        match = PART.match(part) or raise ArgumentError, "#{name}: #{part.inspect} isn't a number, range, list or step"
        star, from, to, step = match.captures
        from = from ? Integer(from, 10) : min
        to = to ? Integer(to, 10) : (star || step ? STAR_MAX.fetch(name, max) : from)
        step = step ? Integer(step, 10) : 1
        raise ArgumentError, "#{name}: #{part.inspect} is outside #{min}-#{max}" unless from.between?(min, max) && to.between?(min, max)
        raise ArgumentError, "#{name}: #{part.inspect} runs backwards" if from > to
        raise ArgumentError, "#{name}: #{part.inspect} has a zero step" if step.zero?

        from.step(to, step).to_a
      end.uniq.sort
    end

    def day_matches?(date)
      return false unless @months.include?(date.month)

      by_dom = @days.include?(date.day)
      by_dow = @weekdays.include?(date.wday)
      @either_day ? by_dom || by_dow : by_dom && by_dow
    end

    # Every UTC instant on local `date` that the cron schedules, oldest first.
    def instants(date)
      return [] unless day_matches?(date)

      @hours.flat_map do |hour|
        @minutes.flat_map { |minute| at_wall_clock(Time.utc(date.year, date.month, date.day, hour, minute)) }
      end.sort
    end

    # The UTC instants whose Amsterdam wall clock reads `wall` (a Time in UTC standing for it):
    # none in the spring-forward gap, two in the fall-back hour.
    def at_wall_clock(wall) = [wall - 7200, wall - 3600].select { local(_1) == wall }

    def local(utc) = utc + LocalSchedule.offset_minutes(utc) * 60

    def minute_floor(time) = time - time.sec - time.subsec
  end
end
