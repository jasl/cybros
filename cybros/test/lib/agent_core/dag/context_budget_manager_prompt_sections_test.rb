require "test_helper"
require "securerandom"
require "tmpdir"

class AgentCore::DAG::ContextBudgetManagerPromptSectionsTest < ActiveSupport::TestCase
  test "context_cost includes prompt_sections with system prefix/tail and section metadata" do
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, ".git"))
      File.write(File.join(dir, "AGENTS.md"), "ROOT AGENTS")
      File.write(File.join(dir, "README.md"), "README BODY")

      conversation = Conversation.create!
      graph = conversation.dag_graph

      turn_id = SecureRandom.uuid

      system_node = nil
      user_node = nil
      agent_node = nil

      graph.mutate!(turn_id: turn_id) do |m|
        system_node =
          m.create_node(
            node_type: Messages::SystemMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "SYSTEM_BASE",
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

      tools_registry = AgentCore::Resources::Tools::Registry.new

      repo_docs_source =
        AgentCore::Resources::PromptInjections::Sources::RepoDocs.new(
          filenames: ["AGENTS.md"],
          max_total_bytes: 50_000,
          order: 10,
        )

      file_set_source =
        AgentCore::Resources::PromptInjections::Sources::FileSet.new(
          files: [{ path: "README.md", max_bytes: 100 }],
          order: 20,
          section_header: "Ctx",
        )

      runtime =
        AgentCore::DAG::Runtime.new(
          provider: Object.new,
          model: "test-model",
          tools_registry: tools_registry,
          prompt_injection_sources: [repo_docs_source, file_set_source],
          prompt_mode: :full,
        )

      manager =
        AgentCore::DAG::ContextBudgetManager.new(
          node: agent_node,
          runtime: runtime,
          execution_context: { cwd: dir, workspace_dir: dir },
        )

      context_nodes = graph.context_for_full(agent_node.id)
      result = manager.build_prompt(context_nodes: context_nodes)

      context_cost = result.metadata.fetch("context_cost")
      sections = context_cost.fetch("prompt_sections")

      system_prompt = sections.fetch("system_prompt")
      assert system_prompt.fetch("prefix").key?("sha256")
      assert system_prompt.fetch("tail").key?("sha256")

      system_sections = system_prompt.fetch("sections")
      assert system_sections.any? { |s| s.fetch("id") == "base_system_prompt" }
      assert system_sections.any? { |s| s.fetch("id") == "safety" }
      assert system_sections.any? { |s| s.fetch("id") == "tooling" }
      assert system_sections.any? { |s| s.fetch("id") == "workspace" }
      assert system_sections.any? { |s| s.fetch("id") == "time" }

      time = system_sections.find { |s| s.fetch("id") == "time" }
      assert_equal "tail", time.fetch("stability")

      repo_docs =
        system_sections.find do |s|
          s.fetch("metadata", {}).fetch("source", nil) == "repo_docs"
        end
      assert repo_docs

      files = repo_docs.dig("metadata", "files")
      assert_kind_of Array, files
      assert files.any? { |f| f.fetch("path") == "AGENTS.md" }

      assert sections.fetch("tools_schema").key?("tool_count")
      assert_kind_of Array, sections.fetch("preamble_messages")

      refute system_sections.any? { |s| s.key?("content") }
    end
  end
end
