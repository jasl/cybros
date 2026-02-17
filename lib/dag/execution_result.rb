module DAG
  class ExecutionResult
    attr_reader :state, :content, :payload, :metadata, :error, :reason

    def self.finished(content: nil, payload: nil, metadata: {})
      new(state: DAG::Node::FINISHED, content: content, payload: payload, metadata: metadata)
    end

    def self.errored(error:, metadata: {})
      new(state: DAG::Node::ERRORED, error: error, metadata: metadata)
    end

    def self.rejected(reason:, metadata: {})
      new(state: DAG::Node::REJECTED, reason: reason, metadata: metadata)
    end

    def self.skipped(reason: nil, metadata: {})
      new(state: DAG::Node::SKIPPED, reason: reason, metadata: metadata)
    end

    def self.cancelled(reason: nil, metadata: {})
      new(state: DAG::Node::CANCELLED, reason: reason, metadata: metadata)
    end

    def initialize(state:, content: nil, payload: nil, metadata: {}, error: nil, reason: nil)
      @state = state
      @content = content
      @payload = payload
      @metadata = metadata
      @error = error
      @reason = reason
    end
  end
end
