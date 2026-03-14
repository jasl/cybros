module Cybros
  module ProgrammableAgent
    class RecognizedDeploymentResolver
      class << self
        def resolve!(agent:, deployment:, initialize_result: nil, capability_snapshot: nil)
          new(
            agent: agent,
            deployment: deployment,
            initialize_result: initialize_result,
            capability_snapshot: capability_snapshot,
          ).resolve!
        end

        def normalize_initialize_identity(initialize_result)
          payload = initialize_result.is_a?(Hash) ? initialize_result.deep_stringify_keys : {}
          identity = payload["identity"]
          normalize_hash(identity)
        end

        def normalize_capability_snapshot(value)
          normalize_hash(value)
        end

        def normalize_supported_methods(value)
          Array(value).map(&:to_s).reject(&:blank?).uniq.sort
        end

        def normalize_hash(value)
          value.is_a?(Hash) ? value.deep_stringify_keys : {}
        end
      end

      def initialize(agent:, deployment:, initialize_result:, capability_snapshot:)
        @agent = agent
        @deployment = deployment
        @initialize_identity = self.class.normalize_initialize_identity(initialize_result)
        @capability_snapshot =
          begin
            explicit_snapshot = self.class.normalize_capability_snapshot(capability_snapshot)
            explicit_snapshot.presence || self.class.normalize_capability_snapshot(deployment&.capability_snapshot)
          end
      end

      def resolve!
        payload = identity_payload
        identity_digest = RecognizedDeployment.digest_for(payload)
        recognized_deployment_key = "recognized_deployment:agent:#{agent.id}:#{identity_digest}"

        record = RecognizedDeployment.find_or_initialize_by(agent: agent, identity_digest: identity_digest)
        record.assign_attributes(
          recognized_deployment_key: recognized_deployment_key,
          contract_fingerprint: contract_fingerprint,
          deployment_fingerprint: deployment_fingerprint,
          protocol_version: protocol_version,
          supported_methods: supported_methods,
          agent_sdk_version: agent_sdk_version,
          agent_capabilities_version: agent_capabilities_version,
          capability_snapshot_digest: capability_snapshot_digest,
          capability_snapshot: capability_snapshot,
          supports_upload: supported_methods.include?("attachments.import"),
          hostname: capability_snapshot["hostname"].to_s.presence,
          container_id: capability_snapshot["container_id"].to_s.presence,
          git_sha: capability_snapshot["git_sha"].to_s.presence,
          build_id: capability_snapshot["build_id"].to_s.presence,
          image_digest: capability_snapshot["image_digest"].to_s.presence,
          booted_at: RecognizedDeployment.parse_time(capability_snapshot["booted_at"]),
        )
        record.save!
        record
      end

      def identity_payload
        {
          "deployment_fingerprint" => deployment_fingerprint,
          "contract_fingerprint" => contract_fingerprint,
          "protocol_version" => protocol_version,
          "supported_methods" => supported_methods,
          "agent_sdk_version" => agent_sdk_version,
          "agent_capabilities_version" => agent_capabilities_version,
          "capability_snapshot_digest" => capability_snapshot_digest,
          "transport_kind" => transport_kind,
          "endpoint_url" => endpoint_url,
          "deployment_bearer_secret_ref" => deployment_bearer_secret_ref,
          "transport_config_digest" => transport_config_digest,
        }.compact
      end

      private

        attr_reader :agent, :deployment, :initialize_identity, :capability_snapshot

        def deployment_fingerprint
          initialize_identity["deployment_fingerprint"].to_s.presence || deployment.deployment_fingerprint.to_s
        end

        def contract_fingerprint
          deployment.contract_fingerprint.to_s.presence || agent.published_contract_fingerprint.to_s
        end

        def protocol_version
          initialize_identity["protocol_version"].to_s.presence || deployment.protocol_version.to_s
        end

        def supported_methods
          methods = initialize_identity["supported_methods"]
          methods = deployment.supported_methods if methods.blank?
          self.class.normalize_supported_methods(methods)
        end

        def agent_sdk_version
          initialize_identity["agent_sdk_version"].to_s.presence || deployment.agent_sdk_version.to_s.presence
        end

        def agent_capabilities_version
          capability_snapshot["agent_capabilities_version"].to_s.presence
        end

        def capability_snapshot_digest
          RecognizedDeployment.digest_for(capability_snapshot)
        end

        def transport_kind
          deployment.respond_to?(:transport_kind) ? deployment.transport_kind.to_s.presence : nil
        end

        def endpoint_url
          deployment.respond_to?(:endpoint_url) ? deployment.endpoint_url.to_s.presence : nil
        end

        def deployment_bearer_secret_ref
          if deployment.respond_to?(:deployment_bearer_secret_ref)
            deployment.deployment_bearer_secret_ref.to_s.presence
          end
        end

        def transport_config_digest
          return nil unless deployment.respond_to?(:transport_config)

          normalized = self.class.normalize_hash(deployment.transport_config)
          return nil if normalized.empty?

          RecognizedDeployment.digest_for(normalized)
        end
    end
  end
end
