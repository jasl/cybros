module AgentCore
  module RuntimeSurface
    class Base
      def prepare_turn(input:)
        _ = input
        Decisions::Pass.new
      end

      def compact_context(input:)
        _ = input
        Decisions::Pass.new
      end

      def review_tool_call(input:)
        _ = input
        Decisions::Pass.new
      end

      def project_tool_result(input:)
        _ = input
        Decisions::Pass.new
      end

      def finalize_output(input:)
        _ = input
        Decisions::Pass.new
      end

      def handle_error(input:)
        _ = input
        Decisions::Pass.new
      end
    end
  end
end
