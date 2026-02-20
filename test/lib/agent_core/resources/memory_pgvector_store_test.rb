# frozen_string_literal: true

require "test_helper"
require "zlib"

class AgentCore::Resources::Memory::PgvectorStoreTest < ActiveSupport::TestCase
  class StubEmbedder
    def embed(text:)
      crc = Zlib.crc32(text.to_s)

      a = (crc & 0xFFFF) / 65_535.0
      b = ((crc >> 16) & 0xFFFF) / 65_535.0

      vec = Array.new(1536, 0.0)
      vec[0] = a
      vec[1] = b
      vec[2] = 1.0
      vec
    end
  end

  setup do
    AgentMemoryEntry.delete_all

    @conversation = Conversation.create!
    @embedder = StubEmbedder.new
    @store =
      AgentCore::Resources::Memory::PgvectorStore.new(
        embedder: @embedder,
        conversation_id: @conversation.id,
        include_global: true,
      )
  end

  test "store + search returns nearest neighbors" do
    apple = @store.store(content: "apple", metadata: { kind: "fruit" })
    @store.store(content: "car", metadata: { kind: "vehicle" })

    results = @store.search(query: "apple", limit: 1)
    assert_equal 1, results.size
    assert_equal apple.content, results.first.content
    assert results.first.score
    assert_equal "fruit", results.first.metadata.fetch("kind")
  end

  test "search can include global entries when include_global=true" do
    global_store = AgentCore::Resources::Memory::PgvectorStore.new(embedder: @embedder, conversation_id: nil)
    global_store.store(content: "global note", metadata: { scope: "global" })
    @store.store(content: "local note", metadata: { scope: "local" })

    results = @store.search(query: "note", limit: 10).map(&:metadata).map { |m| m.fetch("scope") }.sort
    assert_equal ["global", "local"], results
  end

  test "search can exclude global entries when include_global=false" do
    AgentCore::Resources::Memory::PgvectorStore
      .new(embedder: @embedder, conversation_id: nil)
      .store(content: "global note", metadata: { scope: "global" })

    local_only =
      AgentCore::Resources::Memory::PgvectorStore.new(
        embedder: @embedder,
        conversation_id: @conversation.id,
        include_global: false,
      )
    local_only.store(content: "local note", metadata: { scope: "local" })

    results = local_only.search(query: "note", limit: 10).map(&:metadata).map { |m| m.fetch("scope") }.sort
    assert_equal ["local"], results
  end

  test "search supports metadata_filter" do
    @store.store(content: "apple", metadata: { category: "fruit" })
    @store.store(content: "apple sauce", metadata: { category: "recipe" })

    results = @store.search(query: "apple", metadata_filter: { category: "fruit" })
    assert_equal 1, results.size
    assert_equal "fruit", results.first.metadata.fetch("category")
  end

  test "forget removes an entry" do
    entry = @store.store(content: "forget me", metadata: {})

    assert_equal 1, @store.size
    assert @store.forget(id: entry.id)
    assert_equal 0, @store.size
  end
end
