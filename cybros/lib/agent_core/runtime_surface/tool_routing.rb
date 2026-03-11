require "digest"
require "json"

module AgentCore
  module RuntimeSurface
    module ToolRouting
    end

    EffectiveTool =
      Data.define(
        :logical_tool_name,
        :effective_tool_id,
        :implementation_source,
        :implementation_ref,
      )

    class ToolRoutingSnapshot
      attr_reader :effective_tools, :snapshot_id

      def self.restore(payload)
        normalized = payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
        snapshot_id = normalized.fetch(:capability_registry_snapshot_id, normalized.fetch(:snapshot_id, "")).to_s

        AgentCore::ValidationError.raise!(
          "capability_registry_snapshot_id is required",
          code: "cybros.programmable_agent.capability_snapshot.capability_registry_snapshot_id_is_required",
        ) if snapshot_id.empty?

        effective_tools =
          Array(normalized.fetch(:effective_tools, [])).map do |tool|
            attributes = tool.is_a?(Hash) ? tool.deep_symbolize_keys : {}

            EffectiveTool.new(
              logical_tool_name: attributes.fetch(:logical_tool_name, "").to_s,
              effective_tool_id: attributes.fetch(:effective_tool_id, "").to_s,
              implementation_source: attributes.fetch(:implementation_source, "").to_s,
              implementation_ref: attributes.fetch(:implementation_ref, "").to_s,
            )
          end

        new(snapshot_id: snapshot_id, effective_tools: effective_tools)
      end

      def initialize(snapshot_id:, effective_tools:)
        @snapshot_id = snapshot_id.to_s.freeze
        @effective_tools = Array(effective_tools).freeze
        @effective_tools_by_id = @effective_tools.index_by(&:effective_tool_id).freeze
        @routes_by_logical_name = @effective_tools.index_by(&:logical_tool_name).freeze
      end

      def route_for(logical_tool_name)
        @routes_by_logical_name[logical_tool_name.to_s]
      end

      def route_for!(logical_tool_name)
        route_for(logical_tool_name) ||
          AgentCore::ValidationError.raise!(
            "logical tool is not present in capability snapshot",
            code: "cybros.programmable_agent.capability_snapshot.logical_tool_name_must_exist",
            details: { logical_tool_name: logical_tool_name.to_s, snapshot_id: snapshot_id },
          )
      end

      def effective_tool(effective_tool_id)
        @effective_tools_by_id[effective_tool_id.to_s]
      end
    end

    class ToolSurfaceManifest
      TOOL_SURFACE_ID_PREFIX = "surface_".freeze

      attr_reader :capability_registry_snapshot, :selected_tool_ids, :tool_surface_id, :tool_surface_label

      def self.restore(payload, capability_registry_snapshot:)
        payload = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
        expected_snapshot_id = capability_registry_snapshot.snapshot_id
        actual_snapshot_id = payload["capability_registry_snapshot_id"].to_s

        if actual_snapshot_id.present? && actual_snapshot_id != expected_snapshot_id
          AgentCore::ValidationError.raise!(
            "tool_surface capability snapshot must match the pinned deployment snapshot",
            code: "cybros.programmable_agent.tool_surface_manifest.capability_registry_snapshot_id_mismatch",
            details: {
              expected_capability_registry_snapshot_id: expected_snapshot_id,
              actual_capability_registry_snapshot_id: actual_snapshot_id,
            },
          )
        end

        manifest =
          new(
            capability_registry_snapshot: capability_registry_snapshot,
            selected_tool_ids: payload.fetch("selected_tool_ids", []),
            tool_surface_label: payload["tool_surface_label"],
          )

        actual_tool_surface_id = payload["tool_surface_id"].to_s
        if actual_tool_surface_id.present? && actual_tool_surface_id != manifest.tool_surface_id
          AgentCore::ValidationError.raise!(
            "tool_surface_id must match the selected tool ids",
            code: "cybros.programmable_agent.tool_surface_manifest.tool_surface_id_mismatch",
            details: {
              expected_tool_surface_id: manifest.tool_surface_id,
              actual_tool_surface_id: actual_tool_surface_id,
            },
          )
        end

        logical_tool_names = Array(payload["logical_tool_names"]).map(&:to_s).reject(&:empty?).sort
        if logical_tool_names.any? && logical_tool_names != manifest.selected_tools.map(&:logical_tool_name).sort
          AgentCore::ValidationError.raise!(
            "tool_surface logical tool names must match the selected tool ids",
            code: "cybros.programmable_agent.tool_surface_manifest.logical_tool_names_mismatch",
            details: {
              expected_logical_tool_names: manifest.selected_tools.map(&:logical_tool_name).sort,
              actual_logical_tool_names: logical_tool_names,
            },
          )
        end

        manifest
      end

      def initialize(capability_registry_snapshot:, selected_tool_ids:, tool_surface_label: nil)
        @capability_registry_snapshot = capability_registry_snapshot
        @selected_tool_ids = normalize_selected_tool_ids(selected_tool_ids).freeze
        @tool_surface_label = tool_surface_label.to_s.presence

        validate_selected_tool_ids!
        @tool_surface_id = build_tool_surface_id.freeze
      end

      def selected_tools
        @selected_tools ||= selected_tool_ids.filter_map { |tool_id| capability_registry_snapshot.effective_tool(tool_id) }.freeze
      end

      def effective_tool_for(logical_tool_name)
        selected_tools.find { |tool| tool.logical_tool_name == logical_tool_name.to_s }
      end

      private

        def normalize_selected_tool_ids(selected_tool_ids)
          Array(selected_tool_ids).map(&:to_s).reject(&:empty?).uniq
        end

        def validate_selected_tool_ids!
          missing = selected_tool_ids.reject { |tool_id| capability_registry_snapshot.effective_tool(tool_id) }
          return if missing.empty?

          AgentCore::ValidationError.raise!(
            "selected_tool_ids must exist in the capability snapshot",
            code: "cybros.programmable_agent.tool_surface_manifest.selected_tool_ids_must_exist_in_snapshot",
            details: {
              snapshot_id: capability_registry_snapshot.snapshot_id,
              missing_tool_ids: missing,
            },
          )
        end

        def build_tool_surface_id
          payload = {
            capability_registry_snapshot_id: capability_registry_snapshot.snapshot_id,
            selected_tool_ids: selected_tool_ids.sort,
          }

          "#{TOOL_SURFACE_ID_PREFIX}#{Digest::SHA256.hexdigest(JSON.generate(payload)).first(24)}"
        end
    end
  end
end
