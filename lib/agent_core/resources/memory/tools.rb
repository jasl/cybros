# frozen_string_literal: true

module AgentCore
  module Resources
    module Memory
      # Builds native tools for interacting with a Memory::Base store.
      module Tools
        DEFAULT_MAX_BODY_BYTES = 200_000
        DEFAULT_TOOL_NAME_PREFIX = "memory_"
        DEFAULT_SEARCH_LIMIT = 5
        MAX_SEARCH_LIMIT = 20

        module_function

        def build(store:, max_body_bytes: DEFAULT_MAX_BODY_BYTES, tool_name_prefix: DEFAULT_TOOL_NAME_PREFIX)
          unless store.respond_to?(:search) && store.respond_to?(:store) && store.respond_to?(:forget)
            raise ValidationError, "store must implement Memory::Base"
          end

          max_body_bytes = Integer(max_body_bytes)
          raise ValidationError, "max_body_bytes must be positive" if max_body_bytes <= 0

          prefix = tool_name_prefix.to_s
          prefix = prefix.tr(".", "_").gsub(/[^A-Za-z0-9_-]/, "_")
          prefix = "#{prefix}_" unless prefix.empty? || prefix.end_with?("_")

          [
            build_search_tool(store: store, prefix: prefix, max_bytes: max_body_bytes),
            build_store_tool(store: store, prefix: prefix, max_bytes: max_body_bytes),
            build_forget_tool(store: store, prefix: prefix),
          ]
        end

        def build_search_tool(store:, prefix:, max_bytes:)
          Resources::Tools::Tool.new(
            name: "#{prefix}search",
            description: "Search memory for relevant entries.",
            metadata: { source: :memory },
            parameters: {
              type: "object",
              additionalProperties: false,
              properties: {
                query: { type: "string" },
                limit: { type: "integer", minimum: 1, maximum: MAX_SEARCH_LIMIT },
                metadata_filter: { type: "object", additionalProperties: true },
              },
              required: ["query"],
            },
          ) do |args, **|
            require "json"

            query = args.fetch("query").to_s

            limit = Integer(args.fetch("limit", DEFAULT_SEARCH_LIMIT), exception: false) || DEFAULT_SEARCH_LIMIT
            limit = DEFAULT_SEARCH_LIMIT if limit <= 0
            limit = [limit, MAX_SEARCH_LIMIT].min

            metadata_filter = args.fetch("metadata_filter", nil)
            metadata_filter = metadata_filter.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(metadata_filter) : nil

            entries =
              begin
                store.search(query: query, limit: limit, metadata_filter: metadata_filter)
              rescue ArgumentError
                store.search(query: query, limit: limit)
              end

            items =
              Array(entries).map do |entry|
                h = entry.respond_to?(:to_h) ? entry.to_h : {}
                h = AgentCore::Utils.deep_stringify_keys(h) if h.is_a?(Hash)

                {
                  "id" => (h.fetch("id", nil) || (entry.respond_to?(:id) ? entry.id : nil)).to_s,
                  "content" => (h.fetch("content", nil) || (entry.respond_to?(:content) ? entry.content : nil)).to_s,
                  "metadata" => begin
                    md = h.fetch("metadata", nil) || (entry.respond_to?(:metadata) ? entry.metadata : nil)
                    md.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(md) : {}
                  rescue StandardError
                    {}
                  end,
                  "score" => begin
                    score = h.fetch("score", nil)
                    score = entry.score if score.nil? && entry.respond_to?(:score)
                    score.nil? ? nil : score
                  rescue StandardError
                    nil
                  end,
                }.compact
              end

            json = JSON.generate({ "entries" => items, "truncated" => false })
            if json.bytesize > max_bytes
              json = JSON.generate(truncate_entries_payload(items, max_bytes: max_bytes))
            end

            Resources::Tools::ToolResult.success(text: json)
          rescue KeyError => e
            Resources::Tools::ToolResult.error(text: "memory_search missing argument: #{e.message}")
          rescue StandardError => e
            Resources::Tools::ToolResult.error(text: "memory_search failed: #{e.message}")
          end
        end
        private_class_method :build_search_tool

        def truncate_entries_payload(items, max_bytes:)
          require "json"

          truncated = []
          items.each do |item|
            candidate = truncated + [item]
            json = JSON.generate({ "entries" => candidate, "truncated" => true })
            break if json.bytesize > max_bytes

            truncated = candidate
          end

          if truncated.empty? && items.any?
            first = items.first.dup
            budget = [max_bytes - 200, 0].max
            first["content"] = AgentCore::Utils.truncate_utf8_bytes(first.fetch("content", ""), max_bytes: budget)

            payload = { "entries" => [first], "truncated" => true }
            json = JSON.generate(payload)
            if json.bytesize > max_bytes
              first["content"] = ""
              payload = { "entries" => [first], "truncated" => true }
              json = JSON.generate(payload)
              if json.bytesize > max_bytes
                return { "entries" => [], "truncated" => true }
              end
            end

            return payload
          end

          { "entries" => truncated, "truncated" => true }
        rescue StandardError
          { "entries" => [], "truncated" => true }
        end
        private_class_method :truncate_entries_payload

        def build_store_tool(store:, prefix:, max_bytes:)
          Resources::Tools::Tool.new(
            name: "#{prefix}store",
            description: "Store a new memory entry.",
            metadata: { source: :memory },
            parameters: {
              type: "object",
              additionalProperties: false,
              properties: {
                content: { type: "string" },
                metadata: { type: "object", additionalProperties: true },
              },
              required: ["content"],
            },
          ) do |args, **|
            require "json"

            content = args.fetch("content").to_s
            metadata = args.fetch("metadata", {})
            metadata = metadata.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(metadata) : {}

            entry =
              begin
                store.store(content: content, metadata: metadata)
              rescue ArgumentError
                store.store(content: content)
              end

            payload = {
              "entry" => {
                "id" => (entry.respond_to?(:id) ? entry.id : "").to_s,
                "content" => (entry.respond_to?(:content) ? entry.content : content).to_s,
                "metadata" => begin
                  md = entry.respond_to?(:metadata) ? entry.metadata : metadata
                  md.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(md) : {}
                rescue StandardError
                  {}
                end,
              }.compact,
            }

            json = JSON.generate(payload)
            if json.bytesize > max_bytes
              budget = [max_bytes - 300, 0].max
              payload["entry"]["content"] = AgentCore::Utils.truncate_utf8_bytes(payload["entry"].fetch("content", ""), max_bytes: budget)
              json = JSON.generate(payload)
              if json.bytesize > max_bytes
                payload["entry"]["content"] = ""
                json = JSON.generate(payload)
              end
              if json.bytesize > max_bytes
                payload["entry"]["metadata"] = {}
                json = JSON.generate(payload)
              end
              if json.bytesize > max_bytes
                payload["entry"]["id"] = AgentCore::Utils.truncate_utf8_bytes(payload["entry"].fetch("id", ""), max_bytes: 200)
                json = JSON.generate(payload)
              end
            end

            Resources::Tools::ToolResult.success(text: json)
          rescue KeyError => e
            Resources::Tools::ToolResult.error(text: "memory_store missing argument: #{e.message}")
          rescue StandardError => e
            Resources::Tools::ToolResult.error(text: "memory_store failed: #{e.message}")
          end
        end
        private_class_method :build_store_tool

        def build_forget_tool(store:, prefix:)
          Resources::Tools::Tool.new(
            name: "#{prefix}forget",
            description: "Forget (delete) a memory entry by id.",
            metadata: { source: :memory },
            parameters: {
              type: "object",
              additionalProperties: false,
              properties: {
                id: { type: "string" },
              },
              required: ["id"],
            },
          ) do |args, **|
            require "json"

            id = args.fetch("id").to_s
            ok = store.forget(id: id) == true

            Resources::Tools::ToolResult.success(text: JSON.generate({ "ok" => ok }))
          rescue KeyError => e
            Resources::Tools::ToolResult.error(text: "memory_forget missing argument: #{e.message}")
          rescue StandardError => e
            Resources::Tools::ToolResult.error(text: "memory_forget failed: #{e.message}")
          end
        end
        private_class_method :build_forget_tool
      end
    end
  end
end
