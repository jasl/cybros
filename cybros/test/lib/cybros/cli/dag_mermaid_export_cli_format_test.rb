require "test_helper"
require Rails.root.join("script/export_dag_mermaid").to_s

class DagMermaidExportCliFormatTest < ActiveSupport::TestCase
  test "usage documents output and compressed flags" do
    usage = DagMermaidExportCLI.usage

    assert_includes usage, "script/export_dag_mermaid.rb <conversation_id>"
    assert_includes usage, "--output PATH"
    assert_includes usage, "--include-compressed"
  end

  test "format_diagnostics warns when graph has multiple roots" do
    analysis = {
      "node_count" => 267,
      "edge_count" => 268,
      "root_count" => 2,
      "root_node_ids" => ["node_a", "node_b"],
      "component_count" => 2,
      "component_sizes" => [231, 36],
    }

    output = DagMermaidExportCLI.format_diagnostics(analysis)

    assert_includes output, "roots=2"
    assert_includes output, "components=2"
    assert_includes output, "Warning: graph has multiple roots"
    assert_includes output, "component_sizes=[231, 36]"
  end
end
