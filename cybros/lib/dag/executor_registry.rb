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

    def context_mode_for(node)
      executor = executor_for(node)
      mode =
        if executor.respond_to?(:context_mode_for)
          executor.context_mode_for(node)
        elsif executor.respond_to?(:context_mode)
          executor.context_mode
        end

      case mode.to_s.strip.downcase.to_sym
      when :full
        :full
      else
        :preview
      end
    rescue StandardError
      :preview
    end

    def execute(node:, context:, stream:)
      executor_for(node).execute(node: node, context: context, stream: stream)
    end
  end

  class << self
    attr_accessor :executor_registry
  end

  self.executor_registry = ExecutorRegistry.new
end
