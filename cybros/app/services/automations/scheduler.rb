module Automations
  class Scheduler
    def self.dispatch_due!(now: Time.current)
      new(now: now).dispatch_due!
    end

    def initialize(now:)
      @now = now
    end

    def dispatch_due!
      Automation.where(status: "active", schedule_kind: "rrule").order(:id).filter_map do |automation|
        scheduled_for = scheduled_for(automation)
        next if scheduled_for.blank?

        Automations::Dispatch.call!(
          automation: automation,
          scheduled_for: scheduled_for,
          dispatch_key: dispatch_key_for(automation, scheduled_for),
          trigger_snapshot: {
            "kind" => "schedule",
            "scheduled_for" => scheduled_for.iso8601,
          },
        )
      end
    end

    private

      attr_reader :now

      def dispatch_key_for(automation, scheduled_for)
        "#{automation.id}:#{scheduled_for.iso8601}"
      end

      def scheduled_for(automation)
        schedule = Automations::ScheduleDefinition.parse!(
          rrule: automation.schedule_rrule,
          timezone: automation.schedule_timezone,
        )
        schedule.scheduled_for(now)
      end
  end
end
