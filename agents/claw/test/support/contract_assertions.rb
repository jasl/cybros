module TestSupport
  module ContractAssertions
    REQUIRED_METHODS = %w[
      initialize
      agent.describe
      agent.health
      agent.schemas.get
      capabilities.handshake
      capabilities.refresh
      attachments.import
      tool.execute
      on_conversation_created
      on_lane_first_user_message
      before_agent_step
      on_context_pressure
      before_subagent_spawn
      before_finalize_output
      after_task_notice
      after_subagent_result
    ].freeze

    def assert_manifest_contract(
      manifest,
      expected_agent_program_key:,
      expected_name:,
      expected_description:,
      expected_config_namespace:,
      expected_agent_sdk_version:
    )
      assert_equal expected_agent_program_key, manifest.fetch("agent_program_key")
      assert_equal expected_name, manifest.fetch("name")
      assert_equal expected_description, manifest.fetch("description")
      assert_equal expected_config_namespace, manifest.fetch("config_namespace")
      assert_equal "agent_rpc.v1", manifest.fetch("protocol_version")
      assert_equal expected_agent_sdk_version, manifest.fetch("agent_sdk_version")
      assert_equal REQUIRED_METHODS, manifest.fetch("supported_methods")
      assert_equal({ "type" => "object", "properties" => {} }, manifest.fetch("global_config_schema"))
      assert_equal({ "type" => "object", "properties" => {} }, manifest.fetch("conversation_config_schema"))
      assert_equal "prompts/system.md.liquid", manifest.dig("prompts", "system")
      refute manifest.key?("runtime_surface")
    end

    module RPCSnapshot
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

      module_function

      def capture(rpc_url:, bearer:, cached_agent_capabilities_version: "claw-agent-capabilities:v1")
        callback = TestSupport::CallbackHarness.new.start

        normalize(
          {
            "health" => exchange(http_get(health_url(rpc_url))),
            "invalid_bearer" => exchange(http_post(rpc_url, body: rpc_body(id: 90, method: "agent.health", params: {}), authorization: "Bearer wrong://agent")),
            "malformed_json" => exchange(http_post(rpc_url, body: "{\"jsonrpc\":", authorization: "Bearer #{bearer}")),
            "unsupported_method" => exchange(http_post(rpc_url, body: rpc_body(id: 91, method: "agent.unsupported", params: {}),
                                                       authorization: "Bearer #{bearer}")),
            "initialize" => exchange(http_post(rpc_url, body: rpc_body(id: 1, method: "initialize", params: {}),
                                               authorization: "Bearer #{bearer}")),
            "describe" => exchange(http_post(rpc_url, body: rpc_body(id: 2, method: "agent.describe", params: {}),
                                             authorization: "Bearer #{bearer}")),
            "agent_health" => exchange(http_post(rpc_url, body: rpc_body(id: 3, method: "agent.health", params: {}),
                                                 authorization: "Bearer #{bearer}")),
            "schemas" => exchange(http_post(rpc_url, body: rpc_body(id: 4, method: "agent.schemas.get", params: {}),
                                             authorization: "Bearer #{bearer}")),
            "handshake" => exchange(http_post(rpc_url, body: rpc_body(id: 5, method: "capabilities.handshake", params: {}),
                                               authorization: "Bearer #{bearer}")),
            "handshake_unchanged" => exchange(
              http_post(
                rpc_url,
                body: rpc_body(id: 6, method: "capabilities.handshake",
                               params: { "cached_agent_capabilities_version" => cached_agent_capabilities_version }),
                authorization: "Bearer #{bearer}"
              )
            ),
            "refresh" => exchange(http_post(rpc_url, body: rpc_body(id: 7, method: "capabilities.refresh", params: { "reason" => "manual" }),
                                             authorization: "Bearer #{bearer}")),
            "attachments_import" => exchange(
              http_post(
                rpc_url,
                body: rpc_body(
                  id: 8,
                  method: "attachments.import",
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
                ),
                authorization: "Bearer #{bearer}"
              )
            ),
            "before_agent_step" => exchange(
              http_post(
                rpc_url,
                body: rpc_body(
                  id: 9,
                  method: "before_agent_step",
                  params: {
                    "conversation_id" => "conversation:test-default",
                    "capability_snapshot" => {
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
                    },
                    "user_input" => "Verify the workspace status",
                    "callback_session" => {
                      "endpoint" => callback.rpc_url,
                      "bearer" => callback.required_bearer
                    }
                  }
                ),
                authorization: "Bearer #{bearer}"
              )
            ),
            "bootstrap_hooks" => {
              "on_conversation_created" => exchange(
                http_post(
                  rpc_url,
                  body: rpc_body(
                    id: 10,
                    method: "on_conversation_created",
                    params: {
                      "conversation_id" => "conversation:test-default",
                      "conversation_kind" => "root",
                      "agent_key" => "main",
                      "lane_id" => "lane-main"
                    }
                  ),
                  authorization: "Bearer #{bearer}"
                )
              ),
              "on_lane_first_user_message_main" => exchange(
                http_post(
                  rpc_url,
                  body: rpc_body(
                    id: 11,
                    method: "on_lane_first_user_message",
                    params: {
                      "conversation_id" => "conversation:test-default",
                      "lane_id" => "lane-main",
                      "lane_role" => "main",
                      "agent_key" => "main",
                      "user_node_id" => "message-1"
                    }
                  ),
                  authorization: "Bearer #{bearer}"
                )
              ),
              "on_lane_first_user_message_branch" => exchange(
                http_post(
                  rpc_url,
                  body: rpc_body(
                    id: 12,
                    method: "on_lane_first_user_message",
                    params: {
                      "conversation_id" => "conversation:branch",
                      "conversation_kind" => "branch",
                      "lane_id" => "lane-branch",
                      "lane_role" => "branch",
                      "agent_key" => "main",
                      "user_node_id" => "message-branch-1"
                    }
                  ),
                  authorization: "Bearer #{bearer}"
                )
              )
            },
            "before_agent_step_workspace" => exchange(
              http_post(
                rpc_url,
                body: rpc_body(
                  id: 13,
                  method: "before_agent_step",
                  params: {
                    "user_input" => "Review the uploaded files",
                    "session_context" => {
                      "workspace" => {
                        "conversation_id" => "conversation:test-default",
                        "logical_workspace_key" => "conversation-conversation:test-default",
                        "logical_workspace_root_path" => "/tmp/cybros/conversations/conversation:test-default",
                        "logical_workspace_initialized_at" => "2026-03-13T09:00:00Z"
                      }
                    },
                    "attachment_manifest" => [
                      {
                        "id" => "attachment-1",
                        "filename" => "screenshot-error.png",
                        "content_type" => "image/png"
                      },
                      {
                        "id" => "attachment-2",
                        "filename" => "logs.txt",
                        "content_type" => "text/plain"
                      }
                    ]
                  }
                ),
                authorization: "Bearer #{bearer}"
              )
            ),
            "lifecycle_hooks" => {
              "on_context_pressure" => exchange(
                http_post(
                  rpc_url,
                  body: rpc_body(
                    id: 15,
                    method: "on_context_pressure",
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
                  ),
                  authorization: "Bearer #{bearer}"
                )
              ),
              "before_subagent_spawn" => exchange(
                http_post(
                  rpc_url,
                  body: rpc_body(
                    id: 16,
                    method: "before_subagent_spawn",
                    params: {
                      "subagent_request" => {
                        "tool_name" => "subagent_run",
                        "tool_call_id" => "tc_subagent",
                        "arguments" => {
                          "name" => "researcher",
                          "prompt" => "Investigate the repo"
                        }
                      }
                    }
                  ),
                  authorization: "Bearer #{bearer}"
                )
              ),
              "before_finalize_output" => exchange(
                http_post(
                  rpc_url,
                  body: rpc_body(
                    id: 17,
                    method: "before_finalize_output",
                    params: {
                      "execution_target_id" => "target-primary",
                      "capability_registry_snapshot_id" => "csnap_fixture",
                      "execution_context" => {
                        "conversation_id" => "conversation:test-default"
                      },
                      "planning" => {
                        "step_plan" => {
                          "summary" => "inspect the current repository status"
                        }
                      },
                      "provider_input" => {
                        "messages" => [
                          { "role" => "user", "content" => "Can you summarize what you are about to do?" }
                        ],
                        "tools" => [
                          {
                            "name" => "compact_context",
                            "description" => "compact",
                            "parameters" => {},
                            "logical_tool_name" => "compact_context",
                            "effective_tool_id" => "etool_compact",
                            "implementation_source" => "agent_program",
                            "implementation_ref" => "agent://compact_context"
                          }
                        ]
                      },
                      "draft_output" => {
                        "content" => "Draft output from the model"
                      }
                    }
                  ),
                  authorization: "Bearer #{bearer}"
                )
              ),
              "after_task_notice_agent_step" => exchange(
                http_post(
                  rpc_url,
                  body: rpc_body(
                    id: 18,
                    method: "after_task_notice",
                    params: {
                      "planning" => {
                        "step_plan" => {
                          "summary" => "inspect the current repository status"
                        }
                      },
                      "provider_input" => {
                        "messages" => [
                          { "role" => "user", "content" => "Please run the checks." }
                        ]
                      },
                      "task_notice" => {
                        "task_id" => "task-123",
                        "subject_kind" => "agent_step",
                        "status" => "failed",
                        "notice" => {
                          "kind" => "provider_error"
                        },
                        "error" => {
                          "class" => "RuntimeError",
                          "message" => "tool execution crashed"
                        }
                      }
                    }
                  ),
                  authorization: "Bearer #{bearer}"
                )
              ),
              "after_task_notice_task" => exchange(
                http_post(
                  rpc_url,
                  body: rpc_body(
                    id: 19,
                    method: "after_task_notice",
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
                  ),
                  authorization: "Bearer #{bearer}"
                )
              ),
              "after_subagent_result" => exchange(
                http_post(
                  rpc_url,
                  body: rpc_body(
                    id: 20,
                    method: "after_subagent_result",
                    params: {
                      "subagent_result" => {
                        "subagent_id" => "subagent-123",
                        "status" => "succeeded",
                        "assistant_output_candidate" => {
                          "format" => "text",
                          "content" => "Candidate answer from the worker",
                          "scope" => "partial"
                        }
                      }
                    }
                  ),
                  authorization: "Bearer #{bearer}"
                )
              )
            }
          }
        )
      ensure
        callback&.shutdown
      end

      def exchange(response)
        {
          "status" => response.code,
          "body" => JSON.parse(response.body)
        }
      end

      def rpc_body(id:, method:, params:)
        JSON.generate({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
      end

      def health_url(rpc_url)
        uri = URI(rpc_url)
        uri.path = "/health"
        uri.query = nil
        uri.to_s
      end

      def http_get(url)
        uri = URI(url)
        request = Net::HTTP::Get.new(uri)
        Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      end

      def http_post(url, body:, authorization:)
        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = authorization
        request.body = body

        Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      end

      def normalize(value)
        case value
        when Hash
          value.transform_values { |child| normalize(child) }
        when Array
          value.map { |child| normalize(child) }
        when String
          value.match?(UUID_PATTERN) ? "<uuid>" : value
        else
          value
        end
      end
    end

    module RPCHostContract
      def test_get_health_serves_identity_without_bearer
        host = build_host.start

        response = http_get(health_url(host))
        payload = assert_json_response(response, status: "200")

        assert_equal true, payload.fetch("ok")
        assert_equal "healthy", payload.fetch("status")
        assert_identity_payload(payload.fetch("identity"))
      ensure
        host&.shutdown
      end

      def test_post_rpc_rejects_invalid_bearer
        host = build_host.start

        response =
          http_post(
            host.rpc_url,
            body: rpc_body(id: 90, method: "agent.health", params: {}),
            authorization: "Bearer wrong://agent"
          )
        payload = assert_json_response(response, status: "500")

        assert_equal "2.0", payload.fetch("jsonrpc")
        assert_nil payload.fetch("id")
        assert_equal(-32_000, payload.dig("error", "code"))
        assert_equal "invalid bearer", payload.dig("error", "message")
      ensure
        host&.shutdown
      end

      def test_post_rpc_rejects_malformed_json
        host = build_host.start

        response = http_post(host.rpc_url, body: "{\"jsonrpc\":", authorization: bearer_header)
        payload = assert_json_response(response, status: "400")

        assert_equal "2.0", payload.fetch("jsonrpc")
        assert_nil payload.fetch("id")
        assert_equal(-32_700, payload.dig("error", "code"))
        refute_empty payload.dig("error", "message").to_s
      ensure
        host&.shutdown
      end

      def test_post_rpc_rejects_unsupported_method
        host = build_host.start

        response = http_post(host.rpc_url, body: rpc_body(id: 91, method: "agent.unsupported", params: {}),
                                           authorization: bearer_header)
        payload = assert_json_response(response, status: "404")

        assert_equal "2.0", payload.fetch("jsonrpc")
        assert_nil payload.fetch("id")
        assert_equal(-32_601, payload.dig("error", "code"))
        assert_includes payload.dig("error", "message"), "agent.unsupported"
      ensure
        host&.shutdown
      end

      def test_http_json_rpc_serves_initialize_describe_health_schemas_and_capabilities
        host = build_host.start

        initialize_payload = rpc_json(host.rpc_url, id: 1, method: "initialize", params: {})
        describe_payload = rpc_json(host.rpc_url, id: 2, method: "agent.describe", params: {})
        health_payload = rpc_json(host.rpc_url, id: 3, method: "agent.health", params: {})
        schemas_payload = rpc_json(host.rpc_url, id: 4, method: "agent.schemas.get", params: {})
        handshake_payload = rpc_json(host.rpc_url, id: 5, method: "capabilities.handshake", params: {})
        unchanged_payload =
          rpc_json(
            host.rpc_url,
            id: 6,
            method: "capabilities.handshake",
            params: { "cached_agent_capabilities_version" => expected_agent_capabilities_version }
          )
        refresh_payload = rpc_json(host.rpc_url, id: 7, method: "capabilities.refresh", params: { "reason" => "manual" })

        assert_identity_payload(initialize_payload.dig("result", "identity"))
        assert_equal expected_agent_program_key, initialize_payload.dig("result", "agent", "key")
        assert_equal expected_agent_name, initialize_payload.dig("result", "agent", "name")
        assert_equal expected_deployment_key, initialize_payload.dig("result", "deployment", "key")
        assert_equal expected_deployment_fingerprint, initialize_payload.dig("result", "deployment", "fingerprint")

        assert_equal expected_agent_name, describe_payload.dig("result", "name")
        assert_equal expected_agent_description, describe_payload.dig("result", "description")
        assert_identity_payload(describe_payload.dig("result", "identity"))

        assert_equal true, health_payload.dig("result", "healthy")
        assert_equal "healthy", health_payload.dig("result", "status")
        assert_identity_payload(health_payload.dig("result", "identity"))

        assert_equal "object", schemas_payload.dig("result", "global_config_schema", "type")
        assert_equal "object", schemas_payload.dig("result", "conversation_config_schema", "type")

        assert_equal "refreshed", handshake_payload.dig("result", "status")
        assert_equal expected_agent_capabilities_version, handshake_payload.dig("result", "agent_capabilities_version")
        assert_equal [], handshake_payload.dig("result", "agent_tool_catalog")

        assert_equal "unchanged", unchanged_payload.dig("result", "status")
        assert_equal expected_agent_capabilities_version, unchanged_payload.dig("result", "agent_capabilities_version")
        refute unchanged_payload.fetch("result").key?("agent_tool_catalog")

        assert_equal "refreshed", refresh_payload.dig("result", "status")
        assert_equal "manual", refresh_payload.dig("result", "refresh_reason")
        assert_equal expected_agent_capabilities_version, refresh_payload.dig("result", "agent_capabilities_version")
      ensure
        host&.shutdown
      end

      def test_http_json_rpc_serves_descriptor_based_attachment_imports
        host = build_host.start

        payload =
          rpc_json(
            host.rpc_url,
            id: 8,
            method: "attachments.import",
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

        import = payload.fetch("result").fetch("imports").first

        assert_equal "attachment-1", import.fetch("id")
        assert_equal "attachment_import", import.dig("remote_ref", "kind")
        assert_match %r{\Aattachment-import://attachment-1/}, import.dig("remote_ref", "locator")
        assert_equal "error.png", import.dig("remote_ref", "filename")
        assert_equal "image/png", import.dig("remote_ref", "content_type")
        assert_equal 128, import.dig("remote_ref", "byte_size")
        assert_equal "sha256:abc123", import.dig("remote_ref", "digest")
      ensure
        host&.shutdown
      end

      def test_before_agent_step_returns_typed_planning_with_prompt_replacement_and_tool_surface
        callback = TestSupport::CallbackHarness.new.start
        host = build_host.start
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
          rpc_json(
            host.rpc_url,
            id: 9,
            method: "before_agent_step",
            params: {
              "conversation_id" => "conversation:test-default",
              "capability_snapshot" => capability_snapshot,
              "user_input" => "Verify the workspace status",
              "callback_session" => {
                "endpoint" => callback.rpc_url,
                "bearer" => callback.required_bearer
              }
            }
          )

        result = payload.fetch("result")

        assert_match("Verify the workspace status", result.dig("planning", "step_plan", "summary"))
        assert_equal "clear", result.dig("planning", "staged_mutations", "prompt_buffer_ops", 0, "op")
        assert_equal "system", result.dig("planning", "staged_mutations", "prompt_buffer_ops", 0, "buffer_name")
        assert_equal "put", result.dig("planning", "staged_mutations", "prompt_buffer_ops", 1, "op")
        assert_equal "system", result.dig("planning", "staged_mutations", "prompt_buffer_ops", 1, "entry", "buffer_name")
        assert_nil result.dig("planning", "step_plan", "fixture_scenarios")
        assert_nil result.dig("planning", "staged_mutations", "public_settings_patch")
        assert_nil result.dig("planning", "staged_mutations", "agent_config_patch")
        assert_nil result.dig("planning", "staged_mutations", "kv_ops")
        assert_nil result.dig("planning", "approval_request")
        assert_equal "csnap_fixture", result.dig("planning", "tool_surface", "capability_registry_snapshot_id")
        assert_equal %w[etool_compact etool_subagent_spawn], result.dig("planning", "tool_surface", "selected_tool_ids")
        assert_equal "surface_callback_harness", result.dig("planning", "tool_surface", "tool_surface_id")
        assert_nil result.dig("planning", "tool_surface", "tool_surface_label")
        assert_nil result.dig("planning", "execution_target_proposal")

        assert_equal(
          [ "tool_surface.manifest" ],
          callback.calls.map { |call| call.fetch("method") }
        )
      ensure
        host&.shutdown
        callback&.shutdown
      end

      def test_bootstrap_hooks_return_append_only_authority_tasks
        host = build_host.start

        conversation_payload =
          rpc_json(
            host.rpc_url,
            id: 10,
            method: "on_conversation_created",
            params: {
              "conversation_id" => "conversation:test-default",
              "conversation_kind" => "root",
              "agent_key" => "main",
              "lane_id" => "lane-main"
            }
          )
        main_lane_first_user_payload =
          rpc_json(
            host.rpc_url,
            id: 11,
            method: "on_lane_first_user_message",
            params: {
              "conversation_id" => "conversation:test-default",
              "lane_id" => "lane-main",
              "lane_role" => "main",
              "agent_key" => "main",
              "user_node_id" => "message-1"
            }
          )
        branch_lane_first_user_payload =
          rpc_json(
            host.rpc_url,
            id: 12,
            method: "on_lane_first_user_message",
            params: {
              "conversation_id" => "conversation:branch",
              "conversation_kind" => "branch",
              "lane_id" => "lane-branch",
              "lane_role" => "branch",
              "agent_key" => "main",
              "user_node_id" => "message-branch-1"
            }
          )

        assert_equal "create_task", conversation_payload.dig("result", "actions", 0, "type")
        assert_equal "append", conversation_payload.dig("result", "actions", 0, "placement")
        assert_match(/\Acybros_/i, conversation_payload.dig("result", "actions", 0, "logical_tool_name"))
        assert_equal [ "cybros_generate_title" ], main_lane_first_user_payload.fetch("result").fetch("actions").map { |action| action["logical_tool_name"] }
        assert_equal [ "cybros_generate_title", "cybros_enqueue_lane_summary" ],
                     branch_lane_first_user_payload.fetch("result").fetch("actions").map { |action| action["logical_tool_name"] }
        assert branch_lane_first_user_payload.fetch("result").fetch("actions").all? { |action| action["placement"] == "append" }
      ensure
        host&.shutdown
      end

      def test_before_agent_step_replaces_the_system_prompt_buffer_without_extra_callback_state
        callback = TestSupport::CallbackHarness.new.start
        host = build_host.start

        payload =
          rpc_json(
            host.rpc_url,
            id: 13,
            method: "before_agent_step",
            params: {
              "conversation_id" => "conversation:test-default",
              "user_input" => "Allocate the next seq",
              "callback_session" => {
                "endpoint" => callback.rpc_url,
                "bearer" => callback.required_bearer
              }
            }
          )

        ops = payload.dig("result", "planning", "staged_mutations", "prompt_buffer_ops")
        entry = ops.fetch(1).fetch("entry")

        assert_equal "clear", ops.fetch(0).fetch("op")
        assert_equal "system", ops.fetch(0).fetch("buffer_name")
        assert_equal "system", entry.fetch("buffer_name")
        assert_equal 10, entry.fetch("seq")
        refute_includes callback.calls.map { |call| call.fetch("method") }, "lane.prompt_buffer.list"
      ensure
        host&.shutdown
        callback&.shutdown
      end

      def test_before_agent_step_injects_workspace_and_attachment_descriptors_without_execution_target_callbacks
        host = build_host.start

        payload =
          rpc_json(
            host.rpc_url,
            id: 14,
            method: "before_agent_step",
            params: {
              "user_input" => "Review the uploaded files",
              "session_context" => {
                "workspace" => {
                  "conversation_id" => "conversation:test-default",
                  "logical_workspace_key" => "conversation-conversation:test-default",
                  "logical_workspace_root_path" => "/tmp/cybros/conversations/conversation:test-default",
                  "logical_workspace_initialized_at" => "2026-03-13T09:00:00Z"
                }
              },
              "attachment_manifest" => [
                {
                  "id" => "attachment-1",
                  "filename" => "screenshot-error.png",
                  "content_type" => "image/png"
                },
                {
                  "id" => "attachment-2",
                  "filename" => "logs.txt",
                  "content_type" => "text/plain"
                }
              ]
            }
          )

        system_entry = payload.dig("result", "planning", "staged_mutations", "prompt_buffer_ops", 1, "entry", "content")

        assert_includes system_entry, "Review the uploaded files"
        assert_includes system_entry, "Conversation workspace: /tmp/cybros/conversations/conversation:test-default"
        assert_includes system_entry, "Attachment 1: screenshot-error.png (image/png)"
        assert_includes system_entry, "Attachment 2: logs.txt (text/plain)"
      ensure
        host&.shutdown
      end

      def test_on_context_pressure_before_subagent_spawn_before_finalize_output_after_task_notice_and_after_subagent_result_return_typed_action_envelopes
        host = build_host.start

        context_pressure_payload =
          rpc_json(
            host.rpc_url,
            id: 15,
            method: "on_context_pressure",
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
          rpc_json(
            host.rpc_url,
            id: 16,
            method: "before_subagent_spawn",
            params: {
              "subagent_request" => {
                "tool_name" => "subagent_run",
                "tool_call_id" => "tc_subagent",
                "arguments" => {
                  "name" => "researcher",
                  "prompt" => "Investigate the repo"
                }
              }
            }
          )
        finalize_payload =
          rpc_json(
            host.rpc_url,
            id: 17,
            method: "before_finalize_output",
            params: {
              "execution_target_id" => "target-primary",
              "capability_registry_snapshot_id" => "csnap_fixture",
              "execution_context" => {
                "conversation_id" => "conversation:test-default"
              },
              "planning" => {
                "step_plan" => {
                  "summary" => "inspect the current repository status"
                }
              },
              "provider_input" => {
                "messages" => [
                  { "role" => "user", "content" => "Can you summarize what you are about to do?" }
                ],
                "tools" => [
                  {
                    "name" => "compact_context",
                    "description" => "compact",
                    "parameters" => {},
                    "logical_tool_name" => "compact_context",
                    "effective_tool_id" => "etool_compact",
                    "implementation_source" => "agent_program",
                    "implementation_ref" => "agent://compact_context"
                  }
                ]
              },
              "draft_output" => {
                "content" => "Draft output from the model"
              }
            }
          )
        task_notice_payload =
          rpc_json(
            host.rpc_url,
            id: 18,
            method: "after_task_notice",
            params: {
              "planning" => {
                "step_plan" => {
                  "summary" => "inspect the current repository status"
                }
              },
              "provider_input" => {
                "messages" => [
                  { "role" => "user", "content" => "Please run the checks." }
                ]
              },
              "task_notice" => {
                "task_id" => "task-123",
                "subject_kind" => "agent_step",
                "status" => "failed",
                "notice" => {
                  "kind" => "provider_error"
                },
                "error" => {
                  "class" => "RuntimeError",
                  "message" => "tool execution crashed"
                }
              }
            }
          )
        task_notice_task_payload =
          rpc_json(
            host.rpc_url,
            id: 19,
            method: "after_task_notice",
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
          rpc_json(
            host.rpc_url,
            id: 20,
            method: "after_subagent_result",
            params: {
              "subagent_result" => {
                "subagent_id" => "subagent-123",
                "status" => "succeeded",
                "assistant_output_candidate" => {
                  "format" => "text",
                  "content" => "Candidate answer from the worker",
                  "scope" => "partial"
                }
              }
            }
          )

        context_pressure_actions = context_pressure_payload.dig("result", "actions")
        before_subagent_status = before_subagent_payload.dig("result", "actions", 0, "text").to_s
        finalize_content = finalize_payload.dig("result", "actions", 0, "message", "content").to_s
        error_content = task_notice_payload.dig("result", "actions", 0, "message", "content").to_s
        task_notice_status = task_notice_task_payload.dig("result", "actions", 0, "text").to_s
        subagent_status = subagent_payload.dig("result", "actions", 0, "text").to_s

        assert_equal "set_step_status", context_pressure_actions.dig(0, "type")
        assert_includes context_pressure_actions.dig(0, "text").to_s.downcase, "context"
        assert_equal "create_task", context_pressure_actions.dig(1, "type")
        assert_equal "prepend", context_pressure_actions.dig(1, "placement")
        assert_equal "compact_context", context_pressure_actions.dig(1, "logical_tool_name")
        assert_equal "set_step_status", before_subagent_payload.dig("result", "actions", 0, "type")
        assert_includes before_subagent_status.downcase, "subagent"
        assert_includes before_subagent_status, "subagent_run"
        assert_equal "emit_message", finalize_payload.dig("result", "actions", 0, "type")
        assert_equal "Draft output from the model", finalize_content
        assert_nil finalize_payload.dig("result", "tool_surface")
        assert_equal "emit_message", task_notice_payload.dig("result", "actions", 0, "type")
        assert_includes error_content, "tool execution crashed"
        assert_includes error_content, "Please run the checks."
        assert_includes error_content, "provider_error"
        assert_equal "set_step_status", task_notice_task_payload.dig("result", "actions", 0, "type")
        assert_includes task_notice_status, "remote_tool_failed"
        assert_includes task_notice_status, "shell_exec"
        assert_includes task_notice_status, "shell_exec crashed"
        assert_equal "set_step_status", subagent_payload.dig("result", "actions", 0, "type")
        assert_includes subagent_status.downcase, "summarizing"
        assert_includes subagent_status, "subagent-123"
      ensure
        host&.shutdown
      end

      private

      def expected_deployment_key
        "default"
      end

      def expected_deployment_fingerprint
        "deployment:test-default"
      end

      def expected_agent_capabilities_version
        @expected_agent_capabilities_version ||=
          Cybros::Agents::Claw::Application.new(
            source_root: TestPaths.source_root,
            deployment_fingerprint: expected_deployment_fingerprint,
            required_bearer: required_bearer,
          ).agent_capabilities_version
      end

      def bearer_header
        "Bearer #{required_bearer}"
      end

      def health_url(host)
        uri = URI(host.rpc_url)
        uri.path = "/health"
        uri.query = nil
        uri.to_s
      end

      def assert_identity_payload(identity)
        assert_equal expected_agent_program_key, identity.fetch("agent_program_key")
        assert_equal expected_deployment_key, identity.fetch("agent_deployment_key")
        assert_equal expected_deployment_fingerprint, identity.fetch("deployment_fingerprint")
        assert_equal "agent_rpc.v1", identity.fetch("protocol_version")
        assert_equal REQUIRED_METHODS, identity.fetch("supported_methods")
      end

      def rpc_json(url, id:, method:, params:)
        response =
          http_post(
            url,
            body: rpc_body(id:, method:, params:),
            authorization: bearer_header
          )
        payload = assert_json_response(response, status: "200")

        assert_equal "2.0", payload.fetch("jsonrpc")
        assert_equal id, payload.fetch("id")
        payload
      end

      def rpc_body(id:, method:, params:)
        JSON.generate({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
      end

      def http_get(url, authorization: nil)
        uri = URI(url)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = authorization if authorization

        Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      end

      def http_post(url, body:, authorization: nil)
        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = authorization if authorization
        request.body = body

        Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      end

      def assert_json_response(response, status:)
        assert_equal status, response.code
        assert_equal "application/json", response["Content-Type"]
        JSON.parse(response.body)
      end
    end
  end
end
