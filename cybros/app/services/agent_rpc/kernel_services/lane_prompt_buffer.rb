module AgentRPC
  module KernelServices
    class LanePromptBuffer
      SEQ_STEP = 10

      def self.put!(draft:, buffer_name:, content:, kind: nil, priority: nil, metadata: nil)
        new(draft: draft).put!(buffer_name: buffer_name, content: content, kind: kind, priority: priority, metadata: metadata)
      end

      def self.get(draft:, entry_id:)
        new(draft: draft).get(entry_id: entry_id)
      end

      def self.list(draft:, buffer_name: nil)
        new(draft: draft).list(buffer_name: buffer_name)
      end

      def self.delete!(draft:, entry_id:)
        new(draft: draft).delete!(entry_id: entry_id)
      end

      def self.clear!(draft:, buffer_name:)
        new(draft: draft).clear!(buffer_name: buffer_name)
      end

      def self.snapshot(draft:, buffer_name: nil)
        new(draft: draft).snapshot(buffer_name: buffer_name)
      end

      def self.render(draft:, buffer_name:, max_tokens:)
        new(draft: draft).render(buffer_name: buffer_name, max_tokens: max_tokens)
      end

      def initialize(draft:)
        @draft = draft
      end

      def put!(buffer_name:, content:, kind: nil, priority: nil, metadata: nil)
        normalized_buffer_name = normalize_buffer_name(buffer_name)
        normalized_content = normalize_content(content)
        entry =
          {
            "id" => SecureRandom.uuid,
            "buffer_name" => normalized_buffer_name,
            "seq" => next_seq(buffer_name: normalized_buffer_name),
            "kind" => normalize_kind(kind),
            "content" => normalized_content,
            "priority" => normalize_priority(priority),
            "estimated_tokens" => token_counter.count_text(normalized_content),
            "metadata" => normalize_metadata(metadata || {}),
          }

        append_operation!({ "op" => "put", "entry" => entry })
        { "entry" => entry, "staged_prompt_buffer_ops" => draft.reload.staged_prompt_buffer_ops }
      end

      def get(entry_id:)
        { "entry" => indexed_entries.fetch(normalize_entry_id(entry_id), nil) }
      end

      def list(buffer_name: nil)
        { "entries" => matching_entries(buffer_name: buffer_name) }
      end

      def delete!(entry_id:)
        append_operation!({ "op" => "delete", "entry_id" => normalize_entry_id(entry_id) })
        { "staged_prompt_buffer_ops" => draft.reload.staged_prompt_buffer_ops }
      end

      def clear!(buffer_name:)
        append_operation!({ "op" => "clear", "buffer_name" => normalize_buffer_name(buffer_name) })
        { "staged_prompt_buffer_ops" => draft.reload.staged_prompt_buffer_ops }
      end

      def snapshot(buffer_name: nil)
        { "entries" => matching_entries(buffer_name: buffer_name) }
      end

      def render(buffer_name:, max_tokens:)
        budget = normalize_max_tokens(max_tokens)
        entries = matching_entries(buffer_name: buffer_name)
        selected = []
        oversized_entry_ids = []
        total = 0

        entries.sort_by { |entry| [-entry.fetch("priority"), -entry.fetch("seq"), entry.fetch("id")] }.each do |entry|
          entry_tokens = entry.fetch("estimated_tokens")
          if entry_tokens > budget
            oversized_entry_ids << entry.fetch("id")
            next
          end
          next if total + entry_tokens > budget

          selected << entry
          total += entry_tokens
        end

        selected.sort_by! { |entry| [entry.fetch("seq"), entry.fetch("id")] }
        selected_ids = selected.map { |entry| entry.fetch("id") }
        remaining_entries = entries.reject { |entry| selected_ids.include?(entry.fetch("id")) }

        {
          "content" => selected.map { |entry| entry.fetch("content") }.join("\n\n"),
          "entries" => selected,
          "entry_ids" => selected_ids,
          "estimated_tokens" => total,
          "truncated" => remaining_entries.any?,
          "remaining_entries_count" => remaining_entries.length,
          "remaining_entry_ids" => remaining_entries.map { |entry| entry.fetch("id") },
          "oversized_entry_ids" => oversized_entry_ids,
        }
      end

      private

        attr_reader :draft

        def append_operation!(operation)
          draft.with_lock do
            draft.staged_prompt_buffer_ops = Array(draft.staged_prompt_buffer_ops) + [operation]
            draft.save!
          end
        end

        def lane
          draft.bound_lane || draft.bound_conversation&.chat_lane
        end

        def matching_entries(buffer_name:)
          entries = indexed_entries.values
          normalized_buffer_name = buffer_name.to_s.strip
          if normalized_buffer_name.present?
            entries = entries.select { |entry| entry.fetch("buffer_name") == normalized_buffer_name }
          end
          entries.sort_by { |entry| [entry.fetch("buffer_name"), entry.fetch("seq"), entry.fetch("id")] }
        end

        def indexed_entries
          @indexed_entries ||=
            begin
              entries =
                lane.lane_prompt_buffer_entries.ordered.each_with_object({}) do |entry, out|
                  out[entry.id] = serialize_entry(entry)
                end

              Array(draft.staged_prompt_buffer_ops).each do |operation|
                next unless operation.is_a?(Hash)

                case operation["op"].to_s
                when "put"
                  entry = operation["entry"]
                  next unless entry.is_a?(Hash)

                  entries[entry["id"].to_s] = normalize_entry_snapshot(entry)
                when "delete"
                  entries.delete(operation["entry_id"].to_s)
                when "clear"
                  buffer_name = operation["buffer_name"].to_s.strip
                  entries.delete_if { |_id, entry| entry.fetch("buffer_name") == buffer_name }
                end
              end

              entries
            end
        end

        def next_seq(buffer_name:)
          last_seq =
            matching_entries(buffer_name: buffer_name)
              .map { |entry| entry.fetch("seq") }
              .max.to_i

          last_seq + SEQ_STEP
        end

        def normalize_entry_snapshot(entry)
          {
            "id" => entry.fetch("id").to_s,
            "buffer_name" => entry.fetch("buffer_name").to_s,
            "seq" => Integer(entry.fetch("seq")),
            "kind" => entry.fetch("kind").to_s,
            "content" => entry.fetch("content").to_s,
            "priority" => Integer(entry.fetch("priority")),
            "estimated_tokens" => Integer(entry.fetch("estimated_tokens")),
            "metadata" => normalize_metadata(entry.fetch("metadata", {})),
          }
        end

        def serialize_entry(entry)
          {
            "id" => entry.id,
            "buffer_name" => entry.buffer_name,
            "seq" => entry.seq,
            "kind" => entry.kind,
            "content" => entry.content,
            "priority" => entry.priority,
            "estimated_tokens" => entry.estimated_tokens,
            "metadata" => normalize_metadata(entry.metadata),
          }
        end

        def token_counter
          @token_counter ||= Cybros::AgentRuntimeResolver.token_counter_for_model_ref(model_ref: resolved_model_ref)
        end

        def resolved_model_ref
          draft.selected_model_ref.to_s.presence ||
            Cybros::AgentRuntimeResolver.model_resolution_for(conversation: draft.bound_conversation).fetch(:model_ref)
        end

        def normalize_buffer_name(value)
          normalized = value.to_s.strip
          return normalized if normalized.present?

          AgentCore::ValidationError.raise!(
            "prompt buffer name must be present",
            code: "cybros.agent_rpc.lane_prompt_buffer.buffer_name_blank",
          )
        end

        def normalize_content(value)
          normalized = value.to_s.strip
          return normalized if normalized.present?

          AgentCore::ValidationError.raise!(
            "prompt buffer content must be present",
            code: "cybros.agent_rpc.lane_prompt_buffer.content_blank",
          )
        end

        def normalize_kind(value)
          value.to_s.strip.presence || "note"
        end

        def normalize_priority(value)
          Integer(value, exception: false) || 0
        end

        def normalize_entry_id(value)
          normalized = value.to_s.strip
          return normalized if normalized.present?

          AgentCore::ValidationError.raise!(
            "prompt buffer entry id must be present",
            code: "cybros.agent_rpc.lane_prompt_buffer.entry_id_blank",
          )
        end

        def normalize_max_tokens(value)
          normalized = Integer(value, exception: false)
          return normalized if normalized && normalized >= 0

          AgentCore::ValidationError.raise!(
            "max_tokens must be a non-negative integer",
            code: "cybros.agent_rpc.lane_prompt_buffer.max_tokens_invalid",
            details: { max_tokens: value },
          )
        end

        def normalize_metadata(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested_value), out|
              out[key.to_s] = normalize_metadata(nested_value)
            end
          when Array
            value.map { |element| normalize_metadata(element) }
          else
            value
          end
        end
    end
  end
end
