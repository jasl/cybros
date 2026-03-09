module Automations
  class DispatchDueJob < ApplicationJob
    queue_as :default

    def perform(now: nil)
      Automations::Scheduler.dispatch_due!(now: now || Time.current)
    end
  end
end
