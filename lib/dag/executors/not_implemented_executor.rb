module DAG
  module Executors
    class NotImplementedExecutor
      def execute(node:, context:, stream:)
        _ = context
        _ = stream

        DAG::ExecutionResult.errored(
          error: "No executor registered for node_type=#{node.node_type}"
        )
      end
    end
  end
end
