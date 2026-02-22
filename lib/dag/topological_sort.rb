module DAG
  class TopologicalSort
    class CycleError < DAG::Error; end

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

      available = MinHeap.new
      @node_ids.each do |node_id|
        available.push(node_id) if indegree[node_id].zero?
      end
      result = []

      while (node_id = available.pop)
        result << node_id

        outgoing[node_id].each do |child_id|
          indegree[child_id] -= 1
          available.push(child_id) if indegree[child_id].zero?
        end
      end

      if result.length != @node_ids.length
        raise CycleError, "cycle detected during topological sort"
      end

      result
    end

    private

      class MinHeap
        def initialize
          @data = []
        end

        def push(value)
          @data << value
          sift_up(@data.length - 1)
        end

        def pop
          return nil if @data.empty?

          min = @data.first
          last = @data.pop
          unless @data.empty?
            @data[0] = last
            sift_down(0)
          end

          min
        end

        private

          def sift_up(index)
            while index.positive?
              parent = (index - 1) / 2
              break if @data[parent] <= @data[index]

              @data[parent], @data[index] = @data[index], @data[parent]
              index = parent
            end
          end

          def sift_down(index)
            length = @data.length

            loop do
              left = (index * 2) + 1
              right = left + 1
              smallest = index

              if left < length && @data[left] < @data[smallest]
                smallest = left
              end

              if right < length && @data[right] < @data[smallest]
                smallest = right
              end

              break if smallest == index

              @data[smallest], @data[index] = @data[index], @data[smallest]
              index = smallest
            end
          end
      end
  end
end
