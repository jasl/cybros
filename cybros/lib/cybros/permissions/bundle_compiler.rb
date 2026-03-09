module Cybros
  module Permissions
    class BundleCompiler
      def self.compile(permission_mode:, tools_registry:)
        new(permission_mode: permission_mode, tools_registry: tools_registry).compile
      end

      def initialize(permission_mode:, tools_registry:)
        @permission_mode = permission_mode.to_s.strip
        @tools_registry = tools_registry
      end

      def compile
        validate_permission_mode!

        {
          permission_mode: permission_mode,
          tool_policy: compiled_tool_policy,
          summary: summary,
        }
      end

      private

        attr_reader :permission_mode, :tools_registry

        def compiled_tool_policy
          AgentCore::Resources::Tools::Policy::Ruleset.new(
            allow: allow_rules,
            confirm: confirm_rules,
            delegate: fallback_policy,
            tool_groups: nil,
          )
        end

        def allow_rules
          rules_for_classes(allow_classes, suffix: "allow")
        end

        def confirm_rules
          rules_for_classes(confirm_classes, suffix: "confirm")
        end

        def rules_for_classes(classes, suffix:)
          grouped_tool_names.each_with_object([]) do |(permission_class, tool_names), rules|
            next unless classes.include?(permission_class)
            next if tool_names.empty?

            rules << {
              tools: tool_names.sort,
              reason: "permission_preset_#{permission_mode}_#{permission_class}_#{suffix}",
            }
          end
        end

        def grouped_tool_names
          @grouped_tool_names ||=
            tools_registry.tool_names.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |tool_name, groups|
              permission_class = permission_class_for(tool_name)
              groups[permission_class] << tool_name
            end
        end

        def permission_class_for(tool_name)
          raw =
            case (tool_info = tools_registry.find(tool_name))
            when AgentCore::Resources::Tools::Tool
              tool_info.metadata
            when Hash
              definition = tool_info[:definition]
              definition.fetch(:metadata, definition.fetch("metadata", {})) if definition.is_a?(Hash)
            else
              {}
            end

          permission_class = raw.is_a?(Hash) ? raw.fetch(:permission_class, raw.fetch("permission_class", nil)).to_s.strip : ""
          return permission_class if TOOL_PERMISSION_CLASSES.include?(permission_class)

          "unknown"
        rescue StandardError
          "unknown"
        end

        def allow_classes
          case permission_mode
          when "conservative" then %w[read]
          when "default" then %w[read mutate]
          when "full_access" then TOOL_PERMISSION_CLASSES
          else []
          end
        end

        def confirm_classes
          case permission_mode
          when "conservative" then %w[mutate delegate boundary]
          when "default" then %w[delegate boundary]
          else []
          end
        end

        def fallback_policy
          AgentCore::Resources::Tools::Policy::ConfirmAll.new(reason: "permission_preset_#{permission_mode}_unknown_confirm")
        end

        def summary
          {
            "permission_mode" => permission_mode,
            "tool_defaults" => {
              "read" => allow_classes.include?("read") ? "allow" : "confirm",
              "mutate" => allow_classes.include?("mutate") ? "allow" : "confirm",
              "delegate" => allow_classes.include?("delegate") ? "allow" : "confirm",
              "boundary" => allow_classes.include?("boundary") ? "allow" : "confirm",
              "unknown" => "confirm",
            },
            "public_state_mutations" => {
              "default_outcome" => %w[default full_access].include?(permission_mode) ? "allow" : "confirm",
            },
            "target_switch" => {
              "same_target" => "allow",
              "different_visible_target" => permission_mode == "full_access" ? "allow" : "confirm",
            },
            "execution_boundary" => {
              "default_outcome" => permission_mode == "full_access" ? "allow" : "confirm",
            },
          }
        end

        def validate_permission_mode!
          return if MODES.include?(permission_mode)

          AgentCore::ValidationError.raise!(
            "permission_mode must be one of: #{MODES.join(', ')}",
            code: "cybros.permissions.bundle_compiler.permission_mode_invalid",
            details: { permission_mode: permission_mode, allowed_modes: MODES },
          )
        end
    end
  end
end
