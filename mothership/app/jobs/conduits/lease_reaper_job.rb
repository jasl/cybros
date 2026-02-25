module Conduits
  class LeaseReaperJob < ApplicationJob
    queue_as :default

    def perform(limit: 200)
      Conduits::LeaseReaperService.new.call(limit: limit)
    end
  end
end
