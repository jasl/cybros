module DAG
  # Raised when user/business input validation fails for DAG operations
  # (invalid arguments, illegal state transitions, etc.).
  class ValidationError < Error
    attr_reader :code, :details

    def initialize(message = nil, code: nil, details: {})
      @code = code&.to_s
      @details = details || {}
      super(message)
    end

    def self.raise!(message = nil, code:, details: {})
      raise new(message, code: code.to_s, details: details || {})
    end
  end
end
