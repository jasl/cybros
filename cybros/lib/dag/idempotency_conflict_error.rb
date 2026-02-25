# frozen_string_literal: true

module DAG
  # Raised when an idempotency key collides with an existing record, but the
  # expected and actual values do not match (lane/state/body input-output).
  class IdempotencyConflictError < ValidationError; end
end
