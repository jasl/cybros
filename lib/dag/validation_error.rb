# frozen_string_literal: true

module DAG
  # Raised when user/business input validation fails for DAG operations
  # (invalid arguments, illegal state transitions, etc.).
  class ValidationError < Error
    attr_reader :code, :details

    def initialize(message = nil, code: nil, details: {})
      @code = code
      @details = details || {}
      super(message)
    end
  end
end

