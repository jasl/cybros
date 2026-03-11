module AgentRPC
  module KernelServices
    class ToolSurfaceManifest
      def self.call!(deployment:, payload:)
        new(deployment: deployment, payload: payload).call!
      end

      def initialize(deployment:, payload:)
        @deployment = deployment
        @payload = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
      end

      def call!
        snapshot = capability_snapshot
        requested_snapshot_id = payload.fetch("capability_registry_snapshot_id", "").to_s

        if requested_snapshot_id != snapshot.snapshot_id
          AgentCore::ValidationError.raise!(
            "capability_registry_snapshot_id does not match the pinned deployment snapshot",
            code: "cybros.agent_rpc.tool_surface_manifest.capability_registry_snapshot_id_mismatch",
            details: {
              requested_capability_registry_snapshot_id: requested_snapshot_id,
              expected_capability_registry_snapshot_id: snapshot.snapshot_id,
            },
          )
        end

        manifest =
          Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
            capability_registry_snapshot: snapshot,
            selected_tool_ids: payload.fetch("selected_tool_ids", []),
            tool_surface_label: payload["tool_surface_label"],
          )

        {
          "capability_registry_snapshot_id" => snapshot.snapshot_id,
          "tool_surface_id" => manifest.tool_surface_id,
          "tool_surface_label" => manifest.tool_surface_label,
          "selected_tool_ids" => manifest.selected_tool_ids,
          "logical_tool_names" => manifest.selected_tool_ids.filter_map { |tool_id| snapshot.effective_tool(tool_id)&.logical_tool_name },
        }.compact
      end

      private

        attr_reader :deployment, :payload

        def capability_snapshot
          snapshot_payload = deployment&.capability_snapshot
          snapshot_payload = {} unless snapshot_payload.is_a?(Hash)

          Cybros::ProgrammableAgent::CapabilitySnapshot.restore(snapshot_payload)
        end
    end
  end
end
