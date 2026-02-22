# frozen_string_literal: true

require "json"

module AgentCore
  module Resources
    module Memory
      class PgvectorStore < Base
        def initialize(embedder:, conversation_id: nil, include_global: true)
          @embedder = embedder
          @conversation_id = conversation_id
          @include_global = include_global == true
        end

        def search(query:, limit: 5, metadata_filter: nil)
          limit = Integer(limit)
          raise ValidationError, "limit must be > 0" if limit <= 0

          q = query.to_s.strip
          return [] if q.empty?

          vector = @embedder.embed(text: q)

          scope = base_scope(metadata_filter: metadata_filter)

          records =
            scope
              .nearest_neighbors(:embedding, vector, distance: "cosine")
              .limit(limit)
              .to_a

          records.map do |record|
            distance = record.attributes["neighbor_distance"]
            score = distance.is_a?(Numeric) ? (1.0 - distance.to_f) : nil

            Entry.new(
              id: record.id.to_s,
              content: record.content.to_s,
              metadata: record.metadata.is_a?(Hash) ? record.metadata : {},
              score: score,
            )
          end
        end

        def store(content:, metadata: {})
          text = content.to_s
          raise ValidationError, "content is required" if text.strip.empty?

          vector = @embedder.embed(text: text)

          record =
            ::AgentMemoryEntry.create!(
              conversation_id: @conversation_id,
              content: text,
              metadata: metadata.is_a?(Hash) ? metadata : {},
              embedding: vector,
            )

          Entry.new(id: record.id.to_s, content: record.content.to_s, metadata: record.metadata || {})
        end

        def forget(id:)
          deleted = ::AgentMemoryEntry.where(id: id).delete_all
          deleted.positive?
        end

        def all
          base_scope(metadata_filter: nil).order(:id).map do |record|
            Entry.new(id: record.id.to_s, content: record.content.to_s, metadata: record.metadata || {})
          end
        end

        def size
          base_scope(metadata_filter: nil).count
        end

        def clear
          base_scope(metadata_filter: nil).delete_all
          self
        end

        private

          def base_scope(metadata_filter:)
            scope = ::AgentMemoryEntry.all

            if @conversation_id
              if @include_global
                scope = scope.where(conversation_id: [@conversation_id, nil])
              else
                scope = scope.where(conversation_id: @conversation_id)
              end
            end

            filter = metadata_filter.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(metadata_filter) : nil
            if filter && !filter.empty?
              scope = scope.where("metadata @> ?", JSON.generate(filter))
            end

            scope
          end
      end
    end
  end
end
