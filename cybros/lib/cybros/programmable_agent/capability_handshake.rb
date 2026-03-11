module Cybros
  module ProgrammableAgent
    module CapabilityHandshake
      REFRESH_REASONS = %w[kernel_registry_changed agent_capabilities_changed manual].freeze

      module_function

      def handshake!(deployment:, rpc_client: nil)
        rpc_client ||= AgentDeployments::RPCClient.new(deployment: deployment)
        catalog = KernelCapabilityCatalog.current
        cached = normalize_hash(deployment.capability_snapshot)

        response =
          normalize_hash(
            rpc_client.call(
              "capabilities.handshake",
              {
                "kernel_capability_registry_version" => catalog.kernel_capability_registry_version,
                "cached_capability_registry_snapshot_id" => cached["capability_registry_snapshot_id"],
                "cached_agent_capabilities_version" => cached["agent_capabilities_version"],
              }.compact,
            ),
          )

        if unchanged_fast_path?(response: response, cached: cached, catalog: catalog)
          return cached.merge(
            "status" => "unchanged",
            "kernel_capability_registry_version" => catalog.kernel_capability_registry_version,
          )
        end

        refresh_reason =
          if response["status"].to_s == "refreshed"
            "agent_capabilities_changed"
          else
            "kernel_registry_changed"
          end

        persist_snapshot!(
          deployment: deployment,
          catalog: catalog,
          response: response,
          cached: cached,
          refresh_reason: refresh_reason,
          status: "refreshed",
        )
      end

      def refresh!(deployment:, reason:, rpc_client: nil)
        reason = reason.to_s
        unless REFRESH_REASONS.include?(reason)
          AgentCore::ValidationError.raise!(
            "reason must be one of #{REFRESH_REASONS.join(", ")}",
            code: "cybros.programmable_agent.capability_handshake.reason_must_be_supported",
            details: { reason: reason },
          )
        end

        rpc_client ||= AgentDeployments::RPCClient.new(deployment: deployment)
        catalog = KernelCapabilityCatalog.current
        cached = normalize_hash(deployment.capability_snapshot)
        response =
          normalize_hash(
            rpc_client.call(
              "capabilities.refresh",
              {
                "reason" => reason,
                "kernel_capability_registry_version" => catalog.kernel_capability_registry_version,
                "cached_capability_registry_snapshot_id" => cached["capability_registry_snapshot_id"],
                "cached_agent_capabilities_version" => cached["agent_capabilities_version"],
              }.compact,
            ),
          )

        unless response["status"].to_s == "refreshed"
          AgentCore::ValidationError.raise!(
            "capabilities.refresh must return status=refreshed",
            code: "cybros.programmable_agent.capability_handshake.capabilities_refresh_must_return_refreshed",
            details: { status: response["status"] },
          )
        end

        persist_snapshot!(
          deployment: deployment,
          catalog: catalog,
          response: response,
          cached: cached,
          refresh_reason: reason,
          status: "refreshed",
        )
      end

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end
      private_class_method :normalize_hash

      def normalize_tool_catalog(value)
        Array(value).map { |tool| tool.is_a?(Hash) ? tool.deep_symbolize_keys : {} }
      end
      private_class_method :normalize_tool_catalog

      def unchanged_fast_path?(response:, cached:, catalog:)
        response["status"].to_s == "unchanged" &&
          cached["capability_registry_snapshot_id"].present? &&
          cached["kernel_capability_registry_version"].to_s == catalog.kernel_capability_registry_version.to_s &&
          cached["agent_capabilities_version"].to_s.present? &&
          cached["agent_capabilities_version"].to_s == response["agent_capabilities_version"].to_s
      end
      private_class_method :unchanged_fast_path?

      def persist_snapshot!(deployment:, catalog:, response:, cached:, refresh_reason:, status:)
        agent_capabilities_version = response["agent_capabilities_version"].to_s.presence || cached["agent_capabilities_version"].to_s
        agent_tool_catalog =
          if response["status"].to_s == "refreshed"
            if !response.key?("agent_tool_catalog")
              AgentCore::ValidationError.raise!(
                "refreshed capability responses must include agent_tool_catalog",
                code: "cybros.programmable_agent.capability_handshake.agent_tool_catalog_is_required_for_refreshed_response",
              )
            end

            normalize_tool_catalog(response["agent_tool_catalog"])
          else
            normalize_tool_catalog(cached["agent_tool_catalog"])
          end

        snapshot =
          CapabilitySnapshot.build(
            kernel_registry_version: catalog.kernel_capability_registry_version,
            agent_program_id: deployment.agent_program_id,
            agent_program_version: agent_capabilities_version,
            kernel_tools: catalog.tools,
            agent_tools: agent_tool_catalog,
          )

        payload = {
          "status" => status,
          "refresh_reason" => refresh_reason,
          "capability_registry_snapshot_id" => snapshot.snapshot_id,
          "kernel_capability_registry_version" => catalog.kernel_capability_registry_version,
          "agent_capabilities_version" => agent_capabilities_version,
          "agent_tool_catalog" => agent_tool_catalog.map(&:deep_stringify_keys),
          "effective_tools" =>
            snapshot.effective_tools.map do |tool|
              {
                "logical_tool_name" => tool.logical_tool_name,
                "effective_tool_id" => tool.effective_tool_id,
                "implementation_source" => tool.implementation_source,
                "implementation_ref" => tool.implementation_ref,
              }
            end,
        }

        deployment.update!(capability_snapshot: payload)
        payload
      end
      private_class_method :persist_snapshot!
    end
  end
end
