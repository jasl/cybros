module DAG
  class ExecutionResult
    attr_reader :state, :content, :payload, :metadata, :usage, :error, :reason, :retry_at

    def self.finished(content: nil, payload: nil, metadata: {}, usage: nil, streamed_output: false)
      new(
        state: DAG::Node::FINISHED,
        content: content,
        payload: payload,
        metadata: metadata,
        usage: usage,
        streamed_output: streamed_output
      )
    end

    def self.finished_streamed(metadata: {}, usage: nil)
      finished(metadata: metadata, usage: usage, streamed_output: true)
    end

    def self.errored(error:, metadata: {}, usage: nil)
      new(state: DAG::Node::ERRORED, error: error, metadata: metadata, usage: usage)
    end

    def self.pending(reason:, retry_at:, metadata: {}, usage: nil)
      new(state: DAG::Node::PENDING, reason: reason, retry_at: retry_at, metadata: metadata, usage: usage)
    end

    def self.rejected(reason:, metadata: {}, usage: nil)
      new(state: DAG::Node::REJECTED, reason: reason, metadata: metadata, usage: usage)
    end

    def self.skipped(reason: nil, metadata: {}, usage: nil)
      new(state: DAG::Node::SKIPPED, reason: reason, metadata: metadata, usage: usage)
    end

    def self.stopped(reason: nil, metadata: {}, usage: nil)
      new(state: DAG::Node::STOPPED, reason: reason, metadata: metadata, usage: usage)
    end

    def initialize(state:, content: nil, payload: nil, metadata: {}, usage: nil, error: nil, reason: nil, retry_at: nil, streamed_output: false)
      @state = state
      @content = content
      @payload = payload
      @metadata = metadata
      @usage = usage
      @error = error
      @reason = reason
      @retry_at = retry_at
      @streamed_output = streamed_output == true
    end

    def streamed_output?
      @streamed_output
    end
  end
end
