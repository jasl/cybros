require "test_helper"
require "fileutils"
require "socket"
require "tmpdir"
require "webrick"
require Rails.root.join("agents/claw/test/support/callback_harness")

class RPCContractTest < ActiveSupport::TestCase
  test "application serves initialize describe health schemas and capabilities" do
    initialize_payload = application.call(method_name: "initialize", params: {})
    describe_payload = application.call(method_name: "agent.describe", params: {})
    health_payload = application.call(method_name: "agent.health", params: {})
    schemas_payload = application.call(method_name: "agent.schemas.get", params: {})
    handshake_payload = application.call(method_name: "capabilities.handshake", params: {})
    refresh_payload = application.call(method_name: "capabilities.refresh", params: { "reason" => "manual" })

    assert_equal "claw", initialize_payload.dig("identity", "agent_program_key")
    assert_equal "deployment:test-claw", initialize_payload.dig("identity", "deployment_fingerprint")
    assert_includes initialize_payload.dig("identity", "supported_methods"), "on_conversation_created"
    assert_includes initialize_payload.dig("identity", "supported_methods"), "on_lane_first_user_message"
    assert_includes initialize_payload.dig("identity", "supported_methods"), "tool.execute"
    assert_equal "Claw", describe_payload.dig("name")
    assert_equal true, health_payload.dig("healthy")
    assert_equal "object", schemas_payload.dig("global_config_schema", "type")
    assert_equal "object", schemas_payload.dig("conversation_config_schema", "type")
    assert_equal "refreshed", handshake_payload.dig("status")
    assert_equal application.agent_capabilities_version, handshake_payload.dig("agent_capabilities_version")
    assert_equal "read", handshake_payload.dig("agent_tool_catalog", 0, "logical_tool_name")
    assert_includes handshake_payload.fetch("agent_tool_catalog").map { |tool| tool.fetch("logical_tool_name") }, "memory_search"
    assert_includes handshake_payload.fetch("agent_tool_catalog").map { |tool| tool.fetch("logical_tool_name") }, "memory_get"
    assert_includes handshake_payload.fetch("agent_tool_catalog").map { |tool| tool.fetch("logical_tool_name") }, "memory_store"
    assert_includes handshake_payload.fetch("agent_tool_catalog").map { |tool| tool.fetch("logical_tool_name") }, "skills_load"
    assert_includes handshake_payload.fetch("agent_tool_catalog").map { |tool| tool.fetch("logical_tool_name") }, "skills_read_file"
    assert_includes handshake_payload.fetch("agent_tool_catalog").map { |tool| tool.fetch("logical_tool_name") }, "skills_catalog_list"
    assert_includes handshake_payload.fetch("agent_tool_catalog").map { |tool| tool.fetch("logical_tool_name") }, "skills_install"
    assert_equal "manual", refresh_payload.dig("refresh_reason")
    assert_equal "read", refresh_payload.dig("agent_tool_catalog", 0, "logical_tool_name")
  end

  test "agent capabilities version changes when the exposed tool surface changes" do
    refute_equal application.agent_capabilities_version, web_disabled_application.agent_capabilities_version
  end

  test "application imports descriptor based attachments" do
    payload =
      application.call(
        method_name: "attachments.import",
        params: {
          "attachments" => [
            {
              "id" => "attachment-1",
              "filename" => "error.png",
              "content_type" => "image/png",
              "byte_size" => 128,
              "digest" => "sha256:abc123",
              "signed_download_url" => "https://example.test/rails/active_storage/blobs/redirect/signed/error.png",
              "workspace" => {
                "conversation_id" => "conversation:test-default",
                "logical_workspace_id" => "workspace:test-default"
              }
            }
          ]
        }
      )

    import = payload.fetch("imports").first

    assert_equal "attachment-1", import.fetch("id")
    assert_equal "attachment_import", import.dig("remote_ref", "kind")
    assert_match %r{\Aattachment-import://attachment-1/}, import.dig("remote_ref", "locator")
    assert_equal "error.png", import.dig("remote_ref", "filename")
  end

  test "before_agent_step returns typed planning with staged mutations and cutover fields" do
    callback = TestSupport::CallbackHarness.new.start
    capability_snapshot = {
      "capability_registry_snapshot_id" => "csnap_fixture",
      "effective_tools" => [
        {
          "logical_tool_name" => "compact_context",
          "effective_tool_id" => "etool_compact",
          "implementation_source" => "kernel",
          "implementation_ref" => "kernel://compact_context"
        },
        {
          "logical_tool_name" => "subagent_spawn",
          "effective_tool_id" => "etool_subagent_spawn",
          "implementation_source" => "kernel",
          "implementation_ref" => "kernel://subagent_spawn"
        }
      ]
    }

    payload =
      application.call(
        method_name: "before_agent_step",
        params: {
          "conversation_id" => "conversation:test-default",
          "execution_target_id" => "target-primary",
          "capability_snapshot" => capability_snapshot,
          "user_input" => "[fixture:stage-state] [fixture:replay-kv] [fixture:switch-target] Verify the workspace status",
          "callback_session" => {
            "endpoint" => callback.rpc_url,
            "bearer" => callback.required_bearer
          }
        }
      )

    assert_equal(
      %w[stage-state replay-kv switch-target],
      payload.dig("planning", "step_plan", "fixture_scenarios")
    )
    assert_match("Verify the workspace status", payload.dig("planning", "step_plan", "summary"))
    assert_equal "clear", payload.dig("planning", "staged_mutations", "prompt_buffer_ops", 0, "op")
    assert_equal({ "tone" => "concise" }, payload.dig("planning", "staged_mutations", "public_settings_patch"))
    assert_equal({ "mode" => "review" }, payload.dig("planning", "staged_mutations", "agent_config_patch"))
    assert_equal 2, payload.dig("planning", "staged_mutations", "kv_ops").size
    assert_equal "surface_callback_harness", payload.dig("planning", "tool_surface", "tool_surface_id")
    assert_equal "target-alternate", payload.dig("planning", "execution_target_proposal", "execution_target_id")
    assert_equal [ "tool_surface.manifest", "execution_target.list" ], callback.calls.map { |call| call.fetch("method") }
  ensure
    callback&.shutdown
  end

  test "before_agent_step assembles live root bootstrap and scope inventory for primary runs without injecting conversation memory bodies" do
    travel_to Time.zone.local(2026, 3, 16, 12, 0, 0) do
      conversation_id = "conversation:test-primary"

      with_workspace(
        {
          "AGENTS.md" => "Live AGENTS\n",
          "SOUL.md" => "Live SOUL\n",
          "USER.md" => "Live USER\n",
          "MEMORY.md" => "Root memory stays optional\n",
          "memory/2026-03-16.md" => "Root daily log\n",
          "conversations/#{conversation_id}/MEMORY.md" => "Conversation memory should not be injected\n",
          "conversations/#{conversation_id}/memory/2026-03-16.md" => "Conversation daily log\n",
          "conversations/#{conversation_id}/.lanes/lane:test-default/MEMORY.md" => "Lane memory should not be injected\n",
        },
      ) do |workspace_root|
        payload =
          workspace_application(workspace_root).call(
            method_name: "before_agent_step",
            params: {
              "user_input" => "Inspect runtime context",
              "selected_model_ref" => "dev/mock-model",
              "effective_permission_mode" => "default",
              "session_context" => session_context_payload(conversation_id: conversation_id, workspace_root: workspace_root),
              "execution_context" => execution_context_payload(conversation_id: conversation_id, execution_scope: "primary", workspace_root: workspace_root),
              "capability_snapshot" => capability_snapshot_payload(%w[read exec memory_search memory_get memory_store])
            },
          )

        system_entry = payload.dig("planning", "staged_mutations", "prompt_buffer_ops", 1, "entry", "content")

        assert_includes system_entry, "## Tooling"
        assert_includes system_entry, "## Safety"
        assert_includes system_entry, "## Workspace"
        assert_includes system_entry, "## Scope Inventory"
        assert_includes system_entry, "## Documentation"
        assert_includes system_entry, "## Current Date & Time"
        assert_includes system_entry, "## Runtime"
        assert_includes system_entry, "<bootstrap_source name=\"AGENTS\">"
        assert_includes system_entry, "<bootstrap_source name=\"SOUL\">"
        assert_includes system_entry, "<bootstrap_source name=\"USER\">"
        assert_includes system_entry, "<bootstrap_source name=\"TOOLS\">"
        assert_includes system_entry, "Live SOUL"
        assert_includes system_entry, "Agent root:"
        assert_includes system_entry, "Conversation path:"
        assert_includes system_entry, "Lane path:"
        assert_includes system_entry, "root MEMORY.md: present"
        assert_includes system_entry, "conversation MEMORY.md: present"
        assert_includes system_entry, "lane MEMORY.md: present"
        refute_includes system_entry, "<bootstrap_source name=\"MEMORY\">"
        refute_includes system_entry, "Conversation memory should not be injected"
        refute_includes system_entry, "Lane memory should not be injected"
        assert_includes system_entry, "Execution scope: primary"
      end
    end
  end

  test "before_agent_step uses minimal bootstrap mode for delegated subagent runs" do
    with_workspace({}) do |workspace_root|
      conversation_id = "conversation:test-subagent"
      subagent = {
        "subagent_id" => SecureRandom.uuid,
        "parent_turn_id" => SecureRandom.uuid,
        "parent_dag_node_id" => SecureRandom.uuid
      }
      payload =
        application.call(
          method_name: "before_agent_step",
          params: {
            "user_input" => "Handle delegated work",
            "selected_model_ref" => "dev/mock-model",
            "effective_permission_mode" => "default",
            "session_context" => session_context_payload(conversation_id: conversation_id, workspace_root: workspace_root),
            "execution_context" =>
              execution_context_payload(
                conversation_id: conversation_id,
                execution_scope: "subagent",
                workspace_root: workspace_root,
                subagent: subagent,
              ),
            "capability_snapshot" => capability_snapshot_payload(%w[read exec memory_search memory_get])
          },
        )

      system_entry = payload.dig("planning", "staged_mutations", "prompt_buffer_ops", 1, "entry", "content")

      assert_includes system_entry, "Execution scope: subagent"
      assert_includes system_entry, "<bootstrap_source name=\"AGENTS\">"
      assert_includes system_entry, "<bootstrap_source name=\"TOOLS\">"
      refute_includes system_entry, "<bootstrap_source name=\"SOUL\">"
      refute_includes system_entry, "<bootstrap_source name=\"USER\">"
      refute_includes system_entry, "<bootstrap_source name=\"MEMORY\">"
      refute_includes system_entry, "## Scope Inventory"
      refute_includes system_entry, "## Documentation"
    end
  end

  test "before_agent_step truncates oversized bootstrap sources and emits a warning surface" do
    with_workspace({}) do |workspace_root|
      conversation_id = "conversation:test-budget"
      oversized_tool_names = Array.new(80) { |index| "tool_#{index}_#{'x' * 180}" }
      payload =
        application.call(
          method_name: "before_agent_step",
          params: {
            "user_input" => "Stay concise",
            "selected_model_ref" => "dev/mock-model",
            "effective_permission_mode" => "default",
            "session_context" => session_context_payload(conversation_id: conversation_id, workspace_root: workspace_root),
            "execution_context" => execution_context_payload(conversation_id: conversation_id, execution_scope: "primary", workspace_root: workspace_root),
            "capability_snapshot" => capability_snapshot_payload(oversized_tool_names)
          },
        )

      system_entry = payload.dig("planning", "staged_mutations", "prompt_buffer_ops", 1, "entry", "content")

      assert_includes system_entry, "## Bootstrap Warning"
      assert_includes system_entry, "[truncated TOOLS]"
      refute_includes system_entry, "tool_79_#{'x' * 180}"
    end
  end

  test "application reads live workspace bootstrap files before bundled prompt templates" do
    Dir.mktmpdir("claw-live-workspace-") do |workspace_root|
      File.write(File.join(workspace_root, "AGENTS.md"), "Live AGENTS\n")
      File.write(File.join(workspace_root, "SOUL.md"), "Live SOUL\n")
      File.write(File.join(workspace_root, "USER.md"), "Live USER\n")
      File.write(File.join(workspace_root, "MEMORY.md"), "Live MEMORY\n")

      application =
        Cybros::Agents::Claw::Application.new(
          source_root: Rails.root.join("agents/claw"),
          workspace_root: workspace_root,
          deployment_key: "claw",
          deployment_fingerprint: "deployment:test-claw",
        )

      assert_equal "Live AGENTS\n", application.prompt_text("agent")
      assert_equal "Live SOUL\n", application.prompt_text("soul")
      assert_equal "Live USER\n", application.prompt_text("user")
      assert_includes application.full_system_prompt, "Live AGENTS"
      assert_includes application.full_system_prompt, "Live SOUL"
      assert_includes application.full_system_prompt, "Live USER"
    end
  end

  test "workspace bootstrap seeds the bundled self-mutate skill into a live agent root" do
    Dir.mktmpdir("claw-live-workspace-") do |workspace_root|
      Agents::WorkspaceBootstrap.seed!(
        source_root: Rails.root.join("agents/claw"),
        destination_root: Pathname.new(workspace_root),
      )

      skill_path = Pathname.new(workspace_root).join("skills/self-mutate/SKILL.md")

      assert_predicate skill_path, :file?
      skill_text = skill_path.read
      assert_includes skill_text, "diff"
      assert_includes skill_text, "confirm"
      assert_includes skill_text, ".history"
      assert_includes skill_text, "next top-level turn"
      assert_includes skill_text, "../../SOUL.md"
      assert_includes skill_text, "../../USER.md"
      assert_includes skill_text, "../../skills/"
    end
  end

  test "tool.execute returns a top-level result payload" do
    payload =
      application.call(
        method_name: "tool.execute",
        params: {
          "tool_call_id" => "call-glob",
          "logical_tool_name" => "glob",
          "implementation_ref" => "claw:glob",
          "arguments" => {
            "pattern" => "**/*"
          }
        }
      )

    assert payload.key?("result")
    assert_kind_of Hash, payload.fetch("result")
  end

  test "tool.execute glob returns workspace-relative matches" do
    with_workspace("lib/example.rb" => "puts :ok\n", "README.md" => "# Test\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "glob",
          implementation_ref: "claw:glob",
          arguments: { "pattern" => "**/*.rb" },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      assert_equal [ "lib/example.rb" ], JSON.parse(result.dig("content", 0, "text")).fetch("matches")
    end
  end

  test "tool.execute search returns path line and snippet matches" do
    with_workspace("app/models/user.rb" => "class User < ApplicationRecord\nend\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "search",
          implementation_ref: "claw:search",
          arguments: { "query" => "ApplicationRecord" },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      match = JSON.parse(result.dig("content", 0, "text")).fetch("matches").sole

      assert_equal "app/models/user.rb", match.fetch("path")
      assert_equal 1, match.fetch("line")
      assert_equal "class User < ApplicationRecord", match.fetch("snippet")
    end
  end

  test "tool.execute read returns file contents" do
    with_workspace("notes/todo.txt" => "ship it\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "read",
          implementation_ref: "claw:read",
          arguments: { "path" => "notes/todo.txt" },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      assert_equal "ship it\n", result.dig("content", 0, "text")
    end
  end

  test "tool.execute write updates a file in the workspace" do
    with_workspace("notes/todo.txt" => "before\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "write",
          implementation_ref: "claw:write",
          arguments: { "path" => "notes/todo.txt", "content" => "after\n" },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      assert_equal "after\n", File.read(File.join(workspace_root, "notes/todo.txt"))
      assert_equal "notes/todo.txt", JSON.parse(result.dig("content", 0, "text")).fetch("path")
    end
  end

  test "tool.execute edit replaces one exact text span in a workspace file" do
    with_workspace("notes/todo.txt" => "before\nkeep\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "edit",
          implementation_ref: "claw:edit",
          arguments: {
            "path" => "notes/todo.txt",
            "old_text" => "before",
            "new_text" => "after"
          },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      assert_equal "after\nkeep\n", File.read(File.join(workspace_root, "notes/todo.txt"))
      assert_equal "notes/todo.txt", JSON.parse(result.dig("content", 0, "text")).fetch("path")
    end
  end

  test "tool.execute edit fails when the match is ambiguous" do
    with_workspace("notes/todo.txt" => "same\nsame\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "edit",
          implementation_ref: "claw:edit",
          arguments: {
            "path" => "notes/todo.txt",
            "old_text" => "same",
            "new_text" => "different"
          },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      assert result.fetch("error")
      assert_includes result.dig("content", 0, "text"), "ambiguous"
      assert_equal "same\nsame\n", File.read(File.join(workspace_root, "notes/todo.txt"))
    end
  end

  test "tool.execute apply_patch applies a multi-line patch atomically inside the workspace" do
    with_workspace("notes/todo.txt" => "before\nkeep\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "apply_patch",
          implementation_ref: "claw:apply_patch",
          arguments: {
            "patch" => <<~PATCH
              --- notes/todo.txt
              +++ notes/todo.txt
              @@ -1,2 +1,2 @@
              -before
              +after
               keep
            PATCH
          },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      assert_equal "after\nkeep\n", File.read(File.join(workspace_root, "notes/todo.txt"))
      assert_equal "modified", JSON.parse(result.dig("content", 0, "text")).fetch("files").sole.fetch("status")
    end
  end

  test "tool.execute apply_patch accepts git-style a slash b headers" do
    with_workspace("notes/todo.txt" => "before\nkeep\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "apply_patch",
          implementation_ref: "claw:apply_patch",
          arguments: {
            "patch" => <<~PATCH
              --- a/notes/todo.txt
              +++ b/notes/todo.txt
              @@ -1,2 +1,2 @@
              -before
              +after
               keep
            PATCH
          },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      assert_equal "after\nkeep\n", File.read(File.join(workspace_root, "notes/todo.txt"))
    end
  end

  test "tool.execute apply_patch accepts codex patch format" do
    with_workspace("notes/todo.txt" => "before\nkeep\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "apply_patch",
          implementation_ref: "claw:apply_patch",
          arguments: {
            "patch" => <<~PATCH
              *** Begin Patch
              *** Update File: notes/todo.txt
              @@
              -before
              +after
               keep
              *** End Patch
            PATCH
          },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      assert_equal "after\nkeep\n", File.read(File.join(workspace_root, "notes/todo.txt"))
      assert_equal "modified", JSON.parse(result.dig("content", 0, "text")).fetch("files").sole.fetch("status")
    end
  end

  test "tool.execute apply_patch accepts codex patch format for a file without a trailing newline" do
    with_workspace("notes/todo.txt" => "one") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "apply_patch",
          implementation_ref: "claw:apply_patch",
          arguments: {
            "patch" => <<~PATCH.chomp
              *** Begin Patch
              *** Update File: notes/todo.txt
              @@
              -one
              +one
              +two
              *** End Patch
            PATCH
          },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      assert_equal "one\ntwo\n", File.read(File.join(workspace_root, "notes/todo.txt"))
    end
  end

  test "tool.execute exec runs a non-interactive command inside the workspace and captures streams" do
    with_workspace("notes/todo.txt" => "workspace\n") do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "exec",
          implementation_ref: "claw:exec",
          arguments: { "command" => "pwd && cat notes/todo.txt && >&2 echo warn" },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")

      parsed = JSON.parse(result.dig("content", 0, "text"))
      assert_equal 0, parsed.fetch("exit_code")
      assert_includes parsed.fetch("stdout"), workspace_root
      assert_includes parsed.fetch("stdout"), "workspace"
      assert_includes parsed.fetch("stderr"), "warn"
    end
  end

  test "tool.execute memory_store defaults to lane scope and memory_get reads the scoped default target" do
    callback = TestSupport::CallbackHarness.new.start

    store_payload =
      tool_execute(
        logical_tool_name: "memory_store",
        implementation_ref: "claw:memory_store",
        arguments: { "content" => "Remember alpha" },
        callback_session: callback_session_payload(callback),
      )

    store_result = store_payload.fetch("result")
    refute store_result.fetch("error")
    assert_equal "lane", JSON.parse(store_result.dig("content", 0, "text")).dig("document", "scope")
    assert_equal "Remember alpha", JSON.parse(store_result.dig("content", 0, "text")).dig("document", "body")

    get_payload =
      tool_execute(
        logical_tool_name: "memory_get",
        implementation_ref: "claw:memory_get",
        arguments: { "scope" => "lane" },
        callback_session: callback_session_payload(callback),
      )

    get_result = get_payload.fetch("result")
    refute get_result.fetch("error")
    assert_equal "lane", JSON.parse(get_result.dig("content", 0, "text")).dig("document", "scope")
    assert_equal "Remember alpha", JSON.parse(get_result.dig("content", 0, "text")).dig("document", "body")
    assert_equal(
      [
        ["conversation.memory.get", "lane"],
        ["conversation.memory.append", "lane"],
        ["conversation.memory.get", "lane"],
      ],
      callback.calls.map { |call| [call.fetch("method"), call.dig("params", "scope")] },
    )
  ensure
    callback&.shutdown
  end

  test "tool.execute memory_search searches lane conversation and root in order with source-aware matches" do
    callback =
      TestSupport::CallbackHarness.new(
        memory_documents: {
          ["lane", "MEMORY.md"] => "Lane alpha",
          ["conversation", "MEMORY.md"] => "Conversation alpha",
          ["root", "MEMORY.md"] => "Root alpha",
        },
      ).start

    payload =
      tool_execute(
        logical_tool_name: "memory_search",
        implementation_ref: "claw:memory_search",
        arguments: { "query" => "alpha" },
        callback_session: callback_session_payload(callback),
      )

    result = payload.fetch("result")
    refute result.fetch("error")

    matches = JSON.parse(result.dig("content", 0, "text")).fetch("matches")
    assert_equal %w[lane conversation root], matches.map { |match| match.fetch("scope") }
    assert_equal [1, 1, 1], matches.map { |match| match.fetch("line") }
    assert_equal(
      [
        ["conversation.memory.get", "lane"],
        ["conversation.memory.get", "conversation"],
        ["conversation.memory.get", "root"],
      ],
      callback.calls.map { |call| [call.fetch("method"), call.dig("params", "scope")] },
    )
    assert matches.all? { |match| match.fetch("path").end_with?("MEMORY.md") }
    assert_equal ["Lane alpha", "Conversation alpha", "Root alpha"], matches.map { |match| match.fetch("snippet") }
  ensure
    callback&.shutdown
  end

  test "tool.execute memory_get fails with a stable error for invalid scopes" do
    callback = TestSupport::CallbackHarness.new.start

    payload =
      tool_execute(
        logical_tool_name: "memory_get",
        implementation_ref: "claw:memory_get",
        arguments: { "scope" => "invalid" },
        callback_session: callback_session_payload(callback),
      )

    result = payload.fetch("result")
    assert_equal true, result.fetch("error")
    assert_equal "claw.memory.invalid_scope", result.dig("metadata", "code")
  ensure
    callback&.shutdown
  end

  test "tool.execute memory_get treats target default as the scoped default document" do
    callback = TestSupport::CallbackHarness.new.start

    store_payload =
      tool_execute(
        logical_tool_name: "memory_store",
        implementation_ref: "claw:memory_store",
        arguments: { "scope" => "conversation", "content" => "Remember beta", "target" => "default" },
        callback_session: callback_session_payload(callback),
      )
    refute store_payload.dig("result", "error")

    get_payload =
      tool_execute(
        logical_tool_name: "memory_get",
        implementation_ref: "claw:memory_get",
        arguments: { "scope" => "conversation", "target" => "default" },
        callback_session: callback_session_payload(callback),
      )

    get_result = get_payload.fetch("result")
    refute get_result.fetch("error")
    assert_equal "Remember beta", JSON.parse(get_result.dig("content", 0, "text")).dig("document", "body")
    assert_equal(
      [
        ["conversation.memory.get", "conversation", nil],
        ["conversation.memory.append", "conversation", nil],
        ["conversation.memory.get", "conversation", nil],
      ],
      callback.calls.map do |call|
        [
          call.fetch("method"),
          call.dig("params", "scope"),
          call.dig("params", "target"),
        ]
      end,
    )
  ensure
    callback&.shutdown
  end

  test "tool.execute skills_catalog_list returns structured catalog entries" do
    with_workspace({}) do |workspace_root|
      Dir.mktmpdir("claw-skill-catalog-") do |catalog_root|
        FileUtils.mkdir_p(File.join(catalog_root, "example-skill"))
        File.write(
          File.join(catalog_root, "example-skill", "SKILL.md"),
          <<~MD,
            ---
            name: example-skill
            description: Example catalog skill
            ---

            # example-skill
          MD
        )

        payload =
          with_skill_catalog_sources([{ "catalog" => "curated", "root" => catalog_root }]) do
            tool_execute(
              logical_tool_name: "skills_catalog_list",
              implementation_ref: "claw:skills_catalog_list",
              arguments: { "catalog" => "curated" },
              workspace_root: workspace_root,
            )
          end

        result = payload.fetch("result")
        refute result.fetch("error")
        assert_equal ["example-skill"], JSON.parse(result.dig("content", 0, "text")).fetch("entries").map { |entry| entry.fetch("name") }
      end
    end
  end

  test "tool.execute skills_load returns the installed skill body and files index" do
    with_workspace(
      "skills/example-skill/SKILL.md" => <<~MD,
        ---
        name: example-skill
        description: Example installed skill
        ---

        # example-skill

        Use this skill when the user asks for the example token.
      MD
      "skills/example-skill/references/answer.txt" => "EXAMPLE_TOKEN\n",
    ) do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "skills_load",
          implementation_ref: "claw:skills_load",
          arguments: { "name" => "example-skill" },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")

      parsed = JSON.parse(result.dig("content", 0, "text"))
      assert_equal "example-skill", parsed.dig("meta", "name")
      assert_equal "Example installed skill", parsed.dig("meta", "description")
      assert_includes parsed.fetch("body_markdown"), "Use this skill when the user asks for the example token."
      assert_equal ["references/answer.txt"], parsed.dig("files_index", "references")
    end
  end

  test "tool.execute skills_read_file reads files from installed skills" do
    with_workspace(
      "skills/example-skill/SKILL.md" => <<~MD,
        ---
        name: example-skill
        description: Example installed skill
        ---

        # example-skill
      MD
      "skills/example-skill/references/answer.txt" => "EXAMPLE_TOKEN\n",
    ) do |workspace_root|
      payload =
        tool_execute(
          logical_tool_name: "skills_read_file",
          implementation_ref: "claw:skills_read_file",
          arguments: { "name" => "example-skill", "rel_path" => "references/answer.txt" },
          workspace_root: workspace_root,
        )

      result = payload.fetch("result")
      refute result.fetch("error")
      assert_equal "EXAMPLE_TOKEN\n", result.dig("content", 0, "text")
    end
  end

  test "tool.execute skills_install returns a stable validation error for platform collisions" do
    with_workspace({}) do |workspace_root|
      Dir.mktmpdir("claw-platform-skills-") do |platform_skills_root|
        FileUtils.mkdir_p(File.join(platform_skills_root, "platform-skill"))
        File.write(
          File.join(platform_skills_root, "platform-skill", "SKILL.md"),
          <<~MD,
            ---
            name: platform-skill
            description: Platform collision
            ---

            # platform-skill
          MD
        )

        payload =
          with_platform_skill_dirs([platform_skills_root]) do
            tool_execute(
              logical_tool_name: "skills_install",
              implementation_ref: "claw:skills_install",
              arguments: {
                "source_kind" => "github",
                "repo" => "https://github.com/openai/skills",
                "path" => "skills/example-skill",
                "install_as" => "platform-skill",
              },
              workspace_root: workspace_root,
            )
          end

        result = payload.fetch("result")
        assert_equal true, result.fetch("error")
        assert_equal "cybros.skills_install.destination_conflicts_with_platform_skill", result.dig("metadata", "code")
      end
    end
  end

  test "tool.execute skills_install returns the normalized batch result shape for repo-root installs" do
    with_workspace({}) do |workspace_root|
      Dir.mktmpdir("claw-local-skill-repo-") do |repo_root|
        write_skill_fixture!(Pathname.new(repo_root).join("skills"), name: "alpha-skill", description: "Alpha description")
        write_skill_fixture!(Pathname.new(repo_root).join("skills/.system"), name: "system-helper", description: "System helper")

        payload =
          tool_execute(
            logical_tool_name: "skills_install",
            implementation_ref: "claw:skills_install",
            arguments: {
              "source_kind" => "github",
              "repo" => repo_root,
            },
            workspace_root: workspace_root,
          )

        result = payload.fetch("result")
        refute result.fetch("error")

        parsed = JSON.parse(result.dig("content", 0, "text"))
        assert_equal "repo_root_batch", parsed.fetch("mode")
        assert_equal 2, parsed.fetch("installed_count")
        assert_equal true, parsed.fetch("refresh_effective_on_next_top_level_turn")
        assert_equal ["skills/.system/system-helper", "skills/alpha-skill"], parsed.fetch("installed_skills").map { |entry| entry.fetch("source_path") }
        parsed.fetch("installed_skills").each do |entry|
          refute entry.key?("live_path")
          refute entry.key?("provenance_path")
          refute entry.key?("snapshot_path")
        end
      end
    end
  end

  test "tool.execute skills_install returns a stable batch validation error when repo-root discovery finds no skills" do
    with_workspace({}) do |workspace_root|
      Dir.mktmpdir("claw-empty-skill-repo-") do |repo_root|
        File.write(Pathname.new(repo_root).join("README.md"), "# not a skill repo\n")

        payload =
          tool_execute(
            logical_tool_name: "skills_install",
            implementation_ref: "claw:skills_install",
            arguments: {
              "source_kind" => "github",
              "repo" => repo_root,
            },
            workspace_root: workspace_root,
          )

        result = payload.fetch("result")
        assert_equal true, result.fetch("error")
        assert_equal "cybros.skills_install.invalid_skill_root", result.dig("metadata", "code")
      end
    end
  end

  test "tool.execute web_search returns structured search results when a backend is configured" do
    with_web_backend_server do |server|
      payload =
        web_enabled_application(
          web_search_endpoint: "#{server[:base_url]}/search",
        ).call(
          method_name: "tool.execute",
          params: {
            "tool_call_id" => "call-web-search",
            "logical_tool_name" => "web_search",
            "implementation_ref" => "claw:web_search",
            "arguments" => {
              "query" => "claw runtime",
              "count" => 2
            }
          },
        )

      result = payload.fetch("result")
      refute result.fetch("error")

      parsed = JSON.parse(result.dig("content", 0, "text"))
      first = parsed.fetch("results").first

      assert_equal "https://example.test/claw", first.fetch("url")
      assert_equal "Claw Runtime Guide", first.fetch("title")
      assert_includes first.fetch("snippet"), "runtime"
    end
  end

  test "tool.execute web_fetch returns structured page content" do
    with_web_backend_server do |server|
      payload =
        web_enabled_application.call(
          method_name: "tool.execute",
          params: {
            "tool_call_id" => "call-web-fetch",
            "logical_tool_name" => "web_fetch",
            "implementation_ref" => "claw:web_fetch",
            "arguments" => {
              "url" => "#{server[:base_url]}/page"
            }
          },
        )

      result = payload.fetch("result")
      refute result.fetch("error")

      parsed = JSON.parse(result.dig("content", 0, "text"))
      assert_equal "#{server[:base_url]}/page", parsed.fetch("url")
      assert_equal "Claw Runtime Guide", parsed.fetch("title")
      assert_includes parsed.fetch("content"), "OpenClaw-style tooling"
    end
  end

  test "web tools disappear from the catalog and return a disabled error when no backend is configured" do
    tool_names = web_disabled_application.agent_tool_catalog.map { |tool| tool.fetch("logical_tool_name") }

    refute_includes tool_names, "web_search"
    refute_includes tool_names, "web_fetch"

    payload =
      web_disabled_application.call(
        method_name: "tool.execute",
        params: {
          "tool_call_id" => "call-web-search",
          "logical_tool_name" => "web_search",
          "implementation_ref" => "claw:web_search",
          "arguments" => {
            "query" => "claw runtime"
          }
        },
      )

    result = payload.fetch("result")
    assert result.fetch("error")
    assert_includes result.dig("content", 0, "text"), "disabled"
  end

  test "bootstrap and lifecycle hooks return claw-compatible action envelopes" do
    conversation_payload =
      application.call(
        method_name: "on_conversation_created",
        params: {
          "conversation_id" => "conversation:test-default",
          "conversation_kind" => "root",
          "agent_key" => "main",
          "lane_id" => "lane-main"
        }
      )
    lane_payload =
      application.call(
        method_name: "on_lane_first_user_message",
        params: {
          "conversation_id" => "conversation:branch",
          "conversation_kind" => "branch",
          "lane_id" => "lane-branch",
          "lane_role" => "branch",
          "agent_key" => "main",
          "user_node_id" => "message-branch-1"
        }
      )
    context_pressure_payload =
      application.call(
        method_name: "on_context_pressure",
        params: {
          "context_pressure" => {
            "budget_state" => "soft_limit_reached",
            "budget_action" => "advise_compact"
          },
          "provider_input" => {
            "tools" => [
              {
                "name" => "compact_context",
                "logical_tool_name" => "compact_context"
              }
            ]
          }
        }
      )
    before_subagent_payload =
      application.call(
        method_name: "before_subagent_spawn",
        params: {
          "subagent_request" => {
            "tool_name" => "subagent_run"
          }
        }
      )
    finalize_payload =
      application.call(
        method_name: "before_finalize_output",
        params: {
          "draft_output" => {
            "content" => "Draft output from the model"
          }
        }
      )
    task_notice_payload =
      application.call(
        method_name: "after_task_notice",
        params: {
          "task_notice" => {
            "task_id" => "task-456",
            "subject_kind" => "task",
            "status" => "failed",
            "notice" => {
              "kind" => "remote_tool_failed"
            },
            "logical_tool_name" => "shell_exec",
            "error" => {
              "class" => "RuntimeError",
              "message" => "shell_exec crashed"
            }
          }
        }
      )
    subagent_payload =
      application.call(
        method_name: "after_subagent_result",
        params: {
          "subagent_result" => {
            "subagent_id" => "subagent-123",
            "status" => "succeeded",
            "assistant_output_candidate" => {
              "scope" => "partial"
            }
          }
        }
      )

    assert_equal "create_task", conversation_payload.dig("actions", 0, "type")
    assert_equal [ "cybros_generate_title", "cybros_enqueue_lane_summary" ], lane_payload.fetch("actions").map { |action| action["logical_tool_name"] }
    assert_equal "create_task", context_pressure_payload.dig("actions", 1, "type")
    assert_equal "set_step_status", before_subagent_payload.dig("actions", 0, "type")
    assert_equal "emit_message", finalize_payload.dig("actions", 0, "type")
    assert_equal "Draft output from the model", finalize_payload.dig("actions", 0, "message", "content")
    assert_equal "set_step_status", task_notice_payload.dig("actions", 0, "type")
    assert_includes task_notice_payload.dig("actions", 0, "text"), "shell_exec crashed"
    assert_equal "set_step_status", subagent_payload.dig("actions", 0, "type")
    assert_includes subagent_payload.dig("actions", 0, "text"), "subagent-123"
  end

  test "before_finalize_output maps exact NO_REPLY to an explicit silent finish action" do
    payload =
      application.call(
        method_name: "before_finalize_output",
        params: {
          "draft_output" => {
            "content" => "NO_REPLY"
          }
        }
      )

    assert_equal "finish_silently", payload.dig("actions", 0, "type")
    assert_equal "silent_reply", payload.dig("actions", 0, "reason")
  end

  test "before_finalize_output strips a trailing NO_REPLY token from mixed content" do
    payload =
      application.call(
        method_name: "before_finalize_output",
        params: {
          "draft_output" => {
            "content" => "Memory flush complete. NO_REPLY"
          }
        }
      )

    assert_equal "emit_message", payload.dig("actions", 0, "type")
    assert_equal "Memory flush complete.", payload.dig("actions", 0, "message", "content")
  end

  test "on_context_pressure prepends memory_store before compact_context when memory tools are available" do
    payload =
      application.call(
        method_name: "on_context_pressure",
        params: {
          "context_pressure" => {
            "budget_state" => "soft_limit_reached",
            "budget_action" => "advise_compact"
          },
          "provider_input" => {
            "tools" => [
              {
                "name" => "memory_store",
                "logical_tool_name" => "memory_store"
              },
              {
                "name" => "compact_context",
                "logical_tool_name" => "compact_context"
              }
            ]
          }
        }
      )

    assert_equal "create_task", payload.dig("actions", 1, "type")
    assert_equal "memory_store", payload.dig("actions", 1, "logical_tool_name")
    assert_equal "prepend", payload.dig("actions", 1, "placement")
    assert_equal "create_task", payload.dig("actions", 2, "type")
    assert_equal "compact_context", payload.dig("actions", 2, "logical_tool_name")
  end

  test "unsupported methods raise the claw-compatible key error" do
    error = assert_raises(KeyError) do
      application.call(method_name: "agent.unsupported", params: {})
    end

    assert_includes error.message, "unsupported bundled claw RPC method"
  end

  private

  def tool_execute(logical_tool_name:, implementation_ref:, arguments:, workspace_root: nil, callback_session: nil)
    params = {
      "tool_call_id" => "call-#{logical_tool_name}",
      "logical_tool_name" => logical_tool_name,
      "implementation_ref" => implementation_ref,
      "arguments" => arguments
    }
    params["callback_session"] = callback_session if callback_session
    if workspace_root
      workspace_payload = {
        "conversation_id" => "conversation:test-default",
        "logical_workspace_key" => "conversation-test-default",
        "logical_workspace_root_path" => workspace_root
      }
      params["session_context"] = { "workspace" => workspace_payload }
      params["execution_context"] = { "workspace" => workspace_payload }
    end

    application.call(method_name: "tool.execute", params: params)
  end

  def callback_session_payload(callback)
    {
      "endpoint" => callback.rpc_url,
      "bearer" => callback.required_bearer
    }
  end

  def session_context_payload(conversation_id:, workspace_root:)
    conversation_path = File.join(workspace_root, "conversations", conversation_id)
    lane_path = File.join(conversation_path, ".lanes", "lane:test-default")

    {
      "account_id" => "account:test-default",
      "user_id" => "user:test-default",
      "conversation_id" => conversation_id,
      "workspace" => {
        "conversation_id" => conversation_id,
        "root_path" => workspace_root,
        "conversation_path" => conversation_path,
        "lane_path" => lane_path,
        "cwd" => conversation_path,
        "logical_workspace_key" => "conversation-#{conversation_id.tr(':', '-')}",
        "logical_workspace_root_path" => conversation_path,
        "logical_workspace_initialized_at" => Time.current.change(usec: 0).iso8601
      }
    }
  end

  def execution_context_payload(conversation_id:, execution_scope:, workspace_root:, subagent: nil)
    conversation_path = File.join(workspace_root, "conversations", conversation_id)
    lane_path = File.join(conversation_path, ".lanes", "lane:test-default")

    payload = {
      "account_id" => "account:test-default",
      "user_id" => "user:test-default",
      "conversation_id" => conversation_id,
      "graph_id" => "graph:test-default",
      "lane_id" => "lane:test-default",
      "turn_id" => SecureRandom.uuid,
      "dag_node_id" => SecureRandom.uuid,
      "execution_scope" => execution_scope,
      "workspace" => {
        "conversation_id" => conversation_id,
        "root_path" => workspace_root,
        "conversation_path" => conversation_path,
        "lane_path" => lane_path,
        "cwd" => conversation_path,
      },
    }
    payload["subagent"] = subagent if subagent
    payload
  end

  def capability_snapshot_payload(tool_names)
    {
      "capability_registry_snapshot_id" => "csnap_fixture",
      "effective_tools" =>
        Array(tool_names).map do |tool_name|
          {
            "logical_tool_name" => tool_name,
            "effective_tool_id" => "etool_#{tool_name}",
            "implementation_source" => "agent",
            "implementation_ref" => "claw:#{tool_name}"
          }
        end
    }
  end

  def with_workspace(files)
    Dir.mktmpdir("claw-workspace-") do |dir|
      files.each do |relative_path, content|
        absolute_path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        File.write(absolute_path, content)
      end

      yield dir
    end
  end

  def write_skill_fixture!(root, name:, description:)
    skill_dir = Pathname.new(root).join(name)
    FileUtils.mkdir_p(skill_dir)
    File.write(
      skill_dir.join("SKILL.md"),
      <<~MD,
        ---
        name: #{name}
        description: #{description}
        ---

        # #{name}
      MD
    )
  end

  def with_skill_catalog_sources(sources)
    singleton = RuntimeSetting.singleton_class
    original_method = singleton.instance_method(:skill_catalog_sources)
    singleton.send(:define_method, :skill_catalog_sources) { sources }
    yield
  ensure
    singleton.send(:define_method, :skill_catalog_sources, original_method)
  end

  def with_platform_skill_dirs(dirs)
    singleton = Agents::SkillsStoreBuilder.singleton_class
    original_method = singleton.instance_method(:default_platform_skill_dirs)
    singleton.send(:define_method, :default_platform_skill_dirs) { dirs }
    yield
  ensure
    singleton.send(:define_method, :default_platform_skill_dirs, original_method)
  end

  def application
    @application ||=
      Cybros::Agents::Claw::Application.new(
        source_root: claw_source_root,
        deployment_fingerprint: "deployment:test-claw",
        required_bearer: "secret://agent"
      )
  end

  def workspace_application(workspace_root)
    Cybros::Agents::Claw::Application.new(
      source_root: claw_source_root,
      workspace_root: workspace_root,
      deployment_fingerprint: "deployment:test-claw",
      required_bearer: "secret://agent",
    )
  end

  def web_enabled_application(web_search_endpoint: nil)
    Cybros::Agents::Claw::Application.new(
      source_root: claw_source_root,
      deployment_fingerprint: "deployment:test-claw",
      required_bearer: "secret://agent",
      web_search_backend: "duckduckgo_html",
      web_search_endpoint: web_search_endpoint,
    )
  end

  def web_disabled_application
    Cybros::Agents::Claw::Application.new(
      source_root: claw_source_root,
      deployment_fingerprint: "deployment:test-claw",
      required_bearer: "secret://agent",
      web_search_backend: "disabled",
    )
  end

  def with_web_backend_server
    server =
      WEBrick::HTTPServer.new(
        BindAddress: "127.0.0.1",
        Port: 0,
        AccessLog: [],
        Logger: WEBrick::Log.new(File::NULL),
      )
    server.mount_proc "/search" do |_req, res|
      res["Content-Type"] = "text/html"
      res.body = <<~HTML
        <html>
          <body>
            <div class="result">
              <a class="result__a" href="https://example.test/claw">Claw Runtime Guide</a>
              <a class="result__snippet">OpenClaw-style runtime notes for Cybros.</a>
            </div>
            <div class="result">
              <a class="result__a" href="https://example.test/memory">Memory Guide</a>
              <a class="result__snippet">Conversation memory and recall.</a>
            </div>
          </body>
        </html>
      HTML
    end
    server.mount_proc "/page" do |_req, res|
      res["Content-Type"] = "text/html"
      res.body = <<~HTML
        <html>
          <head>
            <title>Claw Runtime Guide</title>
          </head>
          <body>
            <main>
              <h1>Claw Runtime Guide</h1>
              <p>OpenClaw-style tooling for Cybros runs on the agent-owned execution spine.</p>
            </main>
          </body>
        </html>
      HTML
    end

    thread = Thread.new { server.start }
    wait_for_webrick!(server.config.fetch(:Port))
    yield(base_url: "http://127.0.0.1:#{server.config.fetch(:Port)}")
  ensure
    server&.shutdown
    thread&.join(2)
  end

  def wait_for_webrick!(port)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    loop do
      begin
        socket = TCPSocket.new("127.0.0.1", port)
        socket.close
        return
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        raise "web backend server failed to start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end
  end

  def claw_source_root
    Rails.root.join("agents/claw")
  end
end
