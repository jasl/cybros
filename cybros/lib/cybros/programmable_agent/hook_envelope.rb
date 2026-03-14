module Cybros
  module ProgrammableAgent
    module HookActions
      Noop = Data.define(:type) do
        def to_h = { "type" => type }
      end

      SetStepStatus = Data.define(:type, :text, :state) do
        def to_h
          {
            "type" => type,
            "text" => text,
            "state" => state,
          }.compact
        end
      end

      CreateTask = Data.define(:type, :logical_tool_name, :input, :placement, :metadata) do
        def to_h
          {
            "type" => type,
            "logical_tool_name" => logical_tool_name,
            "input" => input,
            "placement" => placement,
            "metadata" => metadata,
          }.compact
        end
      end

      EmitMessage = Data.define(:type, :message) do
        def to_h
          {
            "type" => type,
            "message" => message,
          }.compact
        end
      end

      Halt = Data.define(:type, :reason, :message) do
        def to_h
          {
            "type" => type,
            "reason" => reason,
            "message" => message,
          }.compact
        end
      end

      Deny = Data.define(:type, :reason, :message) do
        def to_h
          {
            "type" => type,
            "reason" => reason,
            "message" => message,
          }.compact
        end
      end
    end

    class HookEnvelope < Data.define(:planning, :actions)
      TOP_LEVEL_KEYS = %w[planning actions].freeze
      PLANNING_KEYS = %w[
        step_plan
        staged_mutations
        approval_request
        tool_surface
      ].freeze
      STAGED_MUTATION_KEYS = %w[
        public_settings_patch
        agent_config_patch
        kv_ops
        prompt_buffer_ops
      ].freeze
      TERMINAL_ACTION_TYPES = %w[halt deny].freeze
      ACTION_POLICY = {
        "on_conversation_created" => %w[noop create_task],
        "on_lane_first_user_message" => %w[noop create_task],
        "before_agent_step" => %w[noop set_step_status halt],
        "on_context_pressure" => %w[noop set_step_status create_task halt],
        "before_subagent_spawn" => %w[noop set_step_status create_task deny halt],
        "after_task_notice" => %w[noop set_step_status create_task emit_message],
        "after_subagent_result" => %w[noop set_step_status create_task emit_message],
        "before_finalize_output" => %w[noop set_step_status emit_message create_task halt],
      }.freeze
      CREATE_TASK_PLACEMENT_POLICY = {
        "on_conversation_created" => %w[append],
        "on_lane_first_user_message" => %w[append],
        "on_context_pressure" => %w[prepend append],
        "before_subagent_spawn" => %w[prepend],
        "after_task_notice" => %w[append],
        "after_subagent_result" => %w[append],
        "before_finalize_output" => %w[append],
      }.freeze

      Planning = Data.define(
        :step_plan,
        :staged_mutations,
        :approval_request,
        :tool_surface,
      ) do
        def to_h
          {
            "step_plan" => step_plan,
            "staged_mutations" => staged_mutations,
            "approval_request" => approval_request,
            "tool_surface" => tool_surface,
          }.compact
        end
      end

      class << self
        def parse!(hook_name:, request_payload:, payload:)
          raw_payload = normalize_hash(payload)
          validate_top_level_keys!(raw_payload)

          planning = parse_planning!(hook_name: hook_name, request_payload: request_payload, raw_payload: raw_payload)
          actions = parse_actions!(hook_name: hook_name, raw_payload: raw_payload)

          new(planning: planning, actions: actions.freeze)
        end

        private

          def validate_top_level_keys!(payload)
            unknown = payload.keys - TOP_LEVEL_KEYS
            return if unknown.empty?

            AgentCore::ValidationError.raise!(
              "hook envelope contains unknown top-level keys",
              code: "cybros.programmable_agent.hook_contract.unknown_top_level_key",
              details: { unknown_keys: unknown },
            )
          end

          def parse_planning!(hook_name:, request_payload:, raw_payload:)
            planning_payload = raw_payload["planning"]
            return nil if planning_payload.nil?

            unless planning_allowed?(hook_name: hook_name, request_payload: request_payload)
              AgentCore::ValidationError.raise!(
                "planning is only allowed for before_agent_step during planning",
                code: "cybros.programmable_agent.hook_contract.planning_not_allowed",
                details: { hook_name: hook_name.to_s },
              )
            end

            planning_payload = normalize_hash(planning_payload)
            if planning_payload.key?("approval_state")
              AgentCore::ValidationError.raise!(
                "hooks must request approval through planning.approval_request",
                code: "cybros.programmable_agent.hook_contract.approval_state_forbidden",
                details: { hook_name: hook_name.to_s },
              )
            end

            unknown = planning_payload.keys - PLANNING_KEYS
            if unknown.any?
              AgentCore::ValidationError.raise!(
                "planning contains unknown fields",
                code: "cybros.programmable_agent.hook_contract.invalid_planning_field",
                details: { unknown_fields: unknown },
              )
            end

            staged_mutations = normalize_hash(planning_payload["staged_mutations"])
            unknown_mutations = staged_mutations.keys - STAGED_MUTATION_KEYS
            if unknown_mutations.any?
              AgentCore::ValidationError.raise!(
                "staged_mutations contains unknown fields",
                code: "cybros.programmable_agent.hook_contract.invalid_staged_mutations",
                details: { unknown_fields: unknown_mutations },
              )
            end

            Planning.new(
              step_plan: normalize_hash(planning_payload["step_plan"]),
              staged_mutations: {
                "public_settings_patch" => normalize_hash(staged_mutations["public_settings_patch"]),
                "agent_config_patch" => normalize_hash(staged_mutations["agent_config_patch"]),
                "kv_ops" => normalize_array(staged_mutations["kv_ops"]),
                "prompt_buffer_ops" => normalize_array(staged_mutations["prompt_buffer_ops"]),
              }.compact,
              approval_request: normalize_optional_hash(planning_payload["approval_request"]),
              tool_surface: normalize_optional_hash(planning_payload["tool_surface"]),
            )
          end

          def parse_actions!(hook_name:, raw_payload:)
            raw_actions = raw_payload["actions"]
            return [] if raw_actions.nil?

            unless raw_actions.is_a?(Array)
              AgentCore::ValidationError.raise!(
                "actions must be an array",
                code: "cybros.programmable_agent.hook_contract.actions_not_array",
                details: { hook_name: hook_name.to_s, actual_class: raw_actions.class.name },
              )
            end

            actions = raw_actions.map { |action| parse_action!(action) }
            validate_action_policy!(hook_name: hook_name, actions: actions)
            validate_create_task_policy!(hook_name: hook_name, actions: actions)
            validate_terminal_actions!(actions)
            validate_emit_message_actions!(actions)
            actions
          end

          def parse_action!(action)
            raw = normalize_hash(action)
            type = raw["type"].to_s

            case type
            when "noop"
              HookActions::Noop.new(type: type)
            when "set_step_status"
              text = raw["text"].to_s.strip
              if text.empty?
                AgentCore::ValidationError.raise!(
                  "set_step_status requires text",
                  code: "cybros.programmable_agent.hook_action.set_step_status_missing_text",
                )
              end

              HookActions::SetStepStatus.new(type: type, text: text, state: raw["state"].to_s.presence)
            when "create_task"
              input = normalize_hash(raw["input"])
              if input.key?("effective_tool_id") || input.key?("implementation_ref") || input.key?("implementation_source")
                AgentCore::ValidationError.raise!(
                  "hook-created tasks may not specify routing metadata",
                  code: "cybros.programmable_agent.runtime.task_rewrite_forbidden",
                  details: { forbidden_keys: %w[effective_tool_id implementation_ref implementation_source] & input.keys },
                )
              end

              placement = raw["placement"].to_s
              unless %w[prepend append].include?(placement)
                AgentCore::ValidationError.raise!(
                  "create_task placement must be prepend or append",
                  code: "cybros.programmable_agent.hook_action.invalid_task_placement",
                  details: { placement: placement },
                )
              end

              logical_tool_name = raw["logical_tool_name"].to_s.strip
              if logical_tool_name.empty?
                AgentCore::ValidationError.raise!(
                  "create_task requires logical_tool_name",
                  code: "cybros.programmable_agent.hook_action.create_task_missing_logical_tool_name",
                )
              end

              HookActions::CreateTask.new(
                type: type,
                logical_tool_name: logical_tool_name,
                input: input,
                placement: placement,
                metadata: normalize_optional_hash(raw["metadata"]),
              )
            when "emit_message"
              HookActions::EmitMessage.new(type: type, message: normalize_hash(raw["message"]).presence || raw["message"])
            when "halt"
              HookActions::Halt.new(type: type, reason: raw["reason"].to_s.presence, message: raw["message"].to_s.presence)
            when "deny"
              HookActions::Deny.new(type: type, reason: raw["reason"].to_s.presence, message: raw["message"].to_s.presence)
            else
              AgentCore::ValidationError.raise!(
                "action type is invalid",
                code: "cybros.programmable_agent.hook_contract.invalid_action_type",
                details: { action_type: type },
              )
            end
          end

          def validate_action_policy!(hook_name:, actions:)
            allowed = ACTION_POLICY.fetch(hook_name.to_s, %w[noop])

            actions.each do |action|
              next if allowed.include?(action.type)

              error_code =
                case action.type
                when "create_task" then "cybros.programmable_agent.hook_policy.create_task_not_allowed"
                when "emit_message" then "cybros.programmable_agent.hook_policy.emit_message_not_allowed"
                when "deny" then "cybros.programmable_agent.hook_policy.deny_not_allowed"
                when "set_step_status" then "cybros.programmable_agent.hook_policy.set_step_status_not_allowed"
                else "cybros.programmable_agent.hook_policy.action_not_allowed"
                end

              AgentCore::ValidationError.raise!(
                "action is not allowed for this hook",
                code: error_code,
                details: { hook_name: hook_name.to_s, action_type: action.type },
              )
            end
          end

          def validate_terminal_actions!(actions)
            terminal_indexes = actions.each_index.select { |index| TERMINAL_ACTION_TYPES.include?(actions[index].type) }
            return if terminal_indexes.empty?

            if terminal_indexes.length > 1 || terminal_indexes.last != actions.length - 1
              AgentCore::ValidationError.raise!(
                "terminal actions must be tail-only",
                code: "cybros.programmable_agent.hook_action.terminal_not_tail",
                details: { terminal_action_indexes: terminal_indexes },
              )
            end
          end

          def validate_create_task_policy!(hook_name:, actions:)
            allowed_placements = CREATE_TASK_PLACEMENT_POLICY.fetch(hook_name.to_s, [])

            actions.each do |action|
              next unless action.type == "create_task"
              next if allowed_placements.include?(action.placement)

              AgentCore::ValidationError.raise!(
                "create_task placement is not allowed for this hook",
                code: "cybros.programmable_agent.hook_policy.create_task_not_allowed",
                details: {
                  hook_name: hook_name.to_s,
                  placement: action.placement.to_s,
                },
              )
            end

            actions.each do |action|
              next unless action.type == "create_task"
              next unless bootstrap_hook?(hook_name)
              next if reserved_bootstrap_tool_name?(action.logical_tool_name)

              AgentCore::ValidationError.raise!(
                "bootstrap hook-created tasks must use the reserved cybros_* namespace",
                code: "cybros.programmable_agent.hook_policy.bootstrap_task_must_use_reserved_namespace",
                details: {
                  hook_name: hook_name.to_s,
                  logical_tool_name: action.logical_tool_name.to_s,
                },
              )
            end
          end

          def validate_emit_message_actions!(actions)
            emit_indexes = actions.each_index.select { |index| actions[index].type == "emit_message" }
            return if emit_indexes.empty?

            invalid_followup =
              emit_indexes.any? do |emit_index|
                actions[(emit_index + 1)..].to_a.any? do |action|
                  %w[emit_message set_step_status].include?(action.type)
                end
              end
            return unless invalid_followup

            AgentCore::ValidationError.raise!(
              "emit_message may not be followed by another emit_message or set_step_status",
              code: "cybros.programmable_agent.hook_action.emit_message_followup_forbidden",
            )
          end

          def planning_allowed?(hook_name:, request_payload:)
            hook_name.to_s == "before_agent_step" && request_payload.is_a?(Hash) && request_payload.dig("step", "phase").to_s == "planning"
          end

          def bootstrap_hook?(hook_name)
            %w[on_conversation_created on_lane_first_user_message].include?(hook_name.to_s)
          end

          def reserved_bootstrap_tool_name?(logical_tool_name)
            logical_tool_name.to_s.start_with?(Cybros::ProgrammableAgent::CapabilitySnapshot::RESERVED_LOGICAL_NAME_PREFIX)
          end

          def normalize_hash(value)
            value.is_a?(Hash) ? value.deep_stringify_keys : {}
          end

          def normalize_optional_hash(value)
            hash = normalize_hash(value)
            hash.presence
          end

          def normalize_array(value)
            Array(value).map do |entry|
              entry.is_a?(Hash) ? entry.deep_stringify_keys : entry
            end
          end
      end

      def to_h
        {
          "planning" => planning&.to_h,
          "actions" => actions.map(&:to_h),
        }.compact
      end
    end
  end
end
