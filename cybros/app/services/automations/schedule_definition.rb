module Automations
  class ScheduleDefinition
    WEEKDAY_CODES = {
      0 => "SU",
      1 => "MO",
      2 => "TU",
      3 => "WE",
      4 => "TH",
      5 => "FR",
      6 => "SA",
    }.freeze
    SUPPORTED_FREQUENCIES = %w[DAILY HOURLY WEEKLY].freeze
    SUPPORTED_WEEKDAY_CODES = WEEKDAY_CODES.values.freeze
    SUPPORTED_KEYS_BY_FREQUENCY = {
      "DAILY" => %w[FREQ BYHOUR BYMINUTE],
      "HOURLY" => %w[FREQ INTERVAL BYMINUTE BYDAY],
      "WEEKLY" => %w[FREQ BYDAY BYHOUR BYMINUTE],
    }.freeze

    def self.parse!(rrule:, timezone:)
      new(rrule: rrule, timezone: timezone)
    end

    def self.validate_rrule!(rrule)
      new(rrule: rrule, timezone: "UTC")
    end

    def initialize(rrule:, timezone:)
      @rule = parse_rule(rrule)
      @timezone = ActiveSupport::TimeZone[timezone.to_s]
      raise ArgumentError, "unsupported automation timezone #{timezone.inspect}" if @timezone.blank?
    end

    def scheduled_for(now)
      local_now = now.in_time_zone(timezone)

      case frequency
      when "DAILY"
        daily_occurrence(local_now)
      when "HOURLY"
        hourly_occurrence(local_now)
      when "WEEKLY"
        weekly_occurrence(local_now)
      else
        raise ArgumentError, "unsupported automation frequency #{frequency.inspect}"
      end
    end

    private

      attr_reader :rule, :timezone

      def parse_rule(rrule)
        parsed =
          rrule.to_s.split(";").each_with_object({}) do |segment, memo|
            key, value = segment.split("=", 2)
            next if key.blank? || value.blank?

            memo[key.upcase] = value
          end
        frequency = parsed["FREQ"].to_s.upcase
        raise ArgumentError, "unsupported automation frequency #{frequency.inspect}" unless SUPPORTED_FREQUENCIES.include?(frequency)

        validate_supported_keys!(parsed, frequency)
        validate_integer_field!(parsed, "INTERVAL", min: 1)
        validate_integer_field!(parsed, "BYHOUR", min: 0, max: 23)
        validate_integer_field!(parsed, "BYMINUTE", min: 0, max: 59)
        validate_weekdays!(parsed["BYDAY"]) if parsed.key?("BYDAY")
        raise ArgumentError, "weekly automations require BYDAY" if frequency == "WEEKLY" && parsed["BYDAY"].blank?

        parsed
      end

      def validate_supported_keys!(parsed, frequency)
        unsupported = parsed.keys - SUPPORTED_KEYS_BY_FREQUENCY.fetch(frequency)
        return if unsupported.empty?

        raise ArgumentError, "unsupported automation rrule keys #{unsupported.join(",")}"
      end

      def validate_integer_field!(parsed, key, min:, max: nil)
        return unless parsed.key?(key)

        value = Integer(parsed[key], exception: false)
        raise ArgumentError, "invalid automation #{key.downcase}" if value.nil? || value < min
        raise ArgumentError, "invalid automation #{key.downcase}" if max && value > max
      end

      def validate_weekdays!(raw)
        codes =
          raw.to_s.split(",").filter_map do |code|
            normalized = code.to_s.strip.upcase
            normalized.presence
          end
        raise ArgumentError, "invalid automation byday" if codes.empty? || (codes - SUPPORTED_WEEKDAY_CODES).any?
      end

      def frequency
        rule.fetch("FREQ").upcase
      end

      def interval
        raw = rule["INTERVAL"].to_i
        raw.positive? ? raw : 1
      end

      def hour
        rule.fetch("BYHOUR", "0").to_i
      end

      def minute
        rule.fetch("BYMINUTE", "0").to_i
      end

      def weekday_codes
        rule.fetch("BYDAY", "").split(",").filter_map do |code|
          normalized = code.to_s.strip.upcase
          normalized.presence
        end
      end

      def within_window?(local_now, occurrence)
        local_now >= occurrence && local_now < occurrence + 1.minute
      end

      def local_occurrence_for_day(local_now)
        local_now.beginning_of_day.change(hour: hour, min: minute, sec: 0)
      end

      def daily_occurrence(local_now)
        occurrence = local_occurrence_for_day(local_now)
        occurrence.utc if within_window?(local_now, occurrence)
      end

      def hourly_occurrence(local_now)
        return unless weekday_codes.empty? || weekday_codes.include?(WEEKDAY_CODES.fetch(local_now.wday))
        return unless (local_now.hour % interval).zero?

        occurrence = local_now.beginning_of_hour.change(min: minute, sec: 0)
        occurrence.utc if within_window?(local_now, occurrence)
      end

      def weekly_occurrence(local_now)
        return unless weekday_codes.include?(WEEKDAY_CODES.fetch(local_now.wday))

        occurrence = local_occurrence_for_day(local_now)
        occurrence.utc if within_window?(local_now, occurrence)
      end
  end
end
