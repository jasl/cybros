module AgentCore
  module RuntimeSurface
    module Errors
      class Error < AgentCore::Error; end

      class StageTimeout < Error
        attr_reader :stage, :timeout_s

        def initialize(stage:, timeout_s:)
          @stage = stage.to_sym
          @timeout_s = timeout_s
          super("runtime surface stage #{stage} timed out after #{timeout_s}s")
        end
      end

      class OutputLimitExceeded < Error
        attr_reader :stage, :max_output_bytes, :actual_output_bytes

        def initialize(stage:, max_output_bytes:, actual_output_bytes:)
          @stage = stage.to_sym
          @max_output_bytes = max_output_bytes
          @actual_output_bytes = actual_output_bytes
          super("runtime surface stage #{stage} exceeded output limit #{max_output_bytes} bytes")
        end
      end

      class InvalidDecision < Error
        attr_reader :stage, :decision_class

        def initialize(stage:, decision_class:)
          @stage = stage.to_sym
          @decision_class = decision_class
          super("runtime surface stage #{stage} returned invalid decision #{decision_class}")
        end
      end

      class HelperUnavailable < Error; end
    end
  end
end
