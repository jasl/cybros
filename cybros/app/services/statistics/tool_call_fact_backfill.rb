module Statistics
  class ToolCallFactBackfill
    DEFAULT_BATCH_SIZE = 500

    class << self
      def backfill!(scope: nil, batch_size: DEFAULT_BATCH_SIZE)
        new(scope: scope, batch_size: batch_size).backfill!
      end
    end

    def initialize(scope: nil, batch_size: DEFAULT_BATCH_SIZE)
      @scope = scope || default_scope
      @batch_size = batch_size.to_i.positive? ? batch_size.to_i : DEFAULT_BATCH_SIZE
    end

    def backfill!
      totals = {
        scanned: 0,
        projected: 0,
        skipped: 0,
      }

      scope.in_batches(of: batch_size) do |relation|
        relation.includes(:graph, :body).each do |task_node|
          totals[:scanned] += 1

          if Statistics::ToolCallFactProjector.project!(task_node)
            totals[:projected] += 1
          else
            totals[:skipped] += 1
          end
        end
      end

      totals
    end

    private

      attr_reader :scope, :batch_size

      def default_scope
        DAG::Node.where(node_type: Messages::Task.node_type_key).order(:id)
      end
  end
end
