require "test_helper"
require "securerandom"

class AgentCore::DAG::ContextBudgetManagerRuntimeSurfaceTest < ActiveSupport::TestCase
  class EnqueueOnSoftLimitPolicy
    def self.action_for(budget_state:, compact_context_suppressed: false)
      return "none" if compact_context_suppressed
      return "enqueue_compact" if budget_state.to_s == "soft_limit_reached"

      "none"
    end
  end

  class BudgetCapturingSurface < AgentCore::RuntimeSurface::Base
    class << self
      attr_accessor :last_input
    end

    def prepare_turn(input:)
      self.class.last_input = input
      AgentCore::RuntimeSurface::Decisions::Pass.new
    end
  end

  class RewritingSurface < AgentCore::RuntimeSurface::Base
    def prepare_turn(input:)
      prompt = input.prompt.dup
      system_prompt = prompt.fetch(:system_prompt, prompt.fetch("system_prompt", ""))

      AgentCore::RuntimeSurface::Decisions::TurnRewrite.new(
        prompt: prompt.merge(system_prompt: "#{system_prompt}\nRUNTIME_NOTE"),
        metadata: { applied: true },
      )
    end
  end

  class OversizedRewritingSurface < AgentCore::RuntimeSurface::Base
    def prepare_turn(input:)
      prompt = input.prompt.dup
      system_prompt = prompt.fetch(:system_prompt, prompt.fetch("system_prompt", ""))

      AgentCore::RuntimeSurface::Decisions::TurnRewrite.new(
        prompt: prompt.merge(system_prompt: "#{system_prompt}\nOVERSIZED_NOTE #{"x" * 4000}"),
        metadata: { applied: true },
      )
    end
  end

  test "prepare_turn can rewrite the built prompt before the main model call" do
    agent_node, graph = build_simple_turn!

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        runtime_surface: RewritingSurface.new,
        runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
      )

    manager =
      AgentCore::DAG::ContextBudgetManager.new(
        node: agent_node,
        runtime: runtime,
        execution_context: {},
      )

    result = manager.build_prompt(context_nodes: graph.context_for_full(agent_node.id))

    assert_includes result.built_prompt.system_prompt, "RUNTIME_NOTE"
    decisions = result.metadata.fetch("context_cost").fetch("decisions")
    assert_includes decisions, { "type" => "prepare_turn_rewrite", "applied" => true, "fallback" => false }
  end

  test "prepare_turn rewrite is rejected when it would exceed the runtime budget" do
    agent_node, graph = build_simple_turn!

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        context_window_tokens: 600,
        runtime_surface: OversizedRewritingSurface.new,
        runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
      )

    manager =
      AgentCore::DAG::ContextBudgetManager.new(
        node: agent_node,
        runtime: runtime,
        execution_context: {},
      )

    result = manager.build_prompt(context_nodes: graph.context_for_full(agent_node.id))

    refute_includes result.built_prompt.system_prompt, "OVERSIZED_NOTE"
    decisions = result.metadata.fetch("context_cost").fetch("decisions")
    assert_includes decisions, { "type" => "prepare_turn_rewrite", "applied" => false, "reason" => "budget_exceeded", "fallback" => false }
  end

  test "prepare_turn budget payload only exposes effective budget facts and state" do
    agent_node, graph = build_simple_turn!
    estimate = estimate_for(agent_node, graph)

    BudgetCapturingSurface.last_input = nil

    build_prompt(
      agent_node,
      graph,
      context_window_tokens: estimate + 100,
      model_context_window_tokens: estimate + 160,
      provider_context_window_tokens: estimate + 120,
      context_soft_limit_tokens: estimate,
      context_soft_limit_ratio: 0.95,
      runtime_surface: BudgetCapturingSurface.new,
      runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
    )

    budget = BudgetCapturingSurface.last_input.budget

    assert_equal %i[budget_state effective_context_soft_limit_tokens effective_prompt_budget_tokens estimated_tokens], budget.keys.sort
    assert_equal estimate + 100, budget.fetch(:effective_prompt_budget_tokens)
    assert_equal estimate, budget.fetch(:effective_context_soft_limit_tokens)
    assert_equal estimate, budget.fetch(:estimated_tokens)
    assert_equal "soft_limit_reached", budget.fetch(:budget_state)
  end

  test "effective soft limit uses tokens ratio or the stricter of both" do
    agent_node, graph = build_simple_turn!

    tokens_only =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: 4000,
        reserved_output_tokens: 100,
        context_soft_limit_tokens: 2200,
      )
    ratio_only =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: 4000,
        reserved_output_tokens: 100,
        context_soft_limit_ratio: 0.5,
      )
    both =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: 4000,
        reserved_output_tokens: 100,
        context_soft_limit_tokens: 2200,
        context_soft_limit_ratio: 0.5,
      )

    assert_equal 2200, tokens_only.metadata.fetch("context_cost").fetch("effective_context_soft_limit_tokens")
    assert_equal 1950, ratio_only.metadata.fetch("context_cost").fetch("effective_context_soft_limit_tokens")
    assert_equal 1950, both.metadata.fetch("context_cost").fetch("effective_context_soft_limit_tokens")
  end

  test "budget state transitions cover normal soft_limit_reached and near_hard_cap" do
    agent_node, graph = build_simple_turn!
    estimate = estimate_for(agent_node, graph)

    normal =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: estimate + 200,
        context_soft_limit_tokens: estimate + 50,
      )
    soft_limit_reached =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: estimate + 200,
        context_soft_limit_tokens: estimate,
      )
    near_hard_cap =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: estimate + 1,
      )

    assert_equal "normal", normal.metadata.fetch("context_cost").fetch("budget_state")
    assert_equal "soft_limit_reached", soft_limit_reached.metadata.fetch("context_cost").fetch("budget_state")
    assert_equal "near_hard_cap", near_hard_cap.metadata.fetch("context_cost").fetch("budget_state")
  end

  test "context budget manager consumes the runtime-injected budget policy" do
    agent_node, graph = build_simple_turn!
    estimate = estimate_for(agent_node, graph)

    result =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: estimate + 200,
        context_soft_limit_tokens: estimate,
        context_budget_policy: EnqueueOnSoftLimitPolicy,
      )

    assert_equal "soft_limit_reached", result.metadata.dig("context_budget", "budget_state")
    assert_equal "enqueue_compact", result.metadata.dig("context_budget", "budget_action")
  end

  test "prompt sections report includes context budget guidance when soft limit advises compaction" do
    agent_node, graph = build_simple_turn!
    estimate = estimate_for(agent_node, graph)

    result =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: estimate + 1000,
        context_soft_limit_tokens: estimate,
        context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
      )

    assert_equal "soft_limit_reached", result.metadata.dig("context_budget", "budget_state")
    assert_equal "advise_compact", result.metadata.dig("context_budget", "budget_action")
    assert result.metadata.dig("context_cost", "prompt_sections", "system_prompt", "sections").any? { |section| section.fetch("id") == "prompt_injection:context_budget_guidance" }
  end

  test "lane prompt buffer material contributes to budget state fingerprint and prompt sections" do
    agent_node, graph = build_simple_turn!

    baseline = build_prompt(agent_node, graph, context_window_tokens: 10_000)
    baseline_total = baseline.metadata.fetch("context_cost").dig("estimated_tokens", "total")

    normal_without_buffer =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: baseline_total + 10_000,
        context_soft_limit_tokens: baseline_total + 10,
      )

    assert_equal "normal", normal_without_buffer.metadata.fetch("context_cost").fetch("budget_state")

    agent_node.lane.lane_prompt_buffer_entries.create!(
      buffer_name: "summaries",
      seq: 10,
      kind: "summary",
      content: "Buffer summary " + ("x" * 80),
      priority: 100,
      estimated_tokens: 95,
      metadata: { "source" => "compact_context" },
    )

    with_buffer =
      build_prompt(
        agent_node,
        graph,
        context_window_tokens: baseline_total + 10_000,
        context_soft_limit_tokens: baseline_total + 10,
      )

    assert_equal "soft_limit_reached", with_buffer.metadata.fetch("context_cost").fetch("budget_state")
    refute_equal baseline.metadata.dig("context_budget", "budget_fingerprint"), with_buffer.metadata.dig("context_budget", "budget_fingerprint")

    section =
      with_buffer.metadata
        .dig("context_cost", "prompt_sections", "system_prompt", "sections")
        .find { |entry| entry.dig("metadata", "source") == "lane_prompt_buffer" && entry.dig("metadata", "buffer_name") == "summaries" }

    assert section.present?, "expected lane prompt buffer section in prompt_sections report"
  end

  private

    def estimate_for(agent_node, graph)
      result = build_prompt(agent_node, graph)
      result.metadata.fetch("context_cost").fetch("estimated_tokens").fetch("total")
    end

    def build_prompt(agent_node, graph, **runtime_overrides)
      runtime =
        AgentCore::DAG::Runtime.new(
          provider: Object.new,
          model: "test-model",
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          token_counter: precise_token_counter,
          **runtime_overrides,
        )

      manager =
        AgentCore::DAG::ContextBudgetManager.new(
          node: agent_node,
          runtime: runtime,
          execution_context: AgentCore::DAG::ExecutionContextBuilder.build(node: agent_node, runtime: runtime),
        )

      manager.build_prompt(context_nodes: graph.context_for_full(agent_node.id))
    end

    def precise_token_counter
      AgentCore::Resources::TokenCounter::HeuristicWithOverhead.new(
        chars_per_token: 1.0,
        non_ascii_chars_per_token: 1.0,
        per_message_overhead: 0,
      )
    end

    def build_simple_turn!
      conversation = create_conversation!
      graph = conversation.dag_graph
      turn_id = SecureRandom.uuid
      agent_node = nil

      graph.mutate!(turn_id: turn_id) do |m|
        system_node =
          m.create_node(
            node_type: Messages::SystemMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "BASE_SYSTEM",
            metadata: {},
          )
        user_node =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "Hello",
            metadata: {},
          )
        agent_node =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            metadata: {},
          )

        m.create_edge(from_node: system_node, to_node: user_node, edge_type: DAG::Edge::SEQUENCE)
        m.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
      end

      [agent_node, graph]
    end
end
