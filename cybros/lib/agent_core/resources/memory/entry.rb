# frozen_string_literal: true

module AgentCore
  module Resources
    module Memory
      # A single memory entry.
      class Entry
        attr_reader :id, :content, :metadata, :score

        # @param id [String] Unique identifier
        # @param content [String] The remembered content
        # @param metadata [Hash] Associated metadata
        # @param score [Float, nil] Relevance score (from search)
        def initialize(id:, content:, metadata: {}, score: nil)
          @id = id
          @content = content
          @metadata = metadata.freeze
          @score = score
        end

        def to_h
          h = { id: id, content: content, metadata: metadata }
          h[:score] = score if score
          h
        end
      end
    end
  end
end
