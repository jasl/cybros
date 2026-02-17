module DAG
  class TopologicalSort
    class CycleError < StandardError; end

    def self.call(node_ids:, edges:)
      new(node_ids: node_ids, edges: edges).call
    end

    def initialize(node_ids:, edges:)
      @node_ids = node_ids.sort
      @edges = edges
    end

    def call
      indegree = Hash.new(0)
      outgoing = Hash.new { |hash, key| hash[key] = [] }

      @node_ids.each do |node_id|
        indegree[node_id] = 0
      end

      @edges.each do |edge|
        from = edge.fetch(:from)
        to = edge.fetch(:to)
        next unless indegree.key?(from) && indegree.key?(to)

        outgoing[from] << to
        indegree[to] += 1
      end

      outgoing.each_value(&:sort!)

      available = @node_ids.select { |node_id| indegree[node_id].zero? }
      result = []

      while available.any?
        node_id = available.shift
        result << node_id

        outgoing[node_id].each do |child_id|
          indegree[child_id] -= 1
          if indegree[child_id].zero?
            insert_sorted(available, child_id)
          end
        end
      end

      if result.length != @node_ids.length
        raise CycleError, "cycle detected during topological sort"
      end

      result
    end

    private

      def insert_sorted(array, value)
        index = array.bsearch_index { |existing| existing >= value } || array.length
        array.insert(index, value)
      end
  end
end
