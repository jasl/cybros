module DAG
  # Raised when a requested mutation is not allowed due to the current graph/node
  # state or invariants (e.g. cannot retry, can only rerun leaf nodes, etc.).
  class OperationNotAllowedError < ValidationError; end
end
