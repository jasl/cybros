# frozen_string_literal: true

require "test_helper"

class AgentCore::ContextManagement::ToolOutputPrunerTest < Minitest::Test
  def test_soft_trims_only_older_tool_outputs_and_protects_recent_turns
    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 2,
        keep_last_assistant_messages: 0,
        soft_trim_max_chars: 10,
        soft_trim_head_chars: 4,
        soft_trim_tail_chars: 4,
      )

    long_tool_body = "x" * 2_000
    long_tool = "[tool: echo]\n#{long_tool_body}"
    long_assistant = "y" * 2_000

    messages = [
      AgentCore::Message.new(role: :user, content: "u1"),
      AgentCore::Message.new(role: :assistant, content: long_assistant),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_1"),
      AgentCore::Message.new(role: :system, content: long_tool),
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
    assert pruned[2].text.start_with?("[tool: echo]\n"), pruned[2].text
    assert_includes pruned[2].text, "[Tool result trimmed:"
    assert pruned[3].text.start_with?("[tool: echo]\n"), pruned[3].text
    assert_includes pruned[3].text, "[Tool result trimmed:"

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
        keep_last_assistant_messages: 0,
        soft_trim_max_chars: 10,
        soft_trim_head_chars: 4,
        soft_trim_tail_chars: 4,
      )

    long_tool_body = "x" * 2_000
    long_tool = "[tool: echo]\n#{long_tool_body}"

    messages = [
      AgentCore::Message.new(role: :user, content: "u1"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_1"),
      AgentCore::Message.new(role: :user, content: "u2"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_2"),
    ]

    pruned, stats = pruner.call(messages: messages)

    assert_includes pruned[1].text, "[Tool result trimmed:"
    assert_includes pruned[3].text, "[Tool result trimmed:"
    assert_equal 2, stats.fetch(:trimmed_count)
  end

  def test_does_not_prune_when_replacement_would_not_be_shorter
    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 0,
        keep_last_assistant_messages: 0,
        soft_trim_max_chars: 10,
        soft_trim_head_chars: 4,
        soft_trim_tail_chars: 4,
      )

    text = "x" * 11
    messages = [AgentCore::Message.new(role: :tool_result, content: text, tool_call_id: "tc_1")]

    pruned, stats = pruner.call(messages: messages)

    assert_equal text, pruned.first.text
    assert_equal 0, stats.fetch(:trimmed_count)
  end

  def test_tool_name_allow_and_deny_globs
    long_tool_body = "x" * 2_000
    echo_tool = "[tool: EcHo]\n#{long_tool_body}"
    other_tool = "[tool: other]\n#{long_tool_body}"

    messages = [
      AgentCore::Message.new(role: :user, content: "u1"),
      AgentCore::Message.new(role: :tool_result, content: echo_tool, tool_call_id: "tc_1"),
      AgentCore::Message.new(role: :tool_result, content: other_tool, tool_call_id: "tc_2"),
    ]

    deny_echo =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 0,
        keep_last_assistant_messages: 0,
        soft_trim_max_chars: 10,
        soft_trim_head_chars: 4,
        soft_trim_tail_chars: 4,
        tools_deny: ["*echo*"],
      )

    pruned, = deny_echo.call(messages: messages)
    assert_equal echo_tool, pruned[1].text
    assert_includes pruned[2].text, "[Tool result trimmed:"

    allow_echo_only =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 0,
        keep_last_assistant_messages: 0,
        soft_trim_max_chars: 10,
        soft_trim_head_chars: 4,
        soft_trim_tail_chars: 4,
        tools_allow: ["echo*"],
      )

    pruned2, = allow_echo_only.call(messages: messages)
    assert_includes pruned2[1].text, "[Tool result trimmed:"
    assert_equal other_tool, pruned2[2].text
  end

  def test_deny_wins_over_allow
    long_tool_body = "x" * 2_000
    echo_tool = "[tool: echo]\n#{long_tool_body}"

    messages = [
      AgentCore::Message.new(role: :user, content: "u1"),
      AgentCore::Message.new(role: :tool_result, content: echo_tool, tool_call_id: "tc_1"),
    ]

    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 0,
        keep_last_assistant_messages: 0,
        soft_trim_max_chars: 10,
        soft_trim_head_chars: 4,
        soft_trim_tail_chars: 4,
        tools_allow: ["*"],
        tools_deny: ["echo"],
      )

    pruned, stats = pruner.call(messages: messages)
    assert_equal echo_tool, pruned[1].text
    assert_equal 0, stats.fetch(:trimmed_count)
  end

  def test_tools_deny_glob_star_matches_unknown_tool_name
    long_text = "x" * 2_000

    messages = [
      AgentCore::Message.new(role: :user, content: "u1"),
      AgentCore::Message.new(role: :tool_result, content: long_text, tool_call_id: "tc_1"),
    ]

    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 0,
        keep_last_assistant_messages: 0,
        soft_trim_max_chars: 10,
        soft_trim_head_chars: 4,
        soft_trim_tail_chars: 4,
        tools_deny: ["*"],
      )

    pruned, stats = pruner.call(messages: messages)
    assert_equal long_text, pruned[1].text
    assert_equal 0, stats.fetch(:trimmed_count)
  end

  def test_does_not_prune_tool_outputs_before_first_user_message
    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 0,
        keep_last_assistant_messages: 0,
        soft_trim_max_chars: 10,
        soft_trim_head_chars: 4,
        soft_trim_tail_chars: 4,
      )

    long_tool_body = "x" * 2_000
    long_tool = "[tool: echo]\n#{long_tool_body}"

    messages = [
      AgentCore::Message.new(role: :system, content: long_tool),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_pre"),
      AgentCore::Message.new(role: :user, content: "u1"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_post"),
    ]

    pruned, stats = pruner.call(messages: messages)

    assert_equal long_tool, pruned[0].text
    assert_equal long_tool, pruned[1].text
    assert_equal "u1", pruned[2].text

    assert_includes pruned[3].text, "[Tool result trimmed:"
    assert_equal "tc_pre", pruned[1].tool_call_id
    assert_equal "tc_post", pruned[3].tool_call_id

    assert_equal 1, stats.fetch(:trimmed_count)
  end

  def test_keep_last_assistant_messages_protects_recent_assistant_tail
    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        recent_turns: 0,
        keep_last_assistant_messages: 2,
        soft_trim_max_chars: 10,
        soft_trim_head_chars: 4,
        soft_trim_tail_chars: 4,
      )

    long_tool_body = "x" * 2_000
    long_tool = "[tool: echo]\n#{long_tool_body}"

    messages = [
      AgentCore::Message.new(role: :user, content: "u1"),
      AgentCore::Message.new(role: :assistant, content: "a1"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_1"),
      AgentCore::Message.new(role: :user, content: "u2"),
      AgentCore::Message.new(role: :assistant, content: "a2"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_2"),
      AgentCore::Message.new(role: :user, content: "u3"),
      AgentCore::Message.new(role: :assistant, content: "a3"),
      AgentCore::Message.new(role: :tool_result, content: long_tool, tool_call_id: "tc_3"),
      AgentCore::Message.new(role: :user, content: "u4"),
      AgentCore::Message.new(role: :assistant, content: "a4"),
    ]

    pruned, = pruner.call(messages: messages)

    assert_includes pruned[5].text, "[Tool result trimmed:"
    assert_equal long_tool, pruned[8].text
  end

  def test_hard_clear_message_preserves_tool_header_when_present
    pruner =
      AgentCore::ContextManagement::ToolOutputPruner.new(
        hard_clear_placeholder: "CLEARED",
      )

    with_header =
      AgentCore::Message.new(
        role: :tool_result,
        content: "[tool: echo]\nhello",
        tool_call_id: "tc_1",
      )

    cleared = pruner.hard_clear_message(with_header)
    assert_equal :tool_result, cleared.role
    assert_equal "tc_1", cleared.tool_call_id
    assert_equal "[tool: echo]\nCLEARED", cleared.text

    without_header =
      AgentCore::Message.new(
        role: :tool_result,
        content: "hello",
        tool_call_id: "tc_2",
        name: "echo",
      )

    cleared2 = pruner.hard_clear_message(without_header)
    assert_equal :tool_result, cleared2.role
    assert_equal "tc_2", cleared2.tool_call_id
    assert_equal "CLEARED", cleared2.text
  end
end
