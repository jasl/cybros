require "test_helper"

class Conversation::ContextCompactionPlanTest < ActiveSupport::TestCase
  class SummarySurface < AgentCore::RuntimeSurface::Base
    def compact_context(input:)
      _ = input
      AgentCore::RuntimeSurface::Decisions::ContextCompaction.new(
        kept_items: [],
        summaries: ["SURFACE_SUMMARY"],
        externalized_items: [],
        metadata: {},
      )
    end
  end

  class BudgetBreakingKeepSurface < AgentCore::RuntimeSurface::Base
    def compact_context(input:)
      _ = input
      AgentCore::RuntimeSurface::Decisions::ContextCompaction.new(
        kept_items: ["t2"],
        summaries: ["SHOULD_NOT_APPLY"],
        externalized_items: [],
        metadata: {},
      )
    end
  end

  class ExplodingSurface < AgentCore::RuntimeSurface::Base
    def compact_context(input:)
      raise "compact_context failed for #{input.context_window.length}"
    end
  end

  test "compact_context surface can replace the compaction summary text" do
    plan =
      build_plan(
        runtime_surface_resolution: runtime_surface_resolution_for(SummarySurface.new),
      )

    result = run_plan(plan)

    assert result.required?
    assert_equal %w[t1 t2], result.compacted_turn_ids
    assert_equal "SURFACE_SUMMARY", result.summary_text
  end

  test "compact_context keep requests still yield to the runtime budget" do
    plan =
      build_plan(
        runtime_surface_resolution: runtime_surface_resolution_for(BudgetBreakingKeepSurface.new),
      )

    result = run_plan(plan)

    assert result.required?
    assert_equal %w[t1 t2], result.compacted_turn_ids
    assert_equal "DEFAULT_SUMMARY", result.summary_text
  end

  test "compact_context surface failures fall back to the default summary" do
    plan =
      build_plan(
        runtime_surface_resolution: runtime_surface_resolution_for(ExplodingSurface.new),
      )

    result = run_plan(plan)

    assert result.required?
    assert_equal %w[t1 t2], result.compacted_turn_ids
    assert_equal "DEFAULT_SUMMARY", result.summary_text
  end

  test "malformed task tool results fall back to the projected preview" do
    plan = build_plan(runtime_surface_resolution: nil)

    text =
      plan.send(
        :tool_result_text_for_task,
        output: { "result" => "{" },
        output_preview: { "result" => "PREVIEW_RESULT" },
      )

    assert_equal "PREVIEW_RESULT", text
  end

  test "estimated token offsets make fixed prompt overhead count toward compaction" do
    plan =
      Conversation::ContextCompactionPlan.new(
        conversation: create_conversation!,
        content: "follow up",
        runtime_surface_resolution: nil,
        estimated_tokens_offset: 15,
      )

    nodes = [
      transcript_node(turn_id: "t1", content: "history one"),
      transcript_node(turn_id: "t2", content: "history two"),
    ]
    estimate_fn = lambda do |context_nodes:|
      turn_count =
        Array(context_nodes)
          .filter_map { |node| node.fetch("turn_id").to_s.presence }
          .uniq
          .reject { |turn_id| turn_id == "synthetic-turn" }
          .length

      case turn_count
      when 2 then 20
      when 1 then 10
      else 5
      end
    end

    plan.define_singleton_method(:effective_prompt_budget_tokens) { 25 }
    plan.define_singleton_method(:transcript_nodes) { nodes }
    plan.define_singleton_method(:estimated_tokens_for) do |context_nodes:|
      estimate_fn.call(context_nodes: context_nodes) + instance_variable_get(:@estimated_tokens_offset).to_i
    end
    plan.define_singleton_method(:summary_text_for) { |compacted_nodes:, budget:| "DEFAULT_SUMMARY" }

    result = plan.plan

    assert result.required?
    assert_equal ["t1"], result.compacted_turn_ids
    assert_equal "DEFAULT_SUMMARY", result.summary_text
  end

  private

    def build_plan(runtime_surface_resolution:)
      Conversation::ContextCompactionPlan.new(
        conversation: create_conversation!,
        content: "follow up",
        runtime_surface_resolution: runtime_surface_resolution,
      )
    end

    def run_plan(plan)
      nodes = transcript_nodes
      estimate_fn = method(:estimated_tokens_for_context)

      plan.define_singleton_method(:effective_prompt_budget_tokens) { 15 }
      plan.define_singleton_method(:transcript_nodes) { nodes }
      plan.define_singleton_method(:estimated_tokens_for) do |context_nodes:|
        estimate_fn.call(context_nodes: context_nodes)
      end
      plan.define_singleton_method(:summary_text_for) { |compacted_nodes:, budget:| "DEFAULT_SUMMARY" }

      plan.plan
    end

    def transcript_nodes
      [
        transcript_node(turn_id: "t1", content: "history one"),
        transcript_node(turn_id: "t2", content: "history two"),
        transcript_node(turn_id: "t3", content: "history three"),
      ]
    end

    def transcript_node(turn_id:, content:)
      {
        "node_id" => "#{turn_id}-user",
        "turn_id" => turn_id,
        "lane_id" => "lane-1",
        "node_type" => Messages::UserMessage.node_type_key,
        "state" => DAG::Node::FINISHED,
        "payload" => {
          "input" => { "content" => content },
          "output" => {},
          "output_preview" => {},
        },
        "metadata" => {},
      }
    end

    def estimated_tokens_for_context(context_nodes:)
      turn_count =
        Array(context_nodes)
          .filter_map { |node| node.fetch("turn_id").to_s.presence }
          .uniq
          .reject { |turn_id| turn_id == "synthetic-turn" }
          .length

      case turn_count
      when 3 then 30
      when 2 then 20
      when 1 then 10
      else 5
      end
    end

    def runtime_surface_resolution_for(surface)
      {
        runtime_surface: surface,
        runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
        execution_context_attributes: {
          type: :noop,
          helpers: [],
          stage_limits: {},
        },
      }
    end
end
