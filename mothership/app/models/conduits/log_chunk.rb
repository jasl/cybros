module Conduits
  class LogChunk < ApplicationRecord
    self.table_name = "conduits_log_chunks"

    belongs_to :directive, class_name: "Conduits::Directive", inverse_of: :log_chunks

    validates :stream, presence: true, inclusion: { in: %w[stdout stderr] }
    validates :seq, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :bytes, presence: true
    validates :bytesize, presence: true, numericality: { greater_than_or_equal_to: 0 }
  end
end
