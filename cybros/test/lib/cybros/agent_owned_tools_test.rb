require "test_helper"

class Cybros::AgentOwnedToolsTest < ActiveSupport::TestCase
  test "memory tools expose scoped workspace-memory parameters on the public tool surface" do
    tools = Cybros::AgentOwnedTools.build.index_by(&:name)

    search_schema = tools.fetch("memory_search").parameters
    get_schema = tools.fetch("memory_get").parameters
    store_schema = tools.fetch("memory_store").parameters

    assert_equal "Search scoped workspace memory files and return matching lines.", tools.fetch("memory_search").description
    assert_equal "Read a scoped workspace memory document.", tools.fetch("memory_get").description
    assert_equal "Store durable notes in a scoped workspace memory document.", tools.fetch("memory_store").description

    assert_equal %w[query], search_schema.fetch(:required)
    assert_includes search_schema.fetch(:properties).keys, :scopes
    assert_equal %w[root conversation lane], search_schema.dig(:properties, :scopes, :items, :enum)

    assert_includes get_schema.fetch(:properties).keys, :scope
    assert_equal %w[root conversation lane], get_schema.dig(:properties, :scope, :enum)
    assert_includes get_schema.fetch(:properties).keys, :target

    assert_equal %w[content], store_schema.fetch(:required)
    assert_includes store_schema.fetch(:properties).keys, :scope
    assert_equal %w[root conversation lane], store_schema.dig(:properties, :scope, :enum)
    assert_includes store_schema.fetch(:properties).keys, :target
    assert_equal %w[append replace], store_schema.dig(:properties, :mode, :enum)
  end
end
