require "json"

module AgentCore
  module Resources
    module Memory
      class PgvectorStore < Base
        MAX_LIMIT = 1000

        def initialize(embedder:, conversation_id: nil, include_global: true)
          @embedder = embedder
          @conversation_id = conversation_id
          @include_global = include_global == true
        end

        def search(query:, limit: 5, metadata_filter: nil)
          raw_limit = limit
          limit = Integer(raw_limit, exception: false)
          ValidationError.raise!(
            "limit must be an Integer",
            code: "agent_core.memory.pgvector_store.limit_must_be_an_integer",
            details: { value_class: raw_limit.class.name },
          ) unless limit
          ValidationError.raise!(
            "limit must be > 0",
            code: "agent_core.memory.pgvector_store.limit_must_be_positive",
            details: { limit: limit },
          ) if limit <= 0
          limit = [limit, MAX_LIMIT].min

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
          ValidationError.raise!(
            "content is required",
            code: "agent_core.memory.pgvector_store.content_is_required",
          ) if text.strip.empty?

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
          raw_id = id
          id = raw_id.to_s.strip
          ValidationError.raise!(
            "id is required",
            code: "agent_core.memory.pgvector_store.id_is_required",
          ) if id.empty?
          ValidationError.raise!(
            "id must be a UUID",
            code: "agent_core.memory.pgvector_store.id_must_be_a_uuid",
            details: { id: id },
          ) unless AgentCore::Utils.uuid_like?(id)

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
