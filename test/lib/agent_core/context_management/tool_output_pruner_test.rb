# frozen_string_literal: true

require "test_helper"

class AgentCore::ContextManagement::ToolOutputPrunerTest < Minitest::Test
  def test_prunes_only_older_tool_outputs_and_protects_recent_turns
    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 2,
        max_output_chars: 10,
        preview_chars: 4,
      )

    long_tool = "x" * 2_000
    long_assistant = "y" * 2_000

    messages = [
      AgentCore::Message.new(role: :user, content: "u1"),
      AgentCore::Message.new(role: :assistant, content: long_assistant),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_1"),
      AgentCore::Message.new(role: :system, content: "[tool: echo]\n#{long_tool}"),
      AgentCore::Message.new(role: :user, content: "u2"),
      AgentCore::Message.new(role: :assistant, content: "a2"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_2"),
      AgentCore::Message.new(role: :user, content: "u3"),
      AgentCore::Message.new(role: :assistant, content: "a3"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_3"),
    ]

    pruned, stats = pruner.call(messages: messages)

    assert_equal messages.length, pruned.length

    # Old tool outputs (before boundary) are trimmed.
    assert pruned[2].text.start_with?("[Trimmed tool output"), pruned[2].text
    assert pruned[3].text.start_with?("[Trimmed tool output"), pruned[3].text

    # Non-tool messages are never trimmed.
    assert_equal long_assistant, pruned[1].text

    # Recent turns are protected (boundary is u2).
    assert_equal long_tool, pruned[6].text
    assert_equal long_tool, pruned[9].text

    # Roles and tool_call_id are preserved.
    assert_equal :tool_result, pruned[2].role
    assert_equal "tc_1", pruned[2].tool_call_id
    assert_equal :system, pruned[3].role

    assert_equal 2, stats.fetch(:trimmed_count)
    assert_operator stats.fetch(:chars_saved), :>, 0
  end

  def test_recent_turns_zero_prunes_all_candidates
    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 0,
        max_output_chars: 10,
        preview_chars: 4,
      )

    long_tool = "x" * 2_000

    messages = [
      AgentCore::Message.new(role: :user, content: "u1"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_1"),
      AgentCore::Message.new(role: :user, content: "u2"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_2"),
    ]

    pruned, stats = pruner.call(messages: messages)

    assert pruned[1].text.start_with?("[Trimmed tool output"), pruned[1].text
    assert pruned[3].text.start_with?("[Trimmed tool output"), pruned[3].text
    assert_equal 2, stats.fetch(:trimmed_count)
  end

  def test_does_not_prune_when_replacement_would_not_be_shorter
    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 0,
        max_output_chars: 10,
        preview_chars: 100,
      )

    text = "x" * 11
    messages = [AgentCore::Message.new(role: :tool_result, content: text, tool_call_id: "tc_1")]

    pruned, stats = pruner.call(messages: messages)

    assert_equal text, pruned.first.text
    assert_equal 0, stats.fetch(:trimmed_count)
  end
end
