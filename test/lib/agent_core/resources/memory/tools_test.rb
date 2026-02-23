# frozen_string_literal: true

require "test_helper"

class AgentCore::Resources::Memory::ToolsTest < Minitest::Test
  class StubStore
    def initialize
      @entries = []
      @next_id = 1
    end

    def search(query:, limit: 5, metadata_filter: nil)
      _ = metadata_filter
      q = query.to_s
      @entries.select { |e| e.content.include?(q) }.first(limit)
    end

    def store(content:, metadata: {})
      entry =
        AgentCore::Resources::Memory::Entry.new(
          id: (@next_id += 1).to_s,
          content: content.to_s,
          metadata: metadata,
        )
      @entries << entry
      entry
    end

    def forget(id:)
      before = @entries.length
      @entries.reject! { |e| e.id.to_s == id.to_s }
      @entries.length < before
    end
  end

  def test_search_store_forget_tools
    store = StubStore.new
    store.store(content: "hello world", metadata: { source: "test" })
    store.store(content: "hello " + ("x" * 2_000), metadata: { source: "big" })

    tools = AgentCore::Resources::Memory::Tools.build(store: store, max_body_bytes: 300)
    by_name = tools.index_by(&:name)

    search = by_name.fetch("memory_search")
    store_tool = by_name.fetch("memory_store")
    forget = by_name.fetch("memory_forget")

    search_result = search.call({ "query" => "hello" })
    payload = JSON.parse(search_result.text)
    assert payload["entries"].is_a?(Array)
    assert payload.key?("truncated")
    assert payload["truncated"], "expected truncated=true under tight max_body_bytes"

    store_result = store_tool.call({ "content" => "keep this", "metadata" => { "tag" => "t1" } })
    store_payload = JSON.parse(store_result.text)
    assert store_payload.fetch("entry").fetch("id").present?
    assert_equal "t1", store_payload.fetch("entry").fetch("metadata").fetch("tag")

    id = store_payload.fetch("entry").fetch("id")
    forget_result = forget.call({ "id" => id })
    forget_payload = JSON.parse(forget_result.text)
    assert_equal true, forget_payload.fetch("ok")
  end

  def test_store_tool_respects_max_body_bytes_even_with_huge_metadata
    store = StubStore.new

    tools = AgentCore::Resources::Memory::Tools.build(store: store, max_body_bytes: 200)
    store_tool = tools.index_by(&:name).fetch("memory_store")

    huge = "x" * 1_000
    result = store_tool.call({ "content" => "ok", "metadata" => { "huge" => huge } })

    assert_operator result.text.bytesize, :<=, 200

    payload = JSON.parse(result.text)
    entry = payload.fetch("entry")
    assert entry.fetch("id").present?
    assert entry.key?("metadata")
    assert entry.fetch("metadata").is_a?(Hash)
  end

  def test_validation_error_from_store_bubbles_to_tool_metadata
    store =
      Class.new do
        def search(query:, limit: 5, metadata_filter: nil)
          _ = query
          _ = limit
          _ = metadata_filter
          []
        end

        def store(content:, metadata: {})
          AgentCore::Resources::Memory::Entry.new(id: "1", content: content, metadata: metadata)
        end

        def forget(id:)
          AgentCore::ValidationError.raise!(
            "invalid id",
            code: "test.memory.invalid_id",
            details: { id: id.to_s },
          )
        end
      end.new

    tools = AgentCore::Resources::Memory::Tools.build(store: store)
    forget = tools.index_by(&:name).fetch("memory_forget")

    result = forget.call({ "id" => "not-a-real-id" })
    assert result.error?
    assert_includes result.text, "validation failed"
    assert_equal "test.memory.invalid_id", result.metadata.dig("validation_error", "code")
  end
end
