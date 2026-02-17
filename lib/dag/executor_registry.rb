module DAG
  class ExecutorRegistry
    def initialize(default_executor: DAG::Executors::NotImplementedExecutor.new)
      @executors = {}
      @default_executor = default_executor
    end

    def register(node_type, executor)
      @executors[node_type] = executor
    end

    def executor_for(node)
      @executors.fetch(node.node_type) { @default_executor }
    end

    def execute(node:, context:)
      executor_for(node).execute(node: node, context: context)
    end
  end

  class << self
    attr_accessor :executor_registry
  end

  self.executor_registry = ExecutorRegistry.new
end
