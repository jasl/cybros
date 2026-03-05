module DAG
  # GraphPolicy is a per-graph, injectable defense-in-depth layer for gating
  # user-semantic operations (fork/rerun/adopt/edit/visibility changes) without
  # blocking the engine's own automation and maintenance routines.
  #
  # Policy is injected via `DAG::Graph#attachable`:
  # - If `attachable.respond_to?(:dag_graph_policy)`, the return value is used.
  # - Otherwise, the graph falls back to ALLOW_ALL.
  class GraphPolicy
    def assert_allowed!(operation:, graph:, subject: nil, details: {})
      _ = operation
      _ = graph
      _ = subject
      _ = details
      true
    end

    protected

      def deny!(message, code:, details: {})
        DAG::OperationNotAllowedError.raise!(message, code: code, details: details)
      end

    class AllowAll < GraphPolicy
      def assert_allowed!(operation:, graph:, subject: nil, details: {})
        _ = operation
        _ = graph
        _ = subject
        _ = details
        true
      end
    end

    ALLOW_ALL = AllowAll.new.freeze
  end
end
