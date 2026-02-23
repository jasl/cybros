# frozen_string_literal: true

require "test_helper"

class AgentCore::PromptBuilder::SystemPromptSectionsBuilderTest < Minitest::Test
  FIXTURES_DIR = File.expand_path("../../fixtures/skills", __dir__)

  def test_memory_changes_do_not_affect_prefix_text
    store = AgentCore::Resources::Skills::FileSystemStore.new(dirs: [FIXTURES_DIR])

    injections = [
      AgentCore::Resources::PromptInjections::Item.new(
        target: :system_section,
        content: "INJECT",
        order: 10,
      ),
    ]

    ctx_1 =
      AgentCore::PromptBuilder::Context.new(
        system_prompt: "BASE",
        prompt_injection_items: injections,
        skills_store: store,
        memory_results: [AgentCore::Resources::Memory::Entry.new(id: "1", content: "MEM_1")],
      )

    ctx_2 =
      AgentCore::PromptBuilder::Context.new(
        system_prompt: "BASE",
        prompt_injection_items: injections,
        skills_store: store,
        memory_results: [AgentCore::Resources::Memory::Entry.new(id: "2", content: "MEM_2")],
      )

    r1 = AgentCore::PromptBuilder::SystemPromptSectionsBuilder.build(context: ctx_1)
    r2 = AgentCore::PromptBuilder::SystemPromptSectionsBuilder.build(context: ctx_2)

    assert_equal r1.prefix_text, r2.prefix_text
    refute_equal r1.tail_text, r2.tail_text

    assert_includes r1.tail_text, "MEM_1"
    assert_includes r2.tail_text, "MEM_2"
    assert_includes r1.prefix_text, "INJECT"
    refute_includes r1.prefix_text, "MEM_1"
    refute_includes r2.prefix_text, "MEM_2"
  end

  def test_injection_with_stability_tail_only_appears_in_tail
    tail_item =
      AgentCore::Resources::PromptInjections::Item.new(
        target: :system_section,
        content: "TAIL_INJECT",
        order: 10,
        metadata: { stability: :tail },
      )

    ctx =
      AgentCore::PromptBuilder::Context.new(
        system_prompt: "BASE",
        prompt_injection_items: [tail_item],
      )

    r = AgentCore::PromptBuilder::SystemPromptSectionsBuilder.build(context: ctx)

    assert_includes r.tail_text, "TAIL_INJECT"
    refute_includes r.prefix_text, "TAIL_INJECT"
  end

  def test_ordering_is_stable_across_sections
    store = AgentCore::Resources::Skills::FileSystemStore.new(dirs: [FIXTURES_DIR])

    memory_entries = [
      AgentCore::Resources::Memory::Entry.new(id: "1", content: "MEM"),
    ]

    items = [
      AgentCore::Resources::PromptInjections::Item.new(
        target: :system_section,
        content: "INJECT_2",
        order: 500,
      ),
      AgentCore::Resources::PromptInjections::Item.new(
        target: :system_section,
        content: "INJECT_1",
        order: 300,
      ),
    ]

    ctx =
      AgentCore::PromptBuilder::Context.new(
        system_prompt: "BASE",
        memory_results: memory_entries,
        prompt_injection_items: items,
        skills_store: store,
      )

    r = AgentCore::PromptBuilder::SystemPromptSectionsBuilder.build(context: ctx)

    prefix = r.prefix_text
    tail = r.tail_text

    idx_mem = tail.index("<relevant_context>")
    idx_i1 = prefix.index("INJECT_1")
    idx_i2 = prefix.index("INJECT_2")
    idx_skills = prefix.index("<available_skills>")

    assert idx_mem && idx_i1 && idx_i2 && idx_skills
    assert_operator idx_i1, :<, idx_i2
    assert_operator idx_i2, :<, idx_skills
  end
end

