require "test_helper"
require "securerandom"

class AgentCore::DAG::ContextBudgetManagerRuntimeSurfaceTest < ActiveSupport::TestCase
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

  private

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
