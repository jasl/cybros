module System
  module Settings
    class RuntimeGovernanceController < BaseController
      def show
        @observability = RuntimeGovernance::ObservabilityFeed.build
      end
    end
  end
end
