# frozen_string_literal: true

module DAG
  # Raised when pagination parameters are invalid (mutually exclusive cursors,
  # unknown/hidden cursors, non-positive limits, etc.).
  class PaginationError < ValidationError; end
end
